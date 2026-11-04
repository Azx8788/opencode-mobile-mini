// Reading a saved provider back into the form's model.
//
// The writer had tests; the reader did not, and it is the half that decides
// whether "edit" can be offered at all. Each case here is a shape the config
// legitimately takes: the v2 document this app writes, the v1 document an
// upgraded server still has, a hand-written entry, and one this form must
// refuse to touch.
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/custom_provider.dart';
import 'package:opencode_mobile/domain/custom_provider_record.dart';

void main() {
  group('v2 documents', () {
    final document = <String, Object?>{
      'providers': <String, Object?>{
        'openrouter': <String, Object?>{
          'package': 'aisdk:@ai-sdk/openai-compatible',
          'name': 'OpenRouter',
          'settings': <String, Object?>{
            'baseURL': 'https://openrouter.ai/api/v1',
            'apiKey': '{file:/root/.secrets/openrouter.key}',
          },
          'models': <String, Object?>{
            'a/model': <String, Object?>{'name': 'Model A'},
            'b': <String, Object?>{},
          },
        },
        'claude-proxy': <String, Object?>{
          'package': 'aisdk:@ai-sdk/anthropic',
          'settings': <String, Object?>{
            'baseURL': 'https://proxy.test/v1',
            'apiKey': 'sk-live',
          },
          'models': <String, Object?>{},
        },
        // A built-in provider override carries no package: the form cannot
        // re-emit it faithfully.
        'builtin-override': <String, Object?>{
          'name': 'OpenAI',
          'settings': <String, Object?>{'baseURL': 'https://api.openai.com/v1'},
          'models': <String, Object?>{},
        },
      },
    };

    test('reads both entries and counts the one it cannot describe', () {
      final catalogue = readCustomProviders(
        document,
        ProviderConfigFormat.v2,
      );
      expect(catalogue.records.map((record) => record.id), [
        'claude-proxy',
        'openrouter',
      ]);
      expect(catalogue.unreadable, 1);
      // Named, not just counted: the provider list shows the app's own rows
      // for ids like this, and a row must not offer to overwrite an entry it
      // could not read.
      expect(catalogue.unreadableIDs, {'builtin-override'});
    });

    test('keeps a secret file a reference, not a value', () {
      final record = readCustomProviders(
        document,
        ProviderConfigFormat.v2,
      ).records.firstWhere((record) => record.id == 'openrouter');
      expect(record.keyMode, ProviderKeyMode.secretFile);
      expect(record.apiKey, isNull);
      expect(record.secretPath, '/root/.secrets/openrouter.key');
      expect(record.models.map((model) => model.id).toSet(), {'a/model', 'b'});
      expect(record.name, 'OpenRouter');
    });

    test('reads a plaintext key as one', () {
      final record = readCustomProviders(
        document,
        ProviderConfigFormat.v2,
      ).records.firstWhere((record) => record.id == 'claude-proxy');
      expect(record.protocol, ProviderProtocol.anthropic);
      expect(record.keyMode, ProviderKeyMode.plaintext);
      expect(record.apiKey, 'sk-live');
      expect(record.models, isEmpty);
    });

    test('an edit keeps the key file the entry pointed at', () {
      final record = readCustomProviders(
        document,
        ProviderConfigFormat.v2,
      ).records.firstWhere((record) => record.id == 'openrouter');
      final draft = record.toDraft(withKey: 'sk-entered');
      expect(draft.secretPath, '/root/.secrets/openrouter.key');
      expect(draft.hasKey, isTrue);
    });
  });

  group('v1 documents', () {
    final document = <String, Object?>{
      'provider': <String, Object?>{
        'responses-gateway': <String, Object?>{
          'npm': '@ai-sdk/openai',
          'name': 'Responses',
          'options': <String, Object?>{
            'baseURL': 'https://gw.test/v1',
            'apiKey': '{env:MY_KEY}',
          },
          'models': <String, Object?>{'m': <String, Object?>{}},
        },
      },
    };

    test('maps the openai package to Responses and env keys to external', () {
      final catalogue = readCustomProviders(document, ProviderConfigFormat.v1);
      expect(catalogue.unreadable, 0);
      final record = catalogue.records.single;
      expect(record.protocol, ProviderProtocol.responses);
      // An env placeholder is the server's business; turning one into a
      // literal key would break the file.
      expect(record.keyMode, ProviderKeyMode.external);
      expect(record.apiKey, isNull);
    });
  });

  test('a document with no provider section reads as empty, not as broken', () {
    final catalogue = readCustomProviders(
      <String, Object?>{r'$schema': 'x'},
      ProviderConfigFormat.v2,
    );
    expect(catalogue.isEmpty, isTrue);
  });
}
