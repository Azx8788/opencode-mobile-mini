// The gateway a person types instead of a Claude account.
//
// The value the form can produce: what counts as an address, a key, a model.
// The file it becomes is covered by `claude_settings_test.dart` — a merge over
// decoded JSON, with no shell in between.
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/agent_auth_probe.dart';
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

  // The row must not keep the signed-out answer read before the write: a
  // settings file naming a gateway and a key is a signed-in agent by the same
  // rule its own status check applies.
  group('agentEndpointSignIn', () {
    test('a saved gateway is signed in, named by its host', () {
      final result = agentEndpointSignIn(
        const AgentEndpointStatus(
          baseUrl: 'https://gateway.example.com/v1',
          model: null,
          hasKey: true,
        ),
      );
      expect(result, isNotNull);
      expect(result!.state, AgentAuthProbeState.signedIn);
      expect(result.accountDisplayName, 'gateway.example.com');
    });

    test('an address without a key is not a sign-in', () {
      expect(
        agentEndpointSignIn(
          const AgentEndpointStatus(
            baseUrl: 'https://gateway.example.com',
            model: null,
            hasKey: false,
          ),
        ),
        isNull,
      );
    });

    test('no endpoint is no sign-in', () {
      expect(agentEndpointSignIn(AgentEndpointStatus.absent), isNull);
    });
  });

  // A provider's saved base URL keeps its `/v1` (OpenCode's AI SDK appends its
  // own endpoint suffix on top of it); Claude Code appends `/v1/messages`
  // itself, so the version segment is stripped before it is handed over.
  group('claudeCodeBaseUrl', () {
    test('strips a trailing /v1 from a new-api style address', () {
      expect(
        AgentEndpoint.claudeCodeBaseUrl('https://host/v1'),
        'https://host',
      );
    });

    test('strips a trailing /v1beta', () {
      expect(
        AgentEndpoint.claudeCodeBaseUrl('https://host/v1beta'),
        'https://host',
      );
    });

    test('strips /v1 after a prefix, keeping the prefix', () {
      expect(
        AgentEndpoint.claudeCodeBaseUrl(
          'https://api.minimaxi.com/anthropic/v1',
        ),
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
}
