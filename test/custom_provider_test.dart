import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/custom_provider.dart';
import 'package:opencode_mobile/domain/provider_model_source.dart';

void main() {
  CustomProviderDraft draft({
    String name = 'My Gateway',
    String id = 'my-gateway',
    ProviderProtocol protocol = ProviderProtocol.chatCompletions,
    String baseUrl = 'https://api.example.com/v1',
    String? apiKey = 'sk-test',
    ProviderKeyMode keyMode = ProviderKeyMode.secretFile,
    List<CustomProviderModel> models = const [
      CustomProviderModel(id: 'deepseek-v3.2'),
    ],
  }) => CustomProviderDraft(
    name: name,
    id: id,
    protocol: protocol,
    baseUrl: baseUrl,
    apiKey: apiKey,
    keyMode: keyMode,
    models: models,
  );

  group('protocol to package', () {
    test('v1 uses the bare npm names', () {
      expect(ProviderProtocol.chatCompletions.npm, '@ai-sdk/openai-compatible');
      expect(ProviderProtocol.responses.npm, '@ai-sdk/openai');
      expect(ProviderProtocol.anthropic.npm, '@ai-sdk/anthropic');
    });

    test('v2 always carries the aisdk: prefix', () {
      // A bare @ai-sdk name is read as a native provider by v2 and fails only
      // when a message is sent (upstream #44881).
      for (final protocol in ProviderProtocol.values) {
        expect(protocol.package, startsWith('aisdk:@ai-sdk/'));
      }
    });
  });

  group('base URL', () {
    test('strips a pasted endpoint suffix and keeps the path', () {
      expect(
        CustomProviderDraft.normalizeBaseUrl(
          'https://api.example.com/v1/chat/completions',
          ProviderProtocol.chatCompletions,
        ),
        'https://api.example.com/v1',
      );
      expect(
        CustomProviderDraft.normalizeBaseUrl(
          'https://api.minimax.io/anthropic/v1/messages',
          ProviderProtocol.anthropic,
        ),
        'https://api.minimax.io/anthropic/v1',
      );
      expect(
        CustomProviderDraft.normalizeBaseUrl(
          'https://api.openai.com/v1/responses',
          ProviderProtocol.responses,
        ),
        'https://api.openai.com/v1',
      );
    });

    test('does not invent a /v1 path', () {
      // DeepSeek's endpoint has no /v1; Venice's has /api/v1; Bailing's shows
      // the whole path. Rewriting any of them invents endpoints that 404.
      expect(
        CustomProviderDraft.normalizeBaseUrl(
          'https://api.deepseek.com',
          ProviderProtocol.chatCompletions,
        ),
        'https://api.deepseek.com',
      );
      expect(
        CustomProviderDraft.normalizeBaseUrl(
          'https://api.venice.ai/api/v1',
          ProviderProtocol.chatCompletions,
        ),
        'https://api.venice.ai/api/v1',
      );
    });

    test('adds https and drops trailing slashes', () {
      expect(
        CustomProviderDraft.normalizeBaseUrl(
          'api.example.com/v1/',
          ProviderProtocol.chatCompletions,
        ),
        'https://api.example.com/v1',
      );
    });

    test('leaves unrelated suffixes alone', () {
      expect(
        CustomProviderDraft.normalizeBaseUrl(
          'https://gw.example.com/openai',
          ProviderProtocol.chatCompletions,
        ),
        'https://gw.example.com/openai',
      );
    });
  });

  group('provider id', () {
    test('is lowercased and made safe for a config key and a file name', () {
      expect(
        CustomProviderDraft.normalizeProviderId('  My Gateway / 中转  '),
        'my-gateway',
      );
      expect(CustomProviderDraft.normalizeProviderId('---'), 'custom');
      expect(CustomProviderDraft.normalizeProviderId(''), 'custom');
      expect(CustomProviderDraft.normalizeProviderId('a' * 80).length, 48);
    });
  });

  group('models', () {
    test('are deduplicated in order and blanks dropped', () {
      final models = CustomProviderDraft.normalizeModels(const [
        CustomProviderModel(id: 'b'),
        CustomProviderModel(id: 'a'),
        CustomProviderModel(id: 'b'),
        CustomProviderModel(id: '  '),
        CustomProviderModel(id: ' c '),
      ]);
      expect(models.map((m) => m.id), ['b', 'a', 'c']);
    });

    test('a display name wins over the id for the label', () {
      expect(
        const CustomProviderModel(id: 'x', name: 'X Model').label,
        'X Model',
      );
      expect(const CustomProviderModel(id: 'x').label, 'x');
    });
  });

  group('v1 document', () {
    test('writes the old keys and the file key reference', () {
      final document = draft().toDocument(ProviderConfigFormat.v1);
      final provider = (document['provider'] as Map)['my-gateway'] as Map;
      expect(provider['npm'], '@ai-sdk/openai-compatible');
      expect(provider['name'], 'My Gateway');
      final options = provider['options'] as Map;
      expect(options['baseURL'], 'https://api.example.com/v1');
      expect(options['apiKey'], '{file:/root/.secrets/my-gateway.key}');
      expect(options['timeout'], 600000);
      final model = (provider['models'] as Map)['deepseek-v3.2'] as Map;
      expect(model['tool_call'], true);
      expect(model.containsKey('capabilities'), false);
    });

    test('never contains the raw key when the key is a file', () {
      final text = draft().toDocument(ProviderConfigFormat.v1).toString();
      expect(text.contains('sk-test'), false);
    });

    test('keeps temperature off for the responses protocol', () {
      final document = draft(
        protocol: ProviderProtocol.responses,
        baseUrl: 'https://api.openai.com/v1',
      ).toDocument(ProviderConfigFormat.v1);
      final provider = (document['provider'] as Map)['my-gateway'] as Map;
      final model = (provider['models'] as Map)['deepseek-v3.2'] as Map;
      expect(model['temperature'], false);
      expect(model['reasoning'], false);
    });
  });

  group('v2 document', () {
    test('uses providers, package and settings', () {
      final document = draft().toDocument(ProviderConfigFormat.v2);
      expect(document.containsKey('providers'), true);
      final provider = (document['providers'] as Map)['my-gateway'] as Map;
      expect(provider['package'], 'aisdk:@ai-sdk/openai-compatible');
      final settings = provider['settings'] as Map;
      expect(settings['baseURL'], 'https://api.example.com/v1');
      expect(settings['apiKey'], '{file:/root/.secrets/my-gateway.key}');
    });

    test('capabilities use the schema shape, not the v1 spellings', () {
      // `capabilities` is additionalProperties:false with `input`/`output` as
      // arrays and `reasoning` as an object. A scalar `input`, a boolean
      // `reasoning` or a v1 `tool_call` would be rejected.
      final document = draft().toDocument(ProviderConfigFormat.v2);
      final provider = (document['providers'] as Map)['my-gateway'] as Map;
      final model = (provider['models'] as Map)['deepseek-v3.2'] as Map;
      final capabilities = model['capabilities'] as Map;
      expect(capabilities['tools'], true);
      expect(capabilities['input'], isA<List>());
      expect(capabilities['input'], ['text']);
      expect(capabilities['output'], ['text']);
      expect(capabilities.containsKey('tool_call'), false);
      // Left out deliberately: one gateway serves reasoning and plain models
      // from one endpoint, so claiming it would break the plain ones.
      expect(capabilities.containsKey('reasoning'), false);
    });

    test('promises image input only where the protocol carries it', () {
      Map modelOf(ProviderProtocol protocol, String url) {
        final document = draft(
          protocol: protocol,
          baseUrl: url,
        ).toDocument(ProviderConfigFormat.v2);
        final provider = (document['providers'] as Map)['my-gateway'] as Map;
        return (provider['models'] as Map)['deepseek-v3.2'] as Map;
      }

      expect(
        (modelOf(
              ProviderProtocol.anthropic,
              'https://api.anthropic.com/v1',
            )['capabilities']
            as Map)['input'],
        ['text', 'image'],
      );
      expect(
        (modelOf(
              ProviderProtocol.responses,
              'https://api.openai.com/v1',
            )['capabilities']
            as Map)['input'],
        ['text', 'image'],
      );
    });

    test('keeps temperature out of the responses protocol', () {
      final document = draft(
        protocol: ProviderProtocol.responses,
        baseUrl: 'https://api.openai.com/v1',
      ).toDocument(ProviderConfigFormat.v2);
      final provider = (document['providers'] as Map)['my-gateway'] as Map;
      final capabilities =
          ((provider['models'] as Map)['deepseek-v3.2'] as Map)['capabilities']
              as Map;
      expect(capabilities.containsKey('temperature'), false);
    });
  });

  group('key modes', () {
    test('plaintext writes the key only when asked', () {
      final document = draft(
        keyMode: ProviderKeyMode.plaintext,
      ).toDocument(ProviderConfigFormat.v1);
      final options =
          (document['provider'] as Map)['my-gateway']['options'] as Map;
      expect(options['apiKey'], 'sk-test');
    });

    test('external leaves the key out entirely', () {
      final document = draft(
        keyMode: ProviderKeyMode.external,
        apiKey: null,
      ).toDocument(ProviderConfigFormat.v1);
      final options =
          (document['provider'] as Map)['my-gateway']['options'] as Map;
      expect(options.containsKey('apiKey'), false);
    });

    test('a missing key is refused in plaintext mode', () {
      expect(
        () => draft(keyMode: ProviderKeyMode.plaintext, apiKey: ' ').validate(),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('merge', () {
    test('into an empty file keeps the provider alone', () {
      final document = draft().mergeInto(null, ProviderConfigFormat.v1);
      expect((document['provider'] as Map).keys, ['my-gateway']);
    });

    test('keeps settings the person already had', () {
      final existing = <String, Object?>{
        r'$schema': 'https://opencode.ai/config.json',
        'model': 'anthropic/claude',
        'provider': {
          'other': {'npm': '@ai-sdk/openai'},
        },
      };
      final document = draft().mergeInto(existing, ProviderConfigFormat.v1);
      expect(document[r'$schema'], 'https://opencode.ai/config.json');
      expect(document['model'], 'anthropic/claude');
      final providers = document['provider'] as Map;
      expect(providers.keys.toSet(), {'other', 'my-gateway'});
    });

    test('refuses to replace an existing provider of the same id', () {
      final existing = <String, Object?>{
        'provider': {
          'my-gateway': {'npm': '@ai-sdk/openai'},
        },
      };
      expect(
        () => draft().mergeInto(existing, ProviderConfigFormat.v1),
        throwsA(isA<Exception>()),
      );
    });

    test('replaces the same id when the edit path asks it to', () {
      final existing = <String, Object?>{
        'provider': {
          'my-gateway': {
            'npm': '@ai-sdk/openai',
            'options': {'baseURL': 'https://old.test/v1'},
          },
        },
      };
      final document = draft().mergeInto(
        existing,
        ProviderConfigFormat.v1,
        replace: true,
      );
      final entry =
          (document['provider'] as Map)['my-gateway'] as Map;
      expect(entry['npm'], '@ai-sdk/openai-compatible');
      expect((entry['options'] as Map)['baseURL'], 'https://api.example.com/v1');
    });
  });

  group('validation', () {
    test('rejects a blank name, url, or empty model list', () {
      expect(() => draft(name: ' ').validate(), throwsA(isA<Exception>()));
      expect(() => draft(baseUrl: '').validate(), throwsA(isA<Exception>()));
      expect(
        () => draft(models: const []).validate(),
        throwsA(isA<Exception>()),
      );
    });

    test('rejects a base URL that is not http(s)', () {
      expect(
        () => draft(baseUrl: 'ftp://example.com').validate(),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('model list parsing', () {
    test('reads the OpenAI/NewAPI envelope', () {
      final models = ProviderModelSource.parseModelList(
        '{"object":"list","data":[{"id":"gpt-4o"},{"id":"deepseek-v3"}]}',
      );
      expect(models.map((m) => m.id), ['gpt-4o', 'deepseek-v3']);
    });

    test('reads a bare array and a models key', () {
      expect(ProviderModelSource.parseModelList('["a","b"]').map((m) => m.id), [
        'a',
        'b',
      ]);
      expect(
        ProviderModelSource.parseModelList(
          '{"models":[{"model":"qwen"}]}',
        ).map((m) => m.id),
        ['qwen'],
      );
    });

    test('reads the Anthropic display name', () {
      final models = ProviderModelSource.parseModelList(
        '{"data":[{"id":"claude-sonnet-4","display_name":"Claude Sonnet 4"}]}',
      );
      expect(models.single.label, 'Claude Sonnet 4');
    });

    test('an unreadable body is an empty list, not a crash', () {
      expect(ProviderModelSource.parseModelList('<html>'), isEmpty);
      expect(ProviderModelSource.parseModelList(''), isEmpty);
    });
  });

  group('fetch', () {
    test('falls back to /v1/models when the bare host 404s', () async {
      final asked = <String>[];
      final source = ProviderModelSource(
        get: (url, headers, timeout) async {
          asked.add(url.toString());
          if (url.path == '/models') {
            return const ProviderHttpAnswer(statusCode: 404, body: '');
          }
          return const ProviderHttpAnswer(
            statusCode: 200,
            body: '{"data":[{"id":"m"}]}',
          );
        },
      );
      final listing = await source.fetch(
        baseUrl: 'https://gw.example.com',
        protocol: ProviderProtocol.chatCompletions,
        apiKey: 'k',
      );
      expect(listing.models.single.id, 'm');
      expect(listing.url.path, '/v1/models');
      expect(asked, [
        'https://gw.example.com/models',
        'https://gw.example.com/v1/models',
      ]);
    });

    test('sends the native Anthropic header first', () async {
      final headers = <Map<String, String>>[];
      final source = ProviderModelSource(
        get: (url, sent, timeout) async {
          headers.add(sent);
          return const ProviderHttpAnswer(
            statusCode: 200,
            body: '{"data":[{"id":"claude"}]}',
          );
        },
      );
      await source.fetch(
        baseUrl: 'https://api.anthropic.com/v1',
        protocol: ProviderProtocol.anthropic,
        apiKey: 'k',
      );
      expect(headers.first['x-api-key'], 'k');
      expect(headers.first.containsKey('Authorization'), false);
    });

    test('a refused key is reported as such', () async {
      final source = ProviderModelSource(
        get: (url, headers, timeout) async =>
            const ProviderHttpAnswer(statusCode: 401, body: ''),
      );
      await expectLater(
        source.fetch(
          baseUrl: 'https://gw.example.com/v1',
          protocol: ProviderProtocol.chatCompletions,
          apiKey: 'bad',
        ),
        throwsA(
          isA<ProviderModelFetchFailure>().having(
            (f) => f.canRetryWithoutKey,
            'canRetryWithoutKey',
            true,
          ),
        ),
      );
    });
  });
}
