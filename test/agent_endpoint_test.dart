// The gateway a person types instead of a Claude account.
//
// Two layers are covered: the value the form can produce (what counts as an
// address, a key, a model) and the program that writes it into Claude Code's
// own settings file. The second runs the real script against a temporary
// home, so a key that would break the shell, a symlinked path, a damaged
// settings file and "change the address, keep the key" are all exercised
// rather than described.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/builtin/agents/agent_endpoint_scripts.dart';
import 'package:opencode_mobile/domain/agent_endpoint.dart';

void main() {
  group('AgentEndpoint', () {
    test('keeps the address as typed, without a trailing slash', () {
      final endpoint = AgentEndpoint(
        baseUrl: 'https://gateway.example.com/v1/',
        apiKey: 'sk-test',
      );
      expect(endpoint.baseUrl, 'https://gateway.example.com/v1');
      expect(endpoint.host, 'gateway.example.com');
      expect(endpoint.isSecure, isTrue);
    });

    test('keeps a port and a path', () {
      final endpoint = AgentEndpoint(
        baseUrl: 'http://192.168.1.9:8080/anthropic',
        apiKey: 'k',
      );
      expect(endpoint.baseUrl, 'http://192.168.1.9:8080/anthropic');
      expect(endpoint.isSecure, isFalse);
    });

    test('refuses an address that is not http(s)', () {
      expect(
        () => AgentEndpoint(baseUrl: 'gateway.example.com', apiKey: 'k'),
        throwsA(isA<Exception>()),
      );
      expect(
        () => AgentEndpoint(baseUrl: 'ftp://gateway.example.com', apiKey: 'k'),
        throwsA(isA<Exception>()),
      );
    });

    test('refuses a query, a fragment and a user', () {
      for (final value in [
        'https://gateway.example.com/?x=1',
        'https://gateway.example.com/#frag',
        'https://user:pass@gateway.example.com',
      ]) {
        expect(
          () => AgentEndpoint(baseUrl: value, apiKey: 'k'),
          throwsA(isA<Exception>()),
          reason: value,
        );
      }
    });

    test('a key is optional only when one is already saved', () {
      final kept = AgentEndpoint(baseUrl: 'https://gateway.example.com');
      expect(kept.apiKey, isNull);
      expect(
        () =>
            AgentEndpoint(baseUrl: 'https://gateway.example.com', apiKey: '  '),
        throwsA(isA<Exception>()),
      );
    });

    test('refuses a key that is not one line', () {
      expect(
        () => AgentEndpoint(
          baseUrl: 'https://gateway.example.com',
          apiKey: 'sk-a\nsk-b',
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('an empty model is no model, and a model is a name', () {
      final none = AgentEndpoint(
        baseUrl: 'https://gateway.example.com',
        apiKey: 'k',
        model: '  ',
      );
      expect(none.model, isNull);
      final named = AgentEndpoint(
        baseUrl: 'https://gateway.example.com',
        apiKey: 'k',
        model: 'claude-sonnet-4-5',
      );
      expect(named.model, 'claude-sonnet-4-5');
      expect(
        () => AgentEndpoint(
          baseUrl: 'https://gateway.example.com',
          apiKey: 'k',
          model: 'bad model',
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('never prints the key', () {
      final endpoint = AgentEndpoint(
        baseUrl: 'https://gateway.example.com',
        apiKey: 'sk-very-secret',
      );
      expect(endpoint.toString(), isNot(contains('sk-very-secret')));
      expect(endpoint.toString(), contains('gateway.example.com'));
    });

    test('only Claude Code documents the endpoint keys', () {
      expect(agentSupportsEndpoint('claude'), isTrue);
      for (final id in ['codex', 'gemini', 'qwen', 'kilo', 'cline', 'fx']) {
        expect(agentSupportsEndpoint(id), isFalse, reason: id);
      }
    });
  });

  // A provider's saved base URL keeps its `/v1` (OpenCode's AI SDK appends its
  // own endpoint suffix on top of it); Claude Code appends `/v1/messages`
  // itself, so the version segment is stripped before it is handed over.
  group('claudeCodeBaseUrl', () {
    test('strips a trailing /v1 from a new-api style address', () {
      expect(AgentEndpoint.claudeCodeBaseUrl('https://host/v1'), 'https://host');
    });

    test('strips a trailing /v1beta', () {
      expect(
        AgentEndpoint.claudeCodeBaseUrl('https://host/v1beta'),
        'https://host',
      );
    });

    test('strips /v1 after a prefix, keeping the prefix', () {
      expect(
        AgentEndpoint.claudeCodeBaseUrl('https://api.minimaxi.com/anthropic/v1'),
        'https://api.minimaxi.com/anthropic',
      );
    });

    test('keeps a non-version path such as an /anthropic prefix', () {
      expect(
        AgentEndpoint.claudeCodeBaseUrl('https://host/anthropic'),
        'https://host/anthropic',
      );
    });

    test('keeps a bare host', () {
      expect(AgentEndpoint.claudeCodeBaseUrl('https://host'), 'https://host');
    });

    test('keeps a port', () {
      expect(
        AgentEndpoint.claudeCodeBaseUrl('http://192.168.1.9:8080/v1'),
        'http://192.168.1.9:8080',
      );
    });

    test('strips a trailing slash before the version segment', () {
      expect(
        AgentEndpoint.claudeCodeBaseUrl('https://host/v1/'),
        'https://host',
      );
    });

    test('refuses an empty address', () {
      expect(
        () => AgentEndpoint.claudeCodeBaseUrl(''),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('the settings writer', () {
    late Directory root;
    late Directory home;
    late String config;

    setUp(() {
      root = Directory.systemTemp.createTempSync('oc-endpoint-');
      // The script's own guard names /home/oc/.oc-profiles; the test moves
      // that prefix to a temporary directory so the same program runs.
      home = Directory('${root.path}/.oc-profiles/test')
        ..createSync(recursive: true);
      config = '${home.path}/claude';
      Directory(config).createSync(recursive: true);
    });

    tearDown(() => root.deleteSync(recursive: true));

    /// The script is the shipped one; only the profile's home moves to the
    /// temporary directory, so the program under test is unchanged.
    String script(String action, {AgentEndpoint? endpoint}) {
      final raw = AgentEndpointScripts.claude(
        profileId: 'test',
        action: action,
        endpoint: endpoint,
      );
      final match = RegExp(r"python3 - '([A-Za-z0-9+/=]+)'").firstMatch(raw)!;
      final payload =
          jsonDecode(utf8.decode(base64.decode(match.group(1)!)))
              as Map<String, dynamic>;
      payload['home'] = home.path;
      final data = base64.encode(utf8.encode(jsonEncode(payload)));
      return raw
          .replaceFirst(match.group(1)!, data)
          .replaceAll('/home/oc', root.path);
    }

    Map<String, dynamic> settings() =>
        jsonDecode(File('$config/settings.json').readAsStringSync())
            as Map<String, dynamic>;

    test('writes the three keys and leaves the rest of the file alone', () {
      File('$config/settings.json').writeAsStringSync(
        jsonEncode({
          'permissions': {
            'allow': ['Bash'],
          },
          'env': {'KEEP_ME': 'yes'},
        }),
      );
      final result = Process.runSync('sh', [
        '-c',
        script(
          'write',
          endpoint: AgentEndpoint(
            baseUrl: 'https://gateway.example.com/v1',
            apiKey: 'sk-live-123',
            model: 'claude-sonnet-4-5',
          ),
        ),
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final data = settings();
      expect(data['permissions'], {
        'allow': ['Bash'],
      });
      expect((data['env'] as Map)['KEEP_ME'], 'yes');
      expect(
        (data['env'] as Map)['ANTHROPIC_BASE_URL'],
        'https://gateway.example.com/v1',
      );
      expect((data['env'] as Map)['ANTHROPIC_AUTH_TOKEN'], 'sk-live-123');
      expect((data['env'] as Map)['ANTHROPIC_MODEL'], 'claude-sonnet-4-5');
    });

    test('keeps the saved key when none is typed', () {
      File('$config/settings.json').writeAsStringSync(
        jsonEncode({
          'env': {'ANTHROPIC_AUTH_TOKEN': 'sk-saved'},
        }),
      );
      final result = Process.runSync('sh', [
        '-c',
        script(
          'write',
          endpoint: AgentEndpoint(
            baseUrl: 'https://other.example.com',
            model: 'claude-haiku-4-5',
          ),
        ),
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final env = settings()['env'] as Map;
      expect(env['ANTHROPIC_AUTH_TOKEN'], 'sk-saved');
      expect(env['ANTHROPIC_BASE_URL'], 'https://other.example.com');
      expect(env['ANTHROPIC_MODEL'], 'claude-haiku-4-5');
    });

    test('refuses to keep a key that is not there', () {
      final result = Process.runSync('sh', [
        '-c',
        script(
          'write',
          endpoint: AgentEndpoint(baseUrl: 'https://gateway.example.com'),
        ),
      ]);
      expect(result.exitCode, 24);
      expect(File('$config/settings.json').existsSync(), isFalse);
    });

    test('a damaged settings file is never overwritten', () {
      File('$config/settings.json').writeAsStringSync('{not json');
      final result = Process.runSync('sh', [
        '-c',
        script(
          'write',
          endpoint: AgentEndpoint(
            baseUrl: 'https://gateway.example.com',
            apiKey: 'k',
          ),
        ),
      ]);
      expect(result.exitCode, 21);
      expect(File('$config/settings.json').readAsStringSync(), '{not json');
    });

    test('clearing removes only this app\u2019s keys', () {
      File('$config/settings.json').writeAsStringSync(
        jsonEncode({
          'env': {
            'KEEP_ME': 'yes',
            'ANTHROPIC_BASE_URL': 'https://gateway.example.com',
            'ANTHROPIC_AUTH_TOKEN': 'sk-saved',
            'ANTHROPIC_MODEL': 'claude-sonnet-4-5',
          },
        }),
      );
      final result = Process.runSync('sh', ['-c', script('clear')]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(settings()['env'], {'KEEP_ME': 'yes'});
    });

    test('clearing a file this app filled removes the file', () {
      File('$config/settings.json').writeAsStringSync(
        jsonEncode({
          'env': {
            'ANTHROPIC_BASE_URL': 'https://gateway.example.com',
            'ANTHROPIC_AUTH_TOKEN': 'sk-saved',
          },
        }),
      );
      expect(Process.runSync('sh', ['-c', script('clear')]).exitCode, 0);
      expect(File('$config/settings.json').existsSync(), isFalse);
    });

    test('a symlinked settings file is refused', () {
      final target = File('${home.path}/elsewhere.json')
        ..writeAsStringSync('{}');
      Link('$config/settings.json').createSync(target.path);
      final result = Process.runSync('sh', [
        '-c',
        script(
          'write',
          endpoint: AgentEndpoint(
            baseUrl: 'https://gateway.example.com',
            apiKey: 'k',
          ),
        ),
      ]);
      expect(result.exitCode, 22);
      expect(target.readAsStringSync(), '{}');
    });

    test('the script never contains the key in the clear', () {
      final raw = AgentEndpointScripts.claude(
        profileId: 'test',
        action: 'write',
        endpoint: AgentEndpoint(
          baseUrl: 'https://gateway.example.com',
          apiKey: "sk-'quoted\"key",
        ),
      );
      expect(raw, isNot(contains("sk-'quoted")));
      expect(raw, isNot(contains('quoted"key')));
    });
  });
}
