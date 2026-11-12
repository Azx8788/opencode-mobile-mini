import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/agent_endpoint.dart';
import 'package:opencode_mobile/domain/claude_settings.dart';
import 'package:opencode_mobile/domain/server_gateway/value_types_catalog.dart'
    show ProductException;

AgentEndpoint _endpoint({
  String baseUrl = 'https://gateway.example.com',
  String? apiKey = 'sk-live-123',
  String? model,
}) => AgentEndpoint(baseUrl: baseUrl, apiKey: apiKey, model: model);

Map<dynamic, dynamic> _env(Map<String, Object?> settings) =>
    settings['env'] as Map<dynamic, dynamic>;

void main() {
  group('merge', () {
    test('keeps everything the file already had', () {
      final next = ClaudeSettings.merge(
        <String, Object?>{
          'permissions': <String, Object?>{
            'allow': <Object?>['Bash'],
          },
          'env': <String, Object?>{'KEEP_ME': 'yes'},
        },
        _endpoint(model: 'deepseek-v4-flash'),
        useApiKeyHeader: false,
      );
      expect(next['permissions'], <String, Object?>{
        'allow': <Object?>['Bash'],
      });
      expect(_env(next)['KEEP_ME'], 'yes');
      expect(_env(next)['ANTHROPIC_BASE_URL'], 'https://gateway.example.com');
      expect(_env(next)['ANTHROPIC_AUTH_TOKEN'], 'sk-live-123');
      expect(_env(next)['ANTHROPIC_API_KEY'], isNull);
    });

    test('a custom model fills every tier and the picker row', () {
      final next = ClaudeSettings.merge(
        const <String, Object?>{},
        _endpoint(model: 'deepseek-v4-flash'),
        useApiKeyHeader: false,
      );
      final env = _env(next);
      for (final name in ClaudeSettings.modelVariables) {
        expect(env[name], 'deepseek-v4-flash', reason: name);
      }
      final picker = next['modelPicker']! as Map<String, Object?>;
      expect(picker['replaceBuiltInOptions'], isTrue);
      final options = picker['options']! as List<Object?>;
      expect(options, hasLength(1));
      expect(options.single, <String, Object?>{
        'model': 'deepseek-v4-flash',
        'label': 'deepseek-v4-flash',
        'behavesAs': ClaudeSettings.behavesAs,
      });
    });

    test('a model Claude Code already knows keeps its own tiers', () {
      final next = ClaudeSettings.merge(
        <String, Object?>{
          'modelPicker': <String, Object?>{'replaceBuiltInOptions': true},
        },
        _endpoint(model: 'claude-sonnet-4-5'),
        useApiKeyHeader: false,
      );
      final env = _env(next);
      expect(env['ANTHROPIC_MODEL'], 'claude-sonnet-4-5');
      for (final name in ClaudeSettings.tierVariables) {
        expect(env[name], isNull, reason: name);
      }
      expect(next.containsKey('modelPicker'), isFalse);
    });

    test('no model removes the model keys and the picker', () {
      final next = ClaudeSettings.merge(
        <String, Object?>{
          'env': <String, Object?>{
            'ANTHROPIC_MODEL': 'old',
            'ANTHROPIC_DEFAULT_HAIKU_MODEL': 'old',
          },
          'modelPicker': <String, Object?>{'replaceBuiltInOptions': true},
        },
        _endpoint(),
        useApiKeyHeader: false,
      );
      final env = _env(next);
      for (final name in ClaudeSettings.modelVariables) {
        expect(env[name], isNull, reason: name);
      }
      expect(next.containsKey('modelPicker'), isFalse);
    });

    test('writes both waits, because a gateway can hold a whole answer', () {
      final env = _env(
        ClaudeSettings.merge(
          const <String, Object?>{},
          _endpoint(),
          useApiKeyHeader: false,
        ),
      );
      expect(env['API_TIMEOUT_MS'], '${ClaudeSettings.apiTimeoutMs}');
      expect(
        env['CLAUDE_STREAM_FIRST_BYTE_TIMEOUT_MS'],
        '${ClaudeSettings.firstByteTimeoutMs}',
      );
    });

    test('a key only a header probe got through becomes ANTHROPIC_API_KEY', () {
      final env = _env(
        ClaudeSettings.merge(
          <String, Object?>{
            'env': <String, Object?>{'ANTHROPIC_AUTH_TOKEN': 'sk-old'},
          },
          _endpoint(apiKey: 'sk-new'),
          useApiKeyHeader: true,
        ),
      );
      expect(env['ANTHROPIC_API_KEY'], 'sk-new');
      expect(env['ANTHROPIC_AUTH_TOKEN'], isNull);
    });

    test('no typed key keeps the one already saved', () {
      final env = _env(
        ClaudeSettings.merge(
          <String, Object?>{
            'env': <String, Object?>{'ANTHROPIC_AUTH_TOKEN': 'sk-saved'},
          },
          _endpoint(apiKey: null),
          useApiKeyHeader: false,
        ),
      );
      expect(env['ANTHROPIC_AUTH_TOKEN'], 'sk-saved');
      expect(env['ANTHROPIC_BASE_URL'], 'https://gateway.example.com');
    });

    test('no typed key and nothing saved is refused', () {
      expect(
        () => ClaudeSettings.merge(
          const <String, Object?>{},
          _endpoint(apiKey: null),
          useApiKeyHeader: false,
        ),
        throwsA(isA<ProductException>()),
      );
    });

    test('a non-map env is replaced rather than extended', () {
      final next = ClaudeSettings.merge(
        <String, Object?>{'env': 'nonsense'},
        _endpoint(),
        useApiKeyHeader: false,
      );
      expect(_env(next)['ANTHROPIC_BASE_URL'], 'https://gateway.example.com');
    });
  });

  group('clear', () {
    test('removes only the variables this app writes', () {
      final next = ClaudeSettings.clear(<String, Object?>{
        'modelPicker': <String, Object?>{'replaceBuiltInOptions': true},
        'env': <String, Object?>{
          'ANTHROPIC_BASE_URL': 'https://gateway.example.com',
          'ANTHROPIC_AUTH_TOKEN': 'sk-live-123',
          'API_TIMEOUT_MS': '600000',
          'ANTHROPIC_MODEL': 'deepseek-v4-flash',
          'ANTHROPIC_DEFAULT_HAIKU_MODEL': 'deepseek-v4-flash',
          'KEEP_ME': 'yes',
        },
        'permissions': <String, Object?>{},
      });
      expect(next['env'], <String, Object?>{'KEEP_ME': 'yes'});
      expect(next.containsKey('modelPicker'), isFalse);
      expect(next['permissions'], <String, Object?>{});
    });

    test('an env left empty is removed, and so is an empty file', () {
      final next = ClaudeSettings.clear(<String, Object?>{
        'env': <String, Object?>{'ANTHROPIC_BASE_URL': 'https://x.example'},
      });
      expect(next, isEmpty);
    });
  });

  group('onboarding', () {
    test('sets the flag that decides between setup and chat', () {
      final next = ClaudeSettings.onboarding(const <String, Object?>{});
      expect(next['hasCompletedOnboarding'], isTrue);
    });

    test('marks the folders a session already opened as trusted', () {
      final next = ClaudeSettings.onboarding(<String, Object?>{
        'hasCompletedOnboarding': false,
        'projects': <String, Object?>{
          '/home/oc/projects/a': <String, Object?>{'allowedTools': <Object?>[]},
          '/home/oc/projects/b': 'unexpected',
        },
      });
      expect(next['hasCompletedOnboarding'], isTrue);
      final projects = next['projects']! as Map<String, Object?>;
      expect(
        projects['/home/oc/projects/a'],
        <String, Object?>{
          'allowedTools': <Object?>[],
          'hasTrustDialogAccepted': true,
        },
      );
      // A value that is not an object is carried through, not replaced: it is
      // the person's, and this app does not know what it means.
      expect(projects['/home/oc/projects/b'], 'unexpected');
    });

    test('invents no project entry', () {
      final next = ClaudeSettings.onboarding(const <String, Object?>{});
      expect(next.containsKey('projects'), isFalse);
    });
  });

  group('decode and encode', () {
    test('an empty file is an empty object', () {
      expect(ClaudeSettings.decode('', 'settings'), isEmpty);
      expect(ClaudeSettings.decode('  \n', 'settings'), isEmpty);
    });

    test('comments are refused rather than dropped', () {
      expect(
        () => ClaudeSettings.decode('{\n  // mine\n  "a": 1\n}', 'settings'),
        throwsA(isA<ProductException>()),
      );
    });

    test('an array is refused', () {
      expect(
        () => ClaudeSettings.decode('[]', 'settings'),
        throwsA(isA<ProductException>()),
      );
    });

    test('encode round-trips through decode', () {
      final value = <String, Object?>{
        'env': <String, Object?>{'A': 'b'},
        'n': 1,
        'list': <Object?>[1, 2],
      };
      expect(ClaudeSettings.decode(ClaudeSettings.encode(value), 'x'), value);
      expect(jsonDecode(ClaudeSettings.encode(value)), value);
    });
  });
}
