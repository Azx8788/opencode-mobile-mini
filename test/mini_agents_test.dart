// Smoke tests for the agent surface.
//
// The app ships every agent the upstream catalog pins: OpenCode 2 (runs in
// the app's Linux), Claude Code and Codex (Paseo's own providers), and the
// ACP agents Gemini CLI, Qwen Code, Kilo, Cline, Goose, Oh My Pi and fx.
// These tests fail if a catalog entry is dropped by accident, if one loses its
// arm64 artifact, or if an id repeats.
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/agent_catalog.dart';

void main() {
  const ids = <String>[
    'opencode2',
    'claude',
    'codex',
    'gemini',
    'qwen',
    'kilo',
    'cline',
    'goose',
    'omp-acp',
    'fx',
  ];

  test('the catalog lists every pinned agent, in order', () {
    final agents = AgentCatalog.builtIn.agents;
    expect(agents.map((agent) => agent.id).toList(), ids);
    expect(agents.map((agent) => agent.name).toList(), <String>[
      'OpenCode 2',
      'Claude Code',
      'Codex',
      'Gemini CLI',
      'Qwen Code',
      'Kilo',
      'Cline',
      'Goose',
      'Oh My Pi',
      'fx',
    ]);
  });

  test('every shipped agent installs on arm64', () {
    for (final agent in AgentCatalog.builtIn.agents) {
      expect(agent.recipe, isNotNull, reason: agent.id);
      expect(
        agent.recipe!.artifacts.containsKey(AgentArchitecture.arm64),
        isTrue,
        reason: '${agent.id} lost its arm64 artifact',
      );
      expect(
        agent.installableOn(AgentArchitecture.arm64),
        isTrue,
        reason: '${agent.id} is not installable on arm64',
      );
      expect(agent.recipe!.version, isNotEmpty, reason: agent.id);
      expect(agent.recipe!.executable, isNotEmpty, reason: agent.id);
    }
  });

  test('every pin is honest: https, exact hash, usable member', () {
    for (final agent in AgentCatalog.builtIn.agents) {
      for (final artifact in agent.recipe!.artifacts.values) {
        expect(artifact.url.scheme, 'https', reason: agent.id);
        expect(
          RegExp(r'^[a-f0-9]{64}$').hasMatch(artifact.sha256),
          isTrue,
          reason: '${agent.id} has no exact SHA-256 pin',
        );
      }
    }
  });

  test('an id resolves to one agent, and an unknown id to none', () {
    expect(AgentCatalog.builtIn.byId('gemini')?.name, 'Gemini CLI');
    expect(AgentCatalog.builtIn.byId('opencode2')?.name, 'OpenCode 2');
    expect(AgentCatalog.builtIn.byId('nope'), isNull);
  });
}
