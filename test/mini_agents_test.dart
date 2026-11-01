// Mini smoke tests for the agent surface.
//
// The app ships three agent tools only: OpenCode 2 (runs in the app's Linux),
// Claude Code and Codex (run through the phone's Paseo host). These tests fail
// if a catalog entry is dropped by accident, if one loses its arm64 artifact,
// or if a removed agent comes back through a merge.
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/agent_catalog.dart';

void main() {
  test('catalog lists exactly OpenCode 2, Claude Code and Codex', () {
    final agents = AgentCatalog.builtIn.agents;
    expect(
      agents.map((agent) => agent.id).toList(),
      <String>['opencode2', 'claude', 'codex'],
    );
    expect(
      agents.map((agent) => agent.name).toList(),
      <String>['OpenCode 2', 'Claude Code', 'Codex'],
    );
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

  test('removed agents stay removed', () {
    for (final id in <String>[
      'gemini',
      'qwen',
      'kilo',
      'cline',
      'goose',
      'omp-acp',
      'fx',
    ]) {
      expect(AgentCatalog.builtIn.byId(id), isNull, reason: '$id is back');
    }
  });

  test('a saved selection for a removed agent resolves to null, not a throw', () {
    expect(AgentCatalog.builtIn.byId('gemini'), isNull);
    expect(AgentCatalog.builtIn.byId('opencode2')?.name, 'OpenCode 2');
  });
}