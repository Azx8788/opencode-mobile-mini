import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/agent_auth_probe.dart';

void main() {
  test('a signed-in answer keeps the key names the script saw', () {
    final result = AgentAuthProbeResult.fromJson(<String, dynamic>{
      'state': 'signedIn',
      'accountDisplayName': 'agentrouter.org',
      'envKeys': <String>[
        'ANTHROPIC_BASE_URL',
        'ANTHROPIC_AUTH_TOKEN',
        'API_TIMEOUT_MS',
      ],
    });
    expect(result.state, AgentAuthProbeState.signedIn);
    expect(result.scriptEnvKeys, <String>[
      'ANTHROPIC_BASE_URL',
      'ANTHROPIC_AUTH_TOKEN',
      'API_TIMEOUT_MS',
    ]);
  });

  test('only names that could be a variable survive', () {
    final result = AgentAuthProbeResult.fromJson(<String, dynamic>{
      'state': 'signedOut',
      'envKeys': <Object?>[
        'ANTHROPIC_BASE_URL',
        'not a name',
        'lowercase',
        '1LEADING_DIGIT',
        '',
        List.filled(65, 'A').join(),
        42,
      ],
    });
    expect(result.state, AgentAuthProbeState.signedOut);
    expect(result.scriptEnvKeys, <String>['ANTHROPIC_BASE_URL']);
  });

  test('no list means no names, not an error', () {
    final result = AgentAuthProbeResult.fromJson(<String, dynamic>{
      'state': 'signedIn',
      'accountDisplayName': 'claude.ai',
    });
    expect(result.scriptEnvKeys, isEmpty);
  });

  test('the existing strictness is unchanged', () {
    // A signed-out answer that also names an account is contradictory.
    final contradictory = AgentAuthProbeResult.fromJson(<String, dynamic>{
      'state': 'signedOut',
      'accountDisplayName': 'someone@example.com',
    });
    expect(contradictory.state, AgentAuthProbeState.error);
    expect(contradictory.error, AgentAuthProbeError.invalidResponse);
    expect(contradictory.scriptEnvKeys, isEmpty);
  });
}
