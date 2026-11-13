import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/agent_endpoint.dart';
import 'package:opencode_mobile/domain/gateway_probe.dart';

/// A gateway that records what each attempt carried, so the test can say
/// which header was tried and in what order.
class _Gateway {
  _Gateway(this._server) {
    _server.listen(_handle);
  }

  static Future<_Gateway> start({
    required List<int> bearerStatuses,
    required List<int> apiKeyStatuses,
    Duration delay = Duration.zero,
    String body = '{}',
  }) async {
    final gateway = _Gateway(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    gateway
      .._bearer = List.of(bearerStatuses)
      .._apiKey = List.of(apiKeyStatuses)
      .._delay = delay
      .._body = body;
    return gateway;
  }

  final HttpServer _server;
  final List<String> headers = [];
  final List<String> paths = [];
  List<int> _bearer = const [];
  List<int> _apiKey = const [];
  Duration _delay = Duration.zero;
  String _body = '{}';

  String get baseUrl => 'http://${_server.address.host}:${_server.port}';

  Future<void> _handle(HttpRequest request) async {
    paths.add(request.uri.path);
    final authorized = request.headers.value('authorization');
    headers.add(authorized != null ? 'bearer' : 'x-api-key');
    if (_delay > Duration.zero) await Future<void>.delayed(_delay);
    final queue = authorized != null ? _bearer : _apiKey;
    final status = queue.isEmpty ? 200 : queue.removeAt(0);
    // Drain whatever the probe sent so the socket closes cleanly.
    await request.drain<void>();
    request.response.statusCode = status;
    request.response.write(_body);
    await request.response.close();
  }

  Future<void> stop() => _server.close(force: true);
}

AgentEndpoint _endpoint(String baseUrl, {String? apiKey = 'sk-test'}) =>
    AgentEndpoint(baseUrl: baseUrl, apiKey: apiKey, model: 'deepseek-v4-flash');

void main() {
  test('a gateway that answers the Messages route is reachable', () async {
    final gateway = await _Gateway.start(
      bearerStatuses: <int>[],
      apiKeyStatuses: <int>[],
    );
    addTearDown(gateway.stop);
    final probe = await GatewayProbeClient.probe(_endpoint(gateway.baseUrl));
    expect(probe.answersMessages, isTrue);
    expect(probe.usesApiKeyHeader, isFalse);
    expect(probe.status, 200);
    expect(gateway.paths, <String>['/v1/messages']);
    expect(gateway.headers, <String>['bearer']);
  });

  test('a key refused in Authorization is retried as x-api-key', () async {
    final gateway = await _Gateway.start(
      bearerStatuses: <int>[401],
      apiKeyStatuses: <int>[200],
    );
    addTearDown(gateway.stop);
    final probe = await GatewayProbeClient.probe(_endpoint(gateway.baseUrl));
    expect(probe.answersMessages, isTrue);
    expect(probe.usesApiKeyHeader, isTrue);
    expect(gateway.headers, <String>['bearer', 'x-api-key']);
  });

  test('a key refused both ways is not a reachable gateway', () async {
    final gateway = await _Gateway.start(
      bearerStatuses: <int>[401],
      apiKeyStatuses: <int>[403],
    );
    addTearDown(gateway.stop);
    final probe = await GatewayProbeClient.probe(_endpoint(gateway.baseUrl));
    expect(probe.answersMessages, isFalse);
    expect(probe.usesApiKeyHeader, isFalse);
    expect(probe.detail, 'key refused');
  });

  test('a 404 is a gateway without the route, not a bad key', () async {
    final gateway = await _Gateway.start(
      bearerStatuses: <int>[404],
      apiKeyStatuses: <int>[],
    );
    addTearDown(gateway.stop);
    final probe = await GatewayProbeClient.probe(_endpoint(gateway.baseUrl));
    expect(probe.answersMessages, isFalse);
    expect(probe.detail, 'no /v1/messages');
    // A 404 is not about the key, so there is no second attempt.
    expect(gateway.headers, <String>['bearer']);
  });

  test('a silent gateway is reported, not thrown', () async {
    final gateway = await _Gateway.start(
      bearerStatuses: <int>[],
      apiKeyStatuses: <int>[],
      delay: const Duration(seconds: 2),
    );
    addTearDown(gateway.stop);
    final probe = await GatewayProbeClient.probe(
      _endpoint(gateway.baseUrl),
      timeout: const Duration(milliseconds: 150),
    );
    expect(probe.answersMessages, isFalse);
    expect(probe.detail, 'no answer in time');
  });

  test('a gateway that is not there is reported, not thrown', () async {
    final probe = await GatewayProbeClient.probe(
      _endpoint('http://127.0.0.1:1'),
      timeout: const Duration(milliseconds: 300),
    );
    expect(probe.answersMessages, isFalse);
    expect(probe.detail, 'unreachable');
  });

  test('no key means no probe: nothing to authenticate with', () async {
    final gateway = await _Gateway.start(
      bearerStatuses: <int>[],
      apiKeyStatuses: <int>[],
    );
    addTearDown(gateway.stop);
    final probe = await GatewayProbeClient.probe(
      _endpoint(gateway.baseUrl, apiKey: null),
    );
    expect(probe.answersMessages, isTrue);
    expect(gateway.paths, isEmpty);
  });

  test('the request names the model and asks for one token', () async {
    late String body;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      body = await utf8.decoder.bind(request).join();
      request.response.statusCode = 200;
      await request.response.close();
    });
    await GatewayProbeClient.probe(
      _endpoint('http://127.0.0.1:${server.port}'),
    );
    final decoded = jsonDecode(body) as Map<String, Object?>;
    expect(decoded['model'], 'deepseek-v4-flash');
    expect(decoded['max_tokens'], 1);
    expect(decoded['messages'], isNotEmpty);
  });

  test('a saved address that ends in /v1 probes one /v1/messages', () async {
    // AgentRouter's saved address keeps /v1; Claude Code appends /v1/messages
    // to the base. Probing the saved string verbatim would ask for
    // /v1/v1/messages and read the 404 as "no route".
    final gateway = await _Gateway.start(
      bearerStatuses: <int>[],
      apiKeyStatuses: <int>[],
    );
    addTearDown(gateway.stop);
    final probe = await GatewayProbeClient.probe(
      _endpoint('${gateway.baseUrl}/v1'),
    );
    expect(gateway.paths, <String>['/v1/messages']);
    expect(probe.answersMessages, isTrue);
  });

  test('a 404 that names a model is a route that is there', () async {
    final gateway = await _Gateway.start(
      bearerStatuses: <int>[404],
      apiKeyStatuses: <int>[],
      body:
          '{"type":"error","error":{"type":"not_found_error",'
          '"message":"model: claude-opus-4-7"}}',
    );
    addTearDown(gateway.stop);
    final probe = await GatewayProbeClient.probe(
      _endpoint(gateway.baseUrl, apiKey: 'sk-test'),
    );
    expect(probe.status, 404);
    expect(probe.answersMessages, isTrue);
    expect(probe.detail, 'model not in catalog');
  });

  test('a 404 with no model word is a missing route', () async {
    final gateway = await _Gateway.start(
      bearerStatuses: <int>[404],
      apiKeyStatuses: <int>[],
      body: '{"error":"not found"}',
    );
    addTearDown(gateway.stop);
    final probe = await GatewayProbeClient.probe(_endpoint(gateway.baseUrl));
    expect(probe.answersMessages, isFalse);
    expect(probe.detail, 'no /v1/messages');
  });
}
