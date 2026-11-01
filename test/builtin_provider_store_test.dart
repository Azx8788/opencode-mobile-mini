import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/builtin/builtin_linux.dart';
import 'package:opencode_mobile/builtin/builtin_provider_store.dart';
import 'package:opencode_mobile/domain/custom_provider.dart';

/// Answers the four scripts the store can send, and keeps every one of them
/// so their shell can be checked and their payloads decoded.
class _FakeServer {
  _FakeServer({
    this.resolveAnswer =
        'JSON:/root/.oc-opencode2/config/opencode/opencode.json',
  });

  String resolveAnswer;

  /// The base64 body the read script would print, or null for "missing".
  String? fileBody;

  final List<String> scripts = [];

  String? get writeScript =>
      scripts.where((s) => s.contains('mv "\$f.tmp')).lastOrNull;

  String? get keyScript =>
      scripts.where((s) => s.contains('chmod 600')).lastOrNull;

  Future<BuiltinLinuxRunResult> run(String script, Duration timeout) async {
    scripts.add(script);
    // Order matters: the read script also prints a `JSON:` marker, and the
    // write script also decodes base64.
    if (script.contains('mv "\$f.tmp') || script.contains('chmod 600')) {
      return const BuiltinLinuxRunResult(exitCode: 0, output: 'DONE');
    }
    if (script.contains('base64 "\$f"')) {
      if (fileBody == null) {
        return const BuiltinLinuxRunResult(exitCode: 0, output: 'MISSING:');
      }
      return BuiltinLinuxRunResult(exitCode: 0, output: 'JSON:$fileBody');
    }
    return BuiltinLinuxRunResult(exitCode: 0, output: resolveAnswer);
  }
}

CustomProviderDraft _draft({
  ProviderKeyMode keyMode = ProviderKeyMode.secretFile,
  String? apiKey = 'sk-very-secret',
  String id = 'my-gateway',
}) => CustomProviderDraft(
  name: 'My Gateway',
  id: id,
  protocol: ProviderProtocol.chatCompletions,
  baseUrl: 'https://api.example.com/v1',
  apiKey: apiKey,
  keyMode: keyMode,
  models: const [CustomProviderModel(id: 'deepseek-v3.2')],
);

/// `sh -n` on the generated script: a quoting mistake is a syntax error here
/// rather than a save that half-worked on someone's phone.
Future<String?> _syntaxError(String script) async {
  final process = await Process.start('sh', ['-n']);
  process.stdin.write(script);
  await process.stdin.close();
  final stderrText = await process.stderr.transform(utf8.decoder).join();
  final code = await process.exitCode;
  return code == 0 ? null : stderrText.trim();
}

void main() {
  group('resolve', () {
    test('reads OpenCode 2 own directory as v2', () async {
      final fake = _FakeServer();
      final store = BuiltinProviderStore(run: fake.run);
      final resolved = await store.resolve();
      expect(resolved.format, ProviderConfigFormat.v2);
      expect(
        resolved.relativePath,
        '.oc-opencode2/config/opencode/opencode.json',
      );
      expect(resolved.exists, true);
      expect(resolved.commentFile, false);
    });

    test('reads the OpenCode 1 path as v1 when that is what exists', () async {
      final fake = _FakeServer(
        resolveAnswer: 'JSON:/root/.config/opencode/opencode.json',
      );
      final resolved = await BuiltinProviderStore(run: fake.run).resolve();
      expect(resolved.format, ProviderConfigFormat.v1);
      expect(resolved.relativePath, '.config/opencode/opencode.json');
    });

    test(
      'a jsonc file is flagged instead of being treated as missing',
      () async {
        final fake = _FakeServer(
          resolveAnswer:
              'JSONC:/root/.oc-opencode2/config/opencode/opencode.jsonc',
        );
        final resolved = await BuiltinProviderStore(run: fake.run).resolve();
        expect(resolved.commentFile, true);
        expect(resolved.exists, true);
      },
    );

    test('a server with no config gets the OpenCode 2 path', () async {
      final fake = _FakeServer(
        resolveAnswer: 'NEW:/root/.oc-opencode2/config/opencode/opencode.json',
      );
      final resolved = await BuiltinProviderStore(run: fake.run).resolve();
      expect(
        resolved.relativePath,
        '.oc-opencode2/config/opencode/opencode.json',
      );
      expect(resolved.exists, false);
    });
  });

  group('scripts', () {
    test('resolve, read, write and key scripts are valid shell', () async {
      final fake = _FakeServer();
      final store = BuiltinProviderStore(run: fake.run);
      await store.resolve();
      await store.save(_draft());
      expect(fake.scripts.length, greaterThanOrEqualTo(4));
      for (final script in fake.scripts) {
        expect(await _syntaxError(script), isNull, reason: script);
      }
    });

    test('the write script is valid shell when there is no backup', () async {
      final fake = _FakeServer(
        resolveAnswer: 'NEW:/root/.oc-opencode2/config/opencode/opencode.json',
      )..fileBody = null;
      await BuiltinProviderStore(run: fake.run).save(_draft());
      final script = fake.writeScript!;
      expect(script.contains('cp "'), false);
      expect(await _syntaxError(script), isNull);
    });
  });

  group('save', () {
    test('writes the provider and never the raw key', () async {
      final fake = _FakeServer();
      final receipt = await BuiltinProviderStore(run: fake.run).save(_draft());
      expect(
        receipt.configPath,
        '/root/.oc-opencode2/config/opencode/opencode.json',
      );
      expect(receipt.keyFileWritten, true);
      final script = fake.writeScript!;
      final encoded = RegExp(
        r"printf '%s' '([A-Za-z0-9+/=]+)'",
      ).firstMatch(script)!.group(1)!;
      final document = jsonDecode(utf8.decode(base64Decode(encoded))) as Map;
      final provider = (document['providers'] as Map)['my-gateway'] as Map;
      expect(provider['package'], 'aisdk:@ai-sdk/openai-compatible');
      expect(
        (provider['settings'] as Map)['apiKey'],
        '{file:/root/.secrets/my-gateway.key}',
      );
      expect(
        utf8.decode(base64Decode(encoded)).contains('sk-very-secret'),
        false,
      );
    });

    test('writes the key into its own 600 file', () async {
      final fake = _FakeServer();
      await BuiltinProviderStore(run: fake.run).save(_draft());
      final script = fake.keyScript!;
      expect(script.contains('chmod 600'), true);
      expect(script.contains('/root/.secrets/my-gateway.key'), true);
      final encoded = RegExp(
        r"printf '%s' '([A-Za-z0-9+/=]+)'",
      ).firstMatch(script)!.group(1)!;
      expect(utf8.decode(base64Decode(encoded)), 'sk-very-secret');
    });

    test('keeps what the existing file already had', () async {
      final existing = {
        r'$schema': 'https://opencode.ai/config.json',
        'model': 'anthropic/claude',
        'providers': {
          'other': {'package': 'aisdk:@ai-sdk/openai'},
        },
      };
      final fake = _FakeServer()
        ..fileBody = base64Encode(utf8.encode(jsonEncode(existing)));
      await BuiltinProviderStore(run: fake.run).save(_draft());
      final script = fake.writeScript!;
      final encoded = RegExp(
        r"printf '%s' '([A-Za-z0-9+/=]+)'",
      ).firstMatch(script)!.group(1)!;
      final document = jsonDecode(utf8.decode(base64Decode(encoded))) as Map;
      expect(document[r'$schema'], 'https://opencode.ai/config.json');
      expect(document['model'], 'anthropic/claude');
      expect((document['providers'] as Map).keys.toSet(), {
        'other',
        'my-gateway',
      });
    });

    test('refuses a jsonc config rather than dropping its comments', () async {
      final fake = _FakeServer(
        resolveAnswer:
            'JSONC:/root/.oc-opencode2/config/opencode/opencode.jsonc',
      );
      await expectLater(
        BuiltinProviderStore(run: fake.run).save(_draft()),
        throwsA(
          isA<ProviderWriteRefused>().having(
            (e) => e.reason,
            'reason',
            'jsonc',
          ),
        ),
      );
      expect(fake.writeScript, isNull);
    });

    test('refuses to replace a provider with the same id', () async {
      final existing = {
        'providers': {
          'my-gateway': {'package': 'aisdk:@ai-sdk/openai'},
        },
      };
      final fake = _FakeServer()
        ..fileBody = base64Encode(utf8.encode(jsonEncode(existing)));
      await expectLater(
        BuiltinProviderStore(run: fake.run).save(_draft()),
        throwsA(isA<ProviderWriteRefused>()),
      );
      expect(fake.writeScript, isNull);
    });

    test('a server with no config starts from this provider alone', () async {
      final fake = _FakeServer();
      await BuiltinProviderStore(run: fake.run).save(_draft());
      final script = fake.writeScript!;
      final encoded = RegExp(
        r"printf '%s' '([A-Za-z0-9+/=]+)'",
      ).firstMatch(script)!.group(1)!;
      final document = jsonDecode(utf8.decode(base64Decode(encoded))) as Map;
      expect((document['providers'] as Map).keys, ['my-gateway']);
    });
  });
}
