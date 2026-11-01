/// The AI Team at a glance: how many tasks are working, how many need the
/// person, and the few most urgent tasks. Derived from the team state the
/// app already holds; it never asks the network for anything. The Work
/// strip and the progress notification read it.
library;

import 'orchestration_gateway.dart';

/// One task on the glance.
class TeamGlanceTask {
  const TeamGlanceTask({
    required this.id,
    required this.title,
    required this.stepsDone,
    required this.stepsTotal,
    required this.needsYou,
  });

  final String id;
  final String title;
  final int stepsDone;

  /// 0 when the host does not say how many steps the task has.
  final int stepsTotal;
  final bool needsYou;

  @override
  bool operator ==(Object other) =>
      other is TeamGlanceTask &&
      other.id == id &&
      other.title == title &&
      other.stepsDone == stepsDone &&
      other.stepsTotal == stepsTotal &&
      other.needsYou == needsYou;

  @override
  int get hashCode => Object.hash(id, title, stepsDone, stepsTotal, needsYou);
}

class TeamGlance {
  const TeamGlance({
    required this.working,
    required this.needsYou,
    required this.top,
  });

  static const idle = TeamGlance(working: 0, needsYou: 0, top: []);

  /// The most tasks the glance lists.
  static const topLimit = 3;

  /// Open tasks the team is running (not waiting on the person).
  final int working;

  /// Open tasks waiting on the person.
  final int needsYou;

  /// Up to [topLimit] open tasks, needs-you first.
  final List<TeamGlanceTask> top;

  bool get isIdle => working == 0 && needsYou == 0;

  /// [open]: the team's open tasks, most urgent first. [gated]: ids of the
  /// tasks waiting on the person.
  factory TeamGlance.fromTasks({
    required List<OrchestrationRun> open,
    required Set<String> gated,
  }) {
    var working = 0;
    var needsYou = 0;
    final tasks = <TeamGlanceTask>[];
    for (final run in open) {
      final needs = gated.contains(run.id);
      if (needs) {
        needsYou++;
      } else if (run.state == RunState.working ||
          run.state == RunState.planning) {
        working++;
      }
      tasks.add(
        TeamGlanceTask(
          id: run.id,
          title: run.title,
          stepsDone: run.completedSteps ?? 0,
          stepsTotal: run.stepCount ?? 0,
          needsYou: needs,
        ),
      );
    }
    tasks.sort((a, b) => a.needsYou == b.needsYou ? 0 : (a.needsYou ? -1 : 1));
    return TeamGlance(
      working: working,
      needsYou: needsYou,
      top: List.unmodifiable(tasks.take(topLimit)),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TeamGlance &&
      other.working == working &&
      other.needsYou == needsYou &&
      other.top.length == top.length &&
      [
        for (var i = 0; i < top.length; i++) top[i] == other.top[i],
      ].every((e) => e);

  @override
  int get hashCode => Object.hash(working, needsYou, Object.hashAll(top));
}

/// The runs a surface shows by default: the host's own upkeep
/// ([OrchestrationRun.isUpkeep]) left out unless [includeUpkeep].
List<OrchestrationRun> teamVisibleRuns(
  Iterable<OrchestrationRun> runs, {
  bool includeUpkeep = false,
}) => [
  for (final run in runs)
    if (includeUpkeep || !run.isUpkeep) run,
];

/// Order of runs everywhere: what needs the person, then active, then
/// waiting; completed runs come last (and collapse on the card).
int teamRunRank(OrchestrationRun run, Set<String> gated) {
  if (gated.contains(run.id) || run.state == RunState.failed) return 0;
  return switch (run.state) {
    RunState.working => 1,
    RunState.planning => 2,
    RunState.blocked => 3,
    RunState.waiting => 4,
    RunState.unknown => 5,
    RunState.cancelled => 6,
    RunState.failed => 0,
    RunState.completed => 7,
  };
}

/// [teamRunRank] first, then the most recently updated run first.
int teamCompareRuns(OrchestrationRun a, OrchestrationRun b, Set<String> gated) {
  final rank = teamRunRank(a, gated).compareTo(teamRunRank(b, gated));
  if (rank != 0) return rank;
  final at = a.updatedAt ?? a.startedAt;
  final bt = b.updatedAt ?? b.startedAt;
  if (at == null && bt == null) return 0;
  if (at == null) return 1;
  if (bt == null) return -1;
  return bt.compareTo(at);
}
