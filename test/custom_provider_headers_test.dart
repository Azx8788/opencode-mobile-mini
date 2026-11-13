// Extra headers and protocol switching: what the advanced tab writes and
// what changing the protocol does to an address already typed.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/custom_provider.dart';
import 'package:opencode_mobile/domain/custom_provider_record.dart';

void main() {
  CustomProviderDraft draft({
    ProviderProtocol protocol = ProviderProtocol.chatCompletions,
    String baseUrl = 'https://api.example.com/v1',
    List<CustomProviderHeader> headers = const [],
  }) => CustomProviderDraft(
    name: 'My Gateway',
    id: 'my-gateway',
    protocol: protocol,
    baseUrl: baseUrl,
    apiKey: 'sk-test',
    models: const [CustomProviderModel(id: 'model-a')],
    headers: headers,
  );

  group('custom headers', () {
    test('v1 writes them under options.headers', () {
      final entry = draft(
        headers: const [
          CustomProviderHeader(name: 'HTTP-Referer', value: 'https://app'),
          CustomProviderHeader(name: 'X-Title', value: 'OpenCode Plus'),
        ],
      ).toProviderEntry(ProviderConfigFormat.v1);
      expect(entry['options'], isA<Map>());
      final options = entry['options'] as Map;
      expect(options['headers'], {
        'HTTP-Referer': 'https://app',
        'X-Title': 'OpenCode Plus',
      });
    });

    test('v2 writes them under settings.headers', () {
      final entry = draft(
        headers: const [
          CustomProviderHeader(name: 'User-Agent', value: 'mini/1.0'),
        ],
      ).toProviderEntry(ProviderConfigFormat.v2);
      final settings = entry['settings'] as Map;
      expect(settings['headers'], {'User-Agent': 'mini/1.0'});
    });

    test('half-filled rows are dropped and names are unique', () {
      final entry = draft(
        headers: const [
          CustomProviderHeader(name: '', value: 'x'),
          CustomProviderHeader(name: 'X-Title', value: ''),
          CustomProviderHeader(name: 'X-Title', value: 'first'),
          CustomProviderHeader(name: 'x-title', value: 'second'),
        ],
      ).toProviderEntry(ProviderConfigFormat.v1);
      final headers = (entry['options'] as Map)['headers'] as Map;
      expect(headers.length, 1);
      expect(headers['x-title'], 'second');
    });

    test('a saved entry reads its headers back', () {
      final document = draft(
        headers: const [
          CustomProviderHeader(name: 'HTTP-Referer', value: 'https://app'),
        ],
      ).toDocument(ProviderConfigFormat.v2);
      final catalogue = readCustomProviders(
        jsonDecode(jsonEncode(document)) as Map<String, Object?>,
        ProviderConfigFormat.v2,
      );
      expect(catalogue.records.single.headers, const [
        CustomProviderHeader(name: 'HTTP-Referer', value: 'https://app'),
      ]);
    });

    test('no headers means no empty object in the config', () {
      final entry = draft().toProviderEntry(ProviderConfigFormat.v2);
      expect((entry['settings'] as Map).containsKey('headers'), isFalse);
    });
  });

  group('protocol switching', () {
    test('moves an official /v1 root to /v1beta for Google', () {
      final switched = draft(
        baseUrl: 'https://generativelanguage.googleapis.com/v1',
      ).switchProtocol(ProviderProtocol.google);
      expect(switched.baseUrl, 'https://generativelanguage.googleapis.com/v1beta');
    });

    test('moves /v1beta back to /v1 for the other protocols', () {
      final switched = draft(
        protocol: ProviderProtocol.google,
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
      ).switchProtocol(ProviderProtocol.anthropic);
      expect(switched.baseUrl, 'https://generativelanguage.googleapis.com/v1');
    });

    test('keeps a custom path exactly as typed', () {
      final switched = draft(
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      ).switchProtocol(ProviderProtocol.google);
      expect(switched.baseUrl, 'https://open.bigmodel.cn/api/paas/v4');
    });

    test('strips a pasted endpoint before switching', () {
      final switched = draft(
        baseUrl: 'https://api.example.com/v1/chat/completions',
      ).switchProtocol(ProviderProtocol.anthropic);
      expect(switched.baseUrl, 'https://api.example.com/v1');
    });

    test('carries the key, models and headers across', () {
      final switched = draft(
        headers: const [
          CustomProviderHeader(name: 'X-Title', value: 'app'),
        ],
      ).switchProtocol(ProviderProtocol.responses);
      expect(switched.apiKey, 'sk-test');
      expect(switched.models.single.id, 'model-a');
      expect(switched.headers.single.name, 'X-Title');
    });

    test('changing the protocol changes the package saved', () {
      final switched = draft().switchProtocol(ProviderProtocol.google);
      expect(
        switched.toProviderEntry(ProviderConfigFormat.v2)['package'],
        'aisdk:@ai-sdk/google',
      );
    });
  });

  group('google base URLs', () {
    test('a pasted /models suffix is removed', () {
      expect(
        CustomProviderDraft.normalizeBaseUrl(
          'https://generativelanguage.googleapis.com/v1beta/models',
          ProviderProtocol.google,
        ),
        'https://generativelanguage.googleapis.com/v1beta',
      );
    });
  });
}
