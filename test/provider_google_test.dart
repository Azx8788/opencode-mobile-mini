// Gemini speaks a different list and probe shape: `models/...` resource
// names, `x-goog-api-key`, and a method suffix instead of a JSON path.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/custom_provider.dart';
import 'package:opencode_mobile/domain/provider_model_source.dart';
import 'package:opencode_mobile/domain/provider_probe.dart';

void main() {
  group('model list', () {
    test('strips the models/ prefix and reads displayName', () async {
      final source = ProviderModelSource(
        get: (url, headers, timeout) async => const ProviderHttpAnswer(
          statusCode: 200,
          body:
              '{"models":[{"name":"models/gemini-2.5-pro",'
              '"displayName":"Gemini 2.5 Pro"}]}',
        ),
      );
      final models = await source.fetch(
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        protocol: ProviderProtocol.google,
        apiKey: 'k',
      );
      expect(models.single.id, 'gemini-2.5-pro');
      expect(models.single.label, 'Gemini 2.5 Pro');
    });

    test('asks for a page and sends the key plus custom headers', () async {
      Uri? seen;
      Map<String, String>? seenHeaders;
      final source = ProviderModelSource(
        get: (url, headers, timeout) async {
          seen = url;
          seenHeaders = headers;
          return const ProviderHttpAnswer(
            statusCode: 200,
            body: '{"models":[]}',
          );
        },
      );
      await expectLater(
        source.fetch(
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
          protocol: ProviderProtocol.google,
          apiKey: 'k',
          headers: const {'X-Title': 'mini'},
        ),
        throwsA(isA<ProviderModelFetchFailure>()),
      );
      expect(seen.toString(), contains('/models?pageSize=100'));
      expect(seenHeaders?['x-goog-api-key'], 'k');
      expect(seenHeaders?['X-Title'], 'mini');
    });
  });

  group('probe request', () {
    final probe = ProviderProbe();

    test('a Gemini call carries the model and method in the path', () {
      final request = probe.buildRequest(
        kind: ProviderProbeKind.nonStreaming,
        protocol: ProviderProtocol.google,
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        model: 'gemini-2.5-pro',
        apiKey: 'k',
        headers: const {'X-Title': 'mini'},
      );
      expect(
        request.url.toString(),
        'https://generativelanguage.googleapis.com/v1beta/models/'
        'gemini-2.5-pro:generateContent',
      );
      expect(request.headers['x-goog-api-key'], 'k');
      expect(request.headers['X-Title'], 'mini');
      final body = jsonDecode(request.body) as Map;
      expect(body['contents'], isA<List>());
      expect(body.containsKey('tools'), isFalse);
    });

    test('a streaming call switches to streamGenerateContent', () {
      final request = probe.buildRequest(
        kind: ProviderProbeKind.streaming,
        protocol: ProviderProtocol.google,
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        model: 'gemini-2.5-pro',
        apiKey: 'k',
      );
      expect(
        request.url.toString(),
        endsWith('gemini-2.5-pro:streamGenerateContent?alt=sse'),
      );
    });

    test('a tool call declares get_weather', () {
      final request = probe.buildRequest(
        kind: ProviderProbeKind.toolCall,
        protocol: ProviderProtocol.google,
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        model: 'gemini-2.5-pro',
        apiKey: 'k',
      );
      final body = jsonDecode(request.body) as Map;
      final tools = body['tools'] as List;
      final declarations = (tools.single as Map)['functionDeclarations'] as List;
      expect((declarations.single as Map)['name'], 'get_weather');
    });
  });

  group('probe judging', () {
    test('reads text out of a Gemini answer', () async {
      final probe = ProviderProbe(
        send: (request) async => const ProviderProbeAnswer(
          statusCode: 200,
          body:
              '{"candidates":[{"content":{"parts":[{"text":"OK"}]}}]}',
        ),
      );
      final result = await probe.runOne(
        kind: ProviderProbeKind.nonStreaming,
        protocol: ProviderProtocol.google,
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        model: 'gemini-2.5-pro',
        apiKey: 'k',
      );
      expect(result.passed, isTrue);
      expect(result.detail, contains('OK'));
    });

    test('accepts a streamed Gemini answer', () async {
      final probe = ProviderProbe(
        send: (request) async => const ProviderProbeAnswer(
          statusCode: 200,
          body:
              'data: {"candidates":[{"content":{"parts":[{"text":"1"}]}}]}\n'
              'data: {"candidates":[{"content":{"parts":[{"text":"2"}]}}]}\n',
        ),
      );
      final result = await probe.runOne(
        kind: ProviderProbeKind.streaming,
        protocol: ProviderProtocol.google,
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        model: 'gemini-2.5-pro',
        apiKey: 'k',
      );
      expect(result.passed, isTrue);
    });
  });
}
