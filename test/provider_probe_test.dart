import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/custom_provider.dart';
import 'package:opencode_mobile/domain/provider_probe.dart';

ProviderProbeAnswer _json(Object body, {int status = 200}) =>
    ProviderProbeAnswer(statusCode: status, body: jsonEncode(body));

Map<String, dynamic> _body(ProviderProbeRequest request) =>
    jsonDecode(request.body) as Map<String, dynamic>;

void main() {
  group('request shape', () {
    test('chat completions posts to /chat/completions with Bearer', () {
      final probe = ProviderProbe(
        send: (request) async => _json({'ok': true}),
      );
      final request = probe.buildRequest(
        kind: ProviderProbeKind.nonStreaming,
        protocol: ProviderProtocol.chatCompletions,
        baseUrl: 'https://api.example.com/v1/',
        model: 'demo',
        apiKey: 'sk-test',
      );
      expect(
        request.url.toString(),
        'https://api.example.com/v1/chat/completions',
      );
      expect(request.headers['authorization'], 'Bearer sk-test');
      final body = _body(request);
      expect(body['model'], 'demo');
      expect(body['stream'], false);
      expect(body['messages'], isNotEmpty);
    });

    test('anthropic posts to /messages with x-api-key and a version', () {
      final probe = ProviderProbe(
        send: (request) async => _json({'ok': true}),
      );
      final request = probe.buildRequest(
        kind: ProviderProbeKind.nonStreaming,
        protocol: ProviderProtocol.anthropic,
        baseUrl: 'https://api.anthropic.com/v1',
        model: 'claude-demo',
        apiKey: 'sk-ant',
      );
      expect(request.url.toString(), 'https://api.anthropic.com/v1/messages');
      expect(request.headers['x-api-key'], 'sk-ant');
      expect(request.headers['anthropic-version'], isNotNull);
      expect(request.headers.containsKey('authorization'), isFalse);
    });

    test('tool probe declares get_weather in each protocol dialect', () {
      final probe = ProviderProbe(
        send: (request) async => _json({'ok': true}),
      );
      final chat = _body(
        probe.buildRequest(
          kind: ProviderProbeKind.toolCall,
          protocol: ProviderProtocol.chatCompletions,
          baseUrl: 'https://x.test/v1',
          model: 'm',
        ),
      );
      expect((chat['tools'] as List).first['type'], 'function');
      expect(
        ((chat['tools'] as List).first as Map)['function']['name'],
        'get_weather',
      );

      final anthropic = _body(
        probe.buildRequest(
          kind: ProviderProbeKind.toolCall,
          protocol: ProviderProtocol.anthropic,
          baseUrl: 'https://x.test/v1',
          model: 'm',
        ),
      );
      expect(
        (anthropic['tools'] as List).first['input_schema'],
        isA<Map>(),
      );

      final responses = _body(
        probe.buildRequest(
          kind: ProviderProbeKind.toolCall,
          protocol: ProviderProtocol.responses,
          baseUrl: 'https://x.test/v1',
          model: 'm',
        ),
      );
      expect((responses['tools'] as List).first['name'], 'get_weather');
    });

  });

  group('verdicts', () {
    test('non-streaming passes with text and fails without it', () async {
      final pass = ProviderProbe(
        send: (request) async => _json({
          'choices': [
            {
              'message': {'content': 'OK'},
            },
          ],
        }),
      );
      expect(
        (await pass.runOne(
          kind: ProviderProbeKind.nonStreaming,
          protocol: ProviderProtocol.chatCompletions,
          baseUrl: 'https://x.test/v1',
          model: 'm',
        )).passed,
        isTrue,
      );

      final empty = ProviderProbe(
        send: (request) async => _json({'choices': []}),
      );
      final result = await empty.runOne(
        kind: ProviderProbeKind.nonStreaming,
        protocol: ProviderProtocol.chatCompletions,
        baseUrl: 'https://x.test/v1',
        model: 'm',
      );
      expect(result.passed, isFalse);
      expect(result.detail, contains('No text'));
    });

    test('streaming needs real deltas, not just a 200', () async {
      final sse = [
        'data: {"choices":[{"delta":{"content":"1"}}]}',
        '',
        'data: {"choices":[{"delta":{"content":"2"}}]}',
        '',
        'data: [DONE]',
      ].join('\n');
      final probe = ProviderProbe(
        send: (request) async =>
            ProviderProbeAnswer(statusCode: 200, body: sse),
      );
      final result = await probe.runOne(
        kind: ProviderProbeKind.streaming,
        protocol: ProviderProtocol.chatCompletions,
        baseUrl: 'https://x.test/v1',
        model: 'm',
      );
      expect(result.passed, isTrue);
      expect(result.detail, contains('2 incremental'));

      final ignored = ProviderProbe(
        send: (request) async => _json({
          'choices': [
            {
              'message': {'content': 'one blob'},
            },
          ],
        }),
      );
      final fellBack = await ignored.runOne(
        kind: ProviderProbeKind.streaming,
        protocol: ProviderProtocol.chatCompletions,
        baseUrl: 'https://x.test/v1',
        model: 'm',
      );
      expect(fellBack.passed, isFalse);
      expect(fellBack.detail, contains('No server-sent events'));
    });

    test('tool calling is read from each protocol shape', () async {
      final chat = ProviderProbe(
        send: (request) async => _json({
          'choices': [
            {
              'message': {
                'tool_calls': [
                  {
                    'function': {'name': 'get_weather'},
                  },
                ],
              },
            },
          ],
        }),
      );
      expect(
        (await chat.runOne(
          kind: ProviderProbeKind.toolCall,
          protocol: ProviderProtocol.chatCompletions,
          baseUrl: 'https://x.test/v1',
          model: 'm',
        )).passed,
        isTrue,
      );

      final anthropic = ProviderProbe(
        send: (request) async => _json({
          'content': [
            {'type': 'tool_use', 'name': 'get_weather'},
          ],
        }),
      );
      expect(
        (await anthropic.runOne(
          kind: ProviderProbeKind.toolCall,
          protocol: ProviderProtocol.anthropic,
          baseUrl: 'https://x.test/v1',
          model: 'm',
        )).passed,
        isTrue,
      );

      final responses = ProviderProbe(
        send: (request) async => _json({
          'output': [
            {'type': 'function_call', 'name': 'get_weather'},
          ],
        }),
      );
      expect(
        (await responses.runOne(
          kind: ProviderProbeKind.toolCall,
          protocol: ProviderProtocol.responses,
          baseUrl: 'https://x.test/v1',
          model: 'm',
        )).passed,
        isTrue,
      );

      final ignored = ProviderProbe(
        send: (request) async => _json({
          'choices': [
            {
              'message': {'content': 'It is sunny.'},
            },
          ],
        }),
      );
      expect(
        (await ignored.runOne(
          kind: ProviderProbeKind.toolCall,
          protocol: ProviderProtocol.chatCompletions,
          baseUrl: 'https://x.test/v1',
          model: 'm',
        )).passed,
        isFalse,
      );
    });
  });

  group('failures', () {
    test('a non-2xx answer names the status and keeps the key out', () async {
      final probe = ProviderProbe(
        send: (request) async => ProviderProbeAnswer(
          statusCode: 401,
          body: '{"error":"invalid api key sk-test"}',
        ),
      );
      final result = await probe.runOne(
        kind: ProviderProbeKind.nonStreaming,
        protocol: ProviderProtocol.chatCompletions,
        baseUrl: 'https://x.test/v1',
        model: 'm',
        apiKey: 'sk-test',
      );
      expect(result.passed, isFalse);
      expect(result.statusCode, 401);
      expect(result.detail, contains('HTTP 401'));
    });

    test('a transport error becomes a row, not a throw', () async {
      final probe = ProviderProbe(
        send: (request) async => throw StateError('connection reset'),
      );
      final result = await probe.runOne(
        kind: ProviderProbeKind.streaming,
        protocol: ProviderProtocol.chatCompletions,
        baseUrl: 'https://x.test/v1',
        model: 'm',
      );
      expect(result.passed, isFalse);
      expect(result.detail, contains('connection reset'));
    });

    test('runAll reports every probe in order and can stop early', () async {
      var calls = 0;
      final probe = ProviderProbe(
        send: (request) async {
          calls++;
          return _json({'choices': []});
        },
      );
      final seen = <ProviderProbeKind>[];
      final results = await probe.runAll(
        protocol: ProviderProtocol.chatCompletions,
        baseUrl: 'https://x.test/v1',
        model: 'm',
        onResult: (result) => seen.add(result.kind),
      );
      expect(results, hasLength(ProviderProbeKind.values.length));
      expect(seen, ProviderProbeKind.values);
      expect(calls, ProviderProbeKind.values.length);

      final stopped = await probe.runAll(
        protocol: ProviderProtocol.chatCompletions,
        baseUrl: 'https://x.test/v1',
        model: 'm',
        cancelled: () => true,
      );
      expect(stopped, isEmpty);
    });

    test('an empty base URL is a clear request error', () {
      final probe = ProviderProbe(
        send: (request) async => _json({'ok': true}),
      );
      expect(
        () => probe.buildRequest(
          kind: ProviderProbeKind.nonStreaming,
          protocol: ProviderProtocol.chatCompletions,
          baseUrl: '  ',
          model: 'm',
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
