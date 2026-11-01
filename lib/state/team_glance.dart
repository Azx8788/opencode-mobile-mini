/// The AI Team glance derived from a plugin snapshot (no network).
library;

import '../domain/orchestration_gateway.dart';
import '../domain/team_glance.dart';
import 'orchestration.dart';

/// Runs with something waiting on the person: a gate naming the run, a
/// work item of the run, or an agent working one of its items.
/// Review-ready is informational and never counts.
Set<String> teamGatedRuns(OrchestrationSnapshot snapshot) {
  final runByWork = <String, String>{
    for (final item in snapshot.work)
      if (item.runId != null) item.id: item.runId!,
  };
  final workByAgent = <String, String>{
    for (final agent in snapshot.agents)
      if (agent.currentWorkId case final work?) ...{
        agent.id: work,
        ?agent.sessionId: work,
      },
  };
  String? runOf(OrchestrationGate gate) =>
      gate.runId ??
      runByWork[gate.workId] ??
      runByWork[workByAgent[gate.agentId]];
  return {
    for (final gate in snapshot.gates)
      if (gate.kind != GateKind.reviewReady) ?runOf(gate),
  };
}

/// The team at a glance, from the open tasks of [snapshot].
TeamGlance teamGlanceFromSnapshot(OrchestrationSnapshot snapshot) {
  if (!snapshot.hasData) return TeamGlance.idle;
  final gated = teamGatedRuns(snapshot);
  final open = [
    for (final run in teamVisibleRuns(snapshot.runs))
      if (run.state != RunState.completed && run.state != RunState.cancelled)
        run,
  ]..sort((a, b) => teamCompareRuns(a, b, gated));
  return TeamGlance.fromTasks(open: open, gated: gated);
}
