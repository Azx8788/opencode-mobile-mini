/// Asks a provider three small questions, the way the app will ask them.
///
/// A model list proves the endpoint answers; it does not prove the endpoint
/// can hold a conversation. The three probes here are the shape of a real
/// turn, each one thing the chat path depends on:
///
/// 1. **Non-streaming** — a plain completion comes back with text.
/// 2. **Streaming** — `stream: true` produces incremental deltas, not one
///    blob at the end (the chat view draws tokens as they arrive).
/// 3. **Tool calling** — a declared function is actually called by name,
///    which is how the agent runs commands and edits files.
///
/// Every probe is a single request and a small, explicit assertion. Failures
/// carry the provider's status and a short body excerpt — never the key.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'custom_provider.dart';

/// What a probe checks. The order is the order they run in.
enum ProviderProbeKind { nonStreaming, streaming, toolCall }

/// One probe's verdict, in words a settings screen can show.
class ProviderProbeResult {
  const ProviderProbeResult({
    required this.kind,
    required this.passed,
    required this.detail,
    this.statusCode,
    this.elapsed = Duration.zero,
  });

  final ProviderProbeKind kind;
  final bool passed;

  /// What happened, short enough for one row: "HTTP 401: invalid key".
  final String detail;

  final int? statusCode;
  final Duration elapsed;

  ProviderProbeResult copyWith({Duration? elapsed}) => ProviderProbeResult(
    kind: kind,
    passed: passed,
    detail: detail,
    statusCode: statusCode,
    elapsed: elapsed ?? this.elapsed,
  );
}

/// A request the probe sends, kept separate from the transport so tests can
/// answer without a socket.
class ProviderProbeRequest {
  const ProviderProbeRequest({
    required this.url,
    required this.headers,
    required this.body,
    required this.timeout,
  });

  final Uri url;
  final Map<String, String> headers;
  final String body;
  final Duration timeout;
}

class ProviderProbeAnswer {
  const ProviderProbeAnswer({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

/// Sends one request and reads the whole answer. Streaming answers are read
/// to the end as text; the SSE frames are parsed afterwards, which keeps the
/// probe's assertions pure.
typedef ProviderProbeSend =
    Future<ProviderProbeAnswer> Function(ProviderProbeRequest request);

/// The five probes for one provider and one model.
class ProviderProbe {
  ProviderProbe({ProviderProbeSend? send}) : _send = send ?? _defaultSend;

  final ProviderProbeSend _send;

  static const _timeout = Duration(seconds: 45);

  /// Runs every probe in order, reporting each one as it finishes.
  ///
  /// [onResult] is called after each probe so a screen can fill its rows
  /// without waiting for the slowest question. A thrown transport error is
  /// turned into a failed row, never into a failed run: one broken probe
  /// must not hide the other four.
  Future<List<ProviderProbeResult>> runAll({
    required ProviderProtocol protocol,
    required String baseUrl,
    required String model,
    String? apiKey,
    void Function(ProviderProbeResult result)? onResult,
    bool Function()? cancelled,
  }) async {
    final results = <ProviderProbeResult>[];
    for (final kind in ProviderProbeKind.values) {
      if (cancelled?.call() ?? false) break;
      final result = await runOne(
        kind: kind,
        protocol: protocol,
        baseUrl: baseUrl,
        model: model,
        apiKey: apiKey,
      );
      results.add(result);
      onResult?.call(result);
    }
    return results;
  }

  /// One probe. Never throws: transport and parse errors become a failed
  /// row with their reason.
  Future<ProviderProbeResult> runOne({
    required ProviderProbeKind kind,
    required ProviderProtocol protocol,
    required String baseUrl,
    required String model,
    String? apiKey,
  }) async {
    final started = DateTime.now();
    try {
      final request = buildRequest(
        kind: kind,
        protocol: protocol,
        baseUrl: baseUrl,
        model: model,
        apiKey: apiKey,
      );
      final answer = await _send(request);
      final verdict = _judge(kind, protocol, answer);
      return ProviderProbeResult(
        kind: kind,
        passed: verdict.passed,
        detail: verdict.detail,
        statusCode: answer.statusCode,
        elapsed: DateTime.now().difference(started),
      );
    } on TimeoutException {
      return ProviderProbeResult(
        kind: kind,
        passed: false,
        detail: 'Timed out after ${_timeout.inSeconds}s',
        elapsed: DateTime.now().difference(started),
      );
    } catch (error) {
      return ProviderProbeResult(
        kind: kind,
        passed: false,
        detail: _short('$error'),
        elapsed: DateTime.now().difference(started),
      );
    }
  }

  /// The request a probe sends. Public so a test can assert the wire shape
  /// without any transport at all.
  ProviderProbeRequest buildRequest({
    required ProviderProbeKind kind,
    required ProviderProtocol protocol,
    required String baseUrl,
    required String model,
    String? apiKey,
  }) {
    final base = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    if (base.isEmpty) {
      throw const FormatException('Enter the base URL first');
    }
    final key = apiKey?.trim() ?? '';
    final headers = <String, String>{
      'content-type': 'application/json',
      'accept': kind == ProviderProbeKind.streaming
          ? 'text/event-stream'
          : 'application/json',
      ..._authHeaders(protocol, key),
    };
    final stream = kind == ProviderProbeKind.streaming;
    final url = Uri.parse('$base${_endpoint(protocol)}');
    final body = switch (protocol) {
      ProviderProtocol.chatCompletions => _chatBody(kind, model, stream),
      ProviderProtocol.responses => _responsesBody(kind, model, stream),
      ProviderProtocol.anthropic => _anthropicBody(kind, model, stream),
    };
    return ProviderProbeRequest(
      url: url,
      headers: headers,
      body: jsonEncode(body),
      timeout: _timeout,
    );
  }

  static Map<String, String> _authHeaders(
    ProviderProtocol protocol,
    String key,
  ) {
    if (key.isEmpty) return const {};
    return switch (protocol) {
      // Anthropic reads its own header; OpenAI-shaped gateways read Bearer.
      ProviderProtocol.anthropic => {
        'x-api-key': key,
        'anthropic-version': '2023-06-01',
      },
      _ => {'authorization': 'Bearer $key'},
    };
  }

  static String _endpoint(ProviderProtocol protocol) => switch (protocol) {
    ProviderProtocol.chatCompletions => '/chat/completions',
    ProviderProtocol.responses => '/responses',
    ProviderProtocol.anthropic => '/messages',
  };

  // ---------------- Request bodies ----------------

  static Map<String, Object?> _chatBody(
    ProviderProbeKind kind,
    String model,
    bool stream,
  ) {
    final body = <String, Object?>{
      'model': model,
      'stream': stream,
      'temperature': 0,
    };
    switch (kind) {
      case ProviderProbeKind.nonStreaming:
        body['max_tokens'] = 24;
        body['messages'] = [
          {'role': 'user', 'content': 'Reply with the single word OK.'},
        ];
      case ProviderProbeKind.streaming:
        body['max_tokens'] = 32;
        body['messages'] = [
          {'role': 'user', 'content': 'Count from 1 to 5, one number per line.'},
        ];
      case ProviderProbeKind.toolCall:
        body['max_tokens'] = 64;
        body['messages'] = [
          {
            'role': 'user',
            'content': 'What is the weather in Berlin? Use the tool.',
          },
        ];
        body['tools'] = [_chatTool];
        body['tool_choice'] = 'auto';
    }
    return body;
  }

  static const Map<String, Object?> _chatTool = {
    'type': 'function',
    'function': {
      'name': 'get_weather',
      'description': 'Current weather for a city.',
      'parameters': {
        'type': 'object',
        'properties': {
          'city': {'type': 'string'},
        },
        'required': ['city'],
      },
    },
  };

  static Map<String, Object?> _responsesBody(
    ProviderProbeKind kind,
    String model,
    bool stream,
  ) {
    final body = <String, Object?>{'model': model, 'stream': stream};
    Map<String, Object?> text(String role, String value) => {
      'role': role,
      'content': [
        {'type': 'input_text', 'text': value},
      ],
    };
    switch (kind) {
      case ProviderProbeKind.nonStreaming:
        body['max_output_tokens'] = 24;
        body['input'] = [text('user', 'Reply with the single word OK.')];
      case ProviderProbeKind.streaming:
        body['max_output_tokens'] = 32;
        body['input'] = [
          text('user', 'Count from 1 to 5, one number per line.'),
        ];
      case ProviderProbeKind.toolCall:
        body['max_output_tokens'] = 64;
        body['input'] = [
          text('user', 'What is the weather in Berlin? Use the tool.'),
        ];
        body['tools'] = [
          {
            'type': 'function',
            'name': 'get_weather',
            'description': 'Current weather for a city.',
            'parameters': {
              'type': 'object',
              'properties': {
                'city': {'type': 'string'},
              },
              'required': ['city'],
            },
          },
        ];
    }
    return body;
  }

  static Map<String, Object?> _anthropicBody(
    ProviderProbeKind kind,
    String model,
    bool stream,
  ) {
    final body = <String, Object?>{'model': model, 'max_tokens': 64};
    if (stream) body['stream'] = true;
    switch (kind) {
      case ProviderProbeKind.nonStreaming:
        body['max_tokens'] = 24;
        body['messages'] = [
          {'role': 'user', 'content': 'Reply with the single word OK.'},
        ];
      case ProviderProbeKind.streaming:
        body['max_tokens'] = 64;
        body['messages'] = [
          {
            'role': 'user',
            'content': 'Count from 1 to 5, one number per line.',
          },
        ];
      case ProviderProbeKind.toolCall:
        body['messages'] = [
          {
            'role': 'user',
            'content': 'What is the weather in Berlin? Use the tool.',
          },
        ];
        body['tools'] = [
          {
            'name': 'get_weather',
            'description': 'Current weather for a city.',
            'input_schema': {
              'type': 'object',
              'properties': {
                'city': {'type': 'string'},
              },
              'required': ['city'],
            },
          },
        ];
    }
    return body;
  }

  // ---------------- Judging ----------------

  _Verdict _judge(
    ProviderProbeKind kind,
    ProviderProtocol protocol,
    ProviderProbeAnswer answer,
  ) {
    if (answer.statusCode < 200 || answer.statusCode >= 300) {
      return _Verdict(false, _httpFailure(answer));
    }
    // A streamed answer is SSE, not one JSON document: parsing the whole
    // body first would report "not JSON" for a perfectly good stream.
    if (kind == ProviderProbeKind.streaming) {
      return _judgeStream(protocol, answer.body);
    }
    final body = _decode(answer.body);
    if (body == null) {
      return _Verdict(false, 'Answer is not JSON: ${_short(answer.body)}');
    }
    return switch (kind) {
      // Handled above; kept so the switch stays exhaustive.
      ProviderProbeKind.streaming => const _Verdict(false, 'Unreachable'),
      ProviderProbeKind.nonStreaming => _judgeText(protocol, body),
      ProviderProbeKind.toolCall => _judgeTool(protocol, body),
    };
  }

  static _Verdict _judgeText(ProviderProtocol protocol, Map body) {
    final text = _textOf(protocol, body).trim();
    return text.isEmpty
        ? const _Verdict(false, 'No text in the reply')
        : _Verdict(true, 'Replied: ${_short(text)}');
  }

  static _Verdict _judgeStream(ProviderProtocol protocol, String raw) {
    if (!raw.contains('data:')) {
      // Some compatible gateways ignore `stream: true` and answer one JSON
      // object. That is a working endpoint but not a working stream.
      return const _Verdict(false, 'No server-sent events in the answer');
    }
    var deltas = 0;
    for (final line in const LineSplitter().convert(raw)) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data.isEmpty || data == '[DONE]') continue;
      final frame = _decode(data);
      if (frame == null) continue;
      if (_streamDelta(protocol, frame).isNotEmpty) deltas++;
    }
    return deltas > 0
        ? _Verdict(true, '$deltas incremental updates')
        : const _Verdict(false, 'Events arrived, but carried no text delta');
  }

  static String _streamDelta(ProviderProtocol protocol, Map frame) {
    switch (protocol) {
      case ProviderProtocol.chatCompletions:
        final choices = frame['choices'];
        if (choices is! List || choices.isEmpty) return '';
        final first = choices.first;
        if (first is! Map) return '';
        final delta = first['delta'];
        if (delta is! Map) return '';
        final content = delta['content'];
        return content is String ? content : '';
      case ProviderProtocol.responses:
        final type = frame['type'];
        if (type == 'response.output_text.delta') {
          final delta = frame['delta'];
          return delta is String ? delta : '';
        }
        return '';
      case ProviderProtocol.anthropic:
        if (frame['type'] != 'content_block_delta') return '';
        final delta = frame['delta'];
        if (delta is! Map) return '';
        final text = delta['text'];
        return text is String ? text : '';
    }
  }

  static _Verdict _judgeTool(ProviderProtocol protocol, Map body) {
    final called = switch (protocol) {
      ProviderProtocol.chatCompletions => _chatToolNames(body).isNotEmpty,
      ProviderProtocol.responses => _responseToolCalls(body),
      ProviderProtocol.anthropic => _anthropicToolUses(body),
    };
    return called
        ? const _Verdict(true, 'Called get_weather')
        : const _Verdict(false, 'Answered without calling the tool');
  }

  static List<String> _chatToolNames(Map body) {
    final choices = body['choices'];
    if (choices is! List || choices.isEmpty) return const [];
    final first = choices.first;
    if (first is! Map) return const [];
    final message = first['message'];
    if (message is! Map) return const [];
    final calls = message['tool_calls'];
    if (calls is! List) return const [];
    return [
      for (final call in calls)
        if (call is Map &&
            call['function'] is Map &&
            (call['function'] as Map)['name'] is String)
          (call['function'] as Map)['name'] as String,
    ];
  }

  static bool _responseToolCalls(Map body) {
    final output = body['output'];
    if (output is! List) return false;
    return output.any(
      (item) => item is Map && item['type'] == 'function_call',
    );
  }

  static bool _anthropicToolUses(Map body) {
    final content = body['content'];
    if (content is! List) return false;
    return content.any((item) => item is Map && item['type'] == 'tool_use');
  }

  /// The assistant text, wherever the protocol keeps it.
  static String _textOf(ProviderProtocol protocol, Map body) {
    switch (protocol) {
      case ProviderProtocol.chatCompletions:
        final choices = body['choices'];
        if (choices is! List || choices.isEmpty) return '';
        final first = choices.first;
        if (first is! Map) return '';
        final message = first['message'];
        if (message is! Map) return '';
        final content = message['content'];
        if (content is String) return content;
        // Some gateways answer content parts even without streaming.
        if (content is List) {
          return [
            for (final part in content)
              if (part is Map && part['text'] is String) part['text'] as String,
          ].join();
        }
        return '';
      case ProviderProtocol.responses:
        final output = body['output'];
        if (output is! List) return '';
        final buffer = StringBuffer();
        for (final item in output) {
          if (item is! Map) continue;
          final content = item['content'];
          if (content is! List) continue;
          for (final part in content) {
            if (part is Map &&
                part['type'] == 'output_text' &&
                part['text'] is String) {
              buffer.write(part['text'] as String);
            }
          }
        }
        return buffer.toString();
      case ProviderProtocol.anthropic:
        final content = body['content'];
        if (content is! List) return '';
        final buffer = StringBuffer();
        for (final part in content) {
          if (part is Map && part['type'] == 'text' && part['text'] is String) {
            buffer.write(part['text'] as String);
          }
        }
        return buffer.toString();
    }
  }

  static Map? _decode(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    try {
      final value = jsonDecode(trimmed);
      return value is Map ? value : null;
    } catch (_) {
      return null;
    }
  }

  static String _httpFailure(ProviderProbeAnswer answer) {
    final body = answer.body.trim();
    final excerpt = body.isEmpty ? '' : ': ${_short(body)}';
    return 'HTTP ${answer.statusCode}$excerpt';
  }

  /// One line, no keys, no walls of HTML.
  static String _short(String value) {
    final collapsed = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return collapsed.length <= 160
        ? collapsed
        : '${collapsed.substring(0, 157)}…';
  }

  static Future<ProviderProbeAnswer> _defaultSend(
    ProviderProbeRequest request,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final http = await client.postUrl(request.url).timeout(request.timeout);
      request.headers.forEach(http.headers.set);
      http.add(utf8.encode(request.body));
      final response = await http.close().timeout(request.timeout);
      final text = await utf8
          .decoder
          .bind(response)
          .join()
          .timeout(request.timeout);
      return ProviderProbeAnswer(statusCode: response.statusCode, body: text);
    } finally {
      client.close(force: true);
    }
  }
}

class _Verdict {
  const _Verdict(this.passed, this.detail);

  final bool passed;
  final String detail;
}
