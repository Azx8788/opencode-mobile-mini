/// One question asked of a gateway before a person is left to discover the
/// answer from a failed turn: does it speak the Anthropic Messages protocol,
/// and does it want the key in `Authorization` or in `x-api-key`?
///
/// New API and One API serve `/v1/messages` beside `/v1/chat/completions`, so
/// the address alone cannot say whether a gateway will work. A short probe
/// can, and its answer decides which variable Claude Code gets: the two are
/// not interchangeable, and sending the wrong one is a 401 that looks like a
/// bad key.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agent_endpoint.dart';

/// What a gateway answered, in the only terms that change what the app writes.
final class GatewayProbe {
  const GatewayProbe({
    required this.answersMessages,
    required this.usesApiKeyHeader,
    this.status,
    this.detail,
  });

  /// The gateway answered the Messages endpoint itself (2xx, or a 4xx that is
  /// about the request rather than about the route). A 404 means the route is
  /// not there, which no key can fix.
  final bool answersMessages;

  /// The key was refused in `Authorization` and accepted in `x-api-key`.
  /// Claude Code sends the latter only for `ANTHROPIC_API_KEY`.
  final bool usesApiKeyHeader;

  final int? status;

  /// A short, non-secret reason for the row to show. Never the key.
  final String? detail;

  @override
  String toString() =>
      'GatewayProbe($status${answersMessages ? '' : ', no messages'}'
      '${usesApiKeyHeader ? ', x-api-key' : ''})';
}

abstract final class GatewayProbeClient {
  /// How long one attempt may take. Two attempts run at most, so a save waits
  /// at most twice this before it proceeds with the default.
  static const timeout = Duration(seconds: 3);

  /// The oldest version every Anthropic-compatible gateway accepts.
  static const anthropicVersion = '2023-06-01';

  /// Asks [endpoint] whether it serves `/v1/messages`.
  ///
  /// Never throws: a probe that cannot reach the gateway is reported as such,
  /// because the person may be saving while offline and the endpoint is still
  /// worth writing. A null key skips the probe entirely — there is nothing to
  /// authenticate with, and a 401 would say nothing about the route.
  static Future<GatewayProbe> probe(
    AgentEndpoint endpoint, {
    Duration timeout = timeout,
  }) async {
    final key = endpoint.apiKey;
    if (key == null) {
      return const GatewayProbe(
        answersMessages: true,
        usesApiKeyHeader: false,
        detail: 'no key to probe with',
      );
    }
    final bearer = await _attempt(endpoint, key, xApiKey: false, timeout: timeout);
    if (bearer.answersMessages) return bearer;
    // Anything but a refused key is an answer about the route or the network;
    // only a refusal is worth retrying with the other header.
    if (!bearer.unauthorized) return bearer;
    final alternate = await _attempt(endpoint, key, xApiKey: true, timeout: timeout);
    if (alternate.answersMessages) {
      return GatewayProbe(
        answersMessages: true,
        usesApiKeyHeader: true,
        status: alternate.status,
        detail: alternate.detail,
      );
    }
    return alternate;
  }

  static Future<GatewayProbe> _attempt(
    AgentEndpoint endpoint,
    String key, {
    required bool xApiKey,
    required Duration timeout,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final uri = Uri.parse('${endpoint.baseUrl}/v1/messages');
      final request = await client.postUrl(uri).timeout(timeout);
      request.headers.set('content-type', 'application/json');
      request.headers.set('anthropic-version', anthropicVersion);
      if (xApiKey) {
        request.headers.set('x-api-key', key);
      } else {
        request.headers.set('authorization', 'Bearer $key');
      }
      final body = jsonEncode(<String, Object?>{
        'model': endpoint.model ?? 'claude-sonnet-4-6',
        'max_tokens': 1,
        'messages': <Object?>[
          <String, Object?>{'role': 'user', 'content': 'ping'},
        ],
      });
      request.add(utf8.encode(body));
      final response = await request.close().timeout(timeout);
      // The body is drained, not read: a gateway that streams stays
      // connected until the socket is closed.
      await response.drain<void>().timeout(timeout);
      final status = response.statusCode;
      final unauthorized = status == 401 || status == 403;
      return GatewayProbe(
        answersMessages: !unauthorized && status != 404 && status < 500,
        usesApiKeyHeader: false,
        status: status,
        detail: unauthorized
            ? 'key refused'
            : status == 404
            ? 'no /v1/messages'
            : status >= 500
            ? 'gateway error'
            : null,
      );
    } on TimeoutException {
      return const GatewayProbe(
        answersMessages: false,
        usesApiKeyHeader: false,
        detail: 'no answer in time',
      );
    } on Object {
      return const GatewayProbe(
        answersMessages: false,
        usesApiKeyHeader: false,
        detail: 'unreachable',
      );
    } finally {
      client.close(force: true);
    }
  }
}

/// `true` when the gateway refused the key rather than the route.
extension GatewayProbeUnauthorized on GatewayProbe {
  bool get unauthorized => status == 401 || status == 403;
}
