/// An AI Team task as a conversation (docs/design/team-conversation-2026-09-26.md):
/// the "lead" lines the app writes from the team's real data, the one "Now"
/// line, and the workers and reviewers that are the task's sub-agents.
///
/// Pure: no widgets and no words. The chat's team conversation turns these
/// into sentences in the person's language. Every line comes from a fact
/// the host reported (a dispatch step reached, a gate opened, the task
/// finished) and carries that fact's time, or no time when the host did not
/// say; nothing is invented.
library;

import 'package:flutter/foundation.dart';

import '../domain/orchestration_gateway.dart';
import '../orchestration/dispatch.dart' show isRefineryName;
import 'team_worker_start.dart';

/// What one lead line says happened.
enum TeamLeadEvent {
  /// The task was split into [TeamLeadLine.count] steps.
  planned,

  /// A step was sent to the workers.
  routed,

  /// A worker is starting on a step.
  workerStarting,

  /// A worker ([TeamLeadLine.agentName]) took a step.
  claimed,

  /// A step's change is on a branch.
  pushed,

  /// A step went to review (the refinery).
  handedToReview,

  /// A step was merged.
  merged,

  /// A step failed ([TeamLeadLine.detail]: the host's error, when given).
  stepFailed,

  /// A step was cancelled.
  stepCancelled,

  /// The team needs the person ([TeamLeadLine.detail]: the question).
  needsYou,

  /// The whole task landed.
  taskMerged,

  /// The task finished without a merge.
  taskFinished,

  /// The task failed ([TeamLeadLine.detail]: the host's error).
  taskFailed,

  /// The task was cancelled.
  taskCancelled,
}

/// One line of the lead's reply.
@immutable
class TeamLeadLine {
  const TeamLeadLine({
    required this.event,
    this.at,
    this.workId,
    this.workTitle,
    this.agentName,
    this.count,
    this.detail,
  });

  final TeamLeadEvent event;

  /// When it happened, host time; null when the host did not say.
  final DateTime? at;
  final String? workId;
  final String? workTitle;

  /// The agent's short name ([teamAgentShortName]), when known.
  final String? agentName;

  /// The number of steps, for [TeamLeadEvent.planned].
  final int? count;
  final String? detail;

  @override
  String toString() => 'TeamLeadLine($event, $workTitle, $agentName, $at)';
}

/// The lead's lines for [run], oldest first. [work] is the run's own items.
List<TeamLeadLine> teamLeadLines({
  required OrchestrationRun run,
  required List<WorkItem> work,
  required DispatchCycle Function(String workId) cycleOf,
  required List<OrchestrationAgent> agents,
  List<OrchestrationGate> gates = const [],
}) {
  final lines = <TeamLeadLine>[];
  if (work.isNotEmpty) {
    lines.add(
      TeamLeadLine(
        event: TeamLeadEvent.planned,
        at: run.startedAt,
        count: work.length,
      ),
    );
  }
  const events = {
    DispatchStep.routed: TeamLeadEvent.routed,
    DispatchStep.agentStarting: TeamLeadEvent.workerStarting,
    DispatchStep.claimed: TeamLeadEvent.claimed,
    DispatchStep.pushed: TeamLeadEvent.pushed,
    DispatchStep.handedToMerge: TeamLeadEvent.handedToReview,
    DispatchStep.merged: TeamLeadEvent.merged,
  };
  for (final item in work) {
    final cycle = cycleOf(item.id);
    final name = _workerName(item, agents);
    for (final step in DispatchStep.values) {
      final event = events[step];
      if (event == null || !cycle.reachedAt.containsKey(step)) continue;
      lines.add(
        TeamLeadLine(
          event: event,
          at: cycle.reachedAt[step],
          workId: item.id,
          workTitle: item.title,
          agentName: event == TeamLeadEvent.claimed ? name : null,
        ),
      );
      // The session is the truth: a worker session made for the item says
      // a worker started even when the host's events did not (the phone,
      // 2026-09-25: session created 19:51:05, no wake event).
      if (step == DispatchStep.routed &&
          !cycle.reachedAt.containsKey(DispatchStep.agentStarting)) {
        final started = _agentOn(item, agents)?.sessionStartedAt;
        if (started != null) {
          lines.add(
            TeamLeadLine(
              event: TeamLeadEvent.workerStarting,
              at: started,
              workId: item.id,
              workTitle: item.title,
            ),
          );
        }
      }
    }
    if (item.state == WorkState.failed) {
      lines.add(
        TeamLeadLine(
          event: TeamLeadEvent.stepFailed,
          at: item.updatedAt,
          workId: item.id,
          workTitle: item.title,
          agentName: name,
          detail: _lastError(item),
        ),
      );
    } else if (item.state == WorkState.cancelled) {
      lines.add(
        TeamLeadLine(
          event: TeamLeadEvent.stepCancelled,
          at: item.updatedAt,
          workId: item.id,
          workTitle: item.title,
        ),
      );
    }
  }
  final titles = {for (final item in work) item.id: item.title};
  for (final gate in gates) {
    lines.add(
      TeamLeadLine(
        event: TeamLeadEvent.needsYou,
        at: gate.createdAt,
        workId: gate.workId,
        workTitle: titles[gate.workId],
        detail: gate.title,
      ),
    );
  }
  final end = run.finishedAt ?? run.updatedAt;
  switch (run.state) {
    case RunState.completed:
      lines.add(
        TeamLeadLine(
          event: run.merged
              ? TeamLeadEvent.taskMerged
              : TeamLeadEvent.taskFinished,
          at: end,
        ),
      );
    case RunState.failed:
      lines.add(
        TeamLeadLine(
          event: TeamLeadEvent.taskFailed,
          at: end,
          detail: _clean(run.lastError),
        ),
      );
    case RunState.cancelled:
      lines.add(TeamLeadLine(event: TeamLeadEvent.taskCancelled, at: end));
    default:
      break;
  }
  // Stable by time; a line the host gave no time keeps its place after the
  // line before it.
  final keyed = <(int, int, TeamLeadLine)>[];
  var last = -1 << 52;
  for (final (index, line) in lines.indexed) {
    final at = line.at?.millisecondsSinceEpoch;
    if (at != null) last = at;
    keyed.add((at ?? last, index, line));
  }
  keyed.sort((a, b) {
    final byTime = a.$1.compareTo(b.$1);
    return byTime != 0 ? byTime : a.$2.compareTo(b.$2);
  });
  return [for (final entry in keyed) entry.$3];
}

/// What the "Now" line says.
enum TeamNowKind {
  /// A gate waits on the person.
  needsYou,

  /// A step waits past its usual window ([TeamNow.stall] says why).
  stalled,

  /// A step waits for a worker to be sent or to wake.
  waitingForWorker,

  /// A worker is starting (the slow part on a phone).
  starting,

  /// A worker is working on a step.
  working,

  /// The work is with review (or waits for the task to close).
  review,

  /// The task is over (merged, finished, failed or cancelled).
  finished,
}

/// The one "Now" fact: what is happening and since when.
@immutable
class TeamNow {
  const TeamNow({
    required this.kind,
    this.since,
    this.agentName,
    this.workTitle,
    this.stall,
    this.gateTitle,
    this.quietSince,
    this.agentId,
    this.workerStage,
  });

  final TeamNowKind kind;

  /// When the current state began, host time; null when unknown.
  final DateTime? since;
  final String? agentName;
  final String? workTitle;
  final DispatchStall? stall;
  final String? gateTitle;

  /// A stalled task: the last sign of progress on its step, host time —
  /// the newest of the step's cycle times, the item's own update and its
  /// worker session's last activity. Null when nothing dates it.
  final DateTime? quietSince;

  /// A stalled task: the id of the agent on its step, when one is.
  final String? agentId;

  /// A starting worker: where its session stands, when the host says.
  final TeamWorkerStage? workerStage;

  @override
  String toString() => 'TeamNow($kind, $agentName, $workTitle, $since)';
}

/// A step that has shown no progress this long has stalled: no step
/// moved, the item did not change and its worker's session did nothing.
const teamNoProgressAfter = Duration(hours: 1);

/// Where [run] stands now, for its one "Now" line. [now] (host clock)
/// lets a step quiet for [teamNoProgressAfter] read as stalled.
TeamNow teamNow({
  required OrchestrationRun run,
  required List<WorkItem> work,
  required DispatchCycle Function(String workId) cycleOf,
  required List<OrchestrationAgent> agents,
  List<OrchestrationGate> gates = const [],
  DateTime? now,
}) {
  switch (run.state) {
    case RunState.completed || RunState.failed || RunState.cancelled:
      return TeamNow(
        kind: TeamNowKind.finished,
        since: run.finishedAt ?? run.updatedAt,
      );
    default:
      break;
  }
  if (gates.isNotEmpty) {
    final gate = gates.first;
    return TeamNow(
      kind: TeamNowKind.needsYou,
      since: gate.createdAt,
      gateTitle: gate.title,
    );
  }
  if (work.isEmpty) {
    return TeamNow(kind: TeamNowKind.waitingForWorker, since: run.startedAt);
  }
  // What moves now: the least advanced step already sent to a worker (or
  // with a worker on it). A step still queued behind it is not "waiting for
  // a worker" while another one is being worked; only when nothing is in
  // flight does the least advanced step of all speak.
  WorkItem? item;
  DispatchCycle? cycle;
  var itemInFlight = false;
  for (final candidate in work) {
    if (candidate.state == WorkState.completed ||
        candidate.state == WorkState.cancelled) {
      continue;
    }
    final candidateCycle = cycleOf(candidate.id);
    if (candidateCycle.isTerminal) continue;
    final inFlight =
        candidateCycle.isDone(DispatchStep.routed) ||
        _agentOn(candidate, agents) != null;
    if (cycle == null ||
        (inFlight && !itemInFlight) ||
        (inFlight == itemInFlight && _lessAdvanced(candidateCycle, cycle))) {
      item = candidate;
      cycle = candidateCycle;
      itemInFlight = inFlight;
    }
  }
  if (item == null || cycle == null) {
    // Every step is done; the task has yet to close.
    DateTime? latest;
    for (final done in work) {
      final at = done.updatedAt;
      if (at != null && (latest == null || at.isAfter(latest))) latest = at;
    }
    return TeamNow(kind: TeamNowKind.review, since: latest);
  }
  final agent = _agentOn(item, agents);
  final name = _workerName(item, agents);
  final sessionRuns =
      agent != null && teamSessionState(agent) == AgentState.working;
  // The last sign of progress on the step: the newest of its cycle times,
  // the item's own update and its worker session's last activity.
  DateTime? quiet;
  for (final at in [
    ...cycle.reachedAt.values,
    item.updatedAt,
    agent?.lastActivity,
  ]) {
    if (at != null && (quiet == null || at.isAfter(quiet))) quiet = at;
  }
  // A step in a worker's hands (or on its way) that has shown nothing for
  // [teamNoProgressAfter] has stalled, whatever step the cycle reached:
  // "starting · can take a few minutes" for 45 h is a stall (owner
  // report, build 2055). Needs [now]; without it only the cycle decides.
  final quietTooLong =
      now != null &&
      quiet != null &&
      now.difference(quiet) >= teamNoProgressAfter;
  // "The host has not started an agent" is wrong once a worker's session
  // runs on the item (it is starting: minutes on a phone).
  if ((cycle.stalled &&
          !(sessionRuns &&
              cycle.stallReason == DispatchStall.hostNotStarted)) ||
      quietTooLong) {
    return TeamNow(
      kind: TeamNowKind.stalled,
      since: cycle.since ?? quiet,
      stall: cycle.stallReason ?? DispatchStall.workingLong,
      agentName: name,
      workTitle: item.title,
      quietSince: quiet,
      agentId: agent?.id,
    );
  }
  final reached = cycle.reachedAt;
  switch (cycle.step) {
    case DispatchStep.routed || DispatchStep.agentStarting:
      // The session is the truth: a worker's session running on the item
      // is starting even before the cycle's evidence says so.
      if (sessionRuns) {
        return TeamNow(
          kind: TeamNowKind.starting,
          since: agent.sessionStartedAt,
          agentName: name,
          workTitle: item.title,
          workerStage: teamWorkerStage(agent),
        );
      }
      return TeamNow(
        kind: TeamNowKind.waitingForWorker,
        since: reached[DispatchStep.routed] ?? item.createdAt ?? run.startedAt,
        workTitle: item.title,
      );
    case DispatchStep.claimed:
      return TeamNow(
        kind: TeamNowKind.starting,
        since: reached[DispatchStep.agentStarting] ?? agent?.sessionStartedAt,
        agentName: name,
        workTitle: item.title,
        workerStage: teamWorkerStage(agent),
      );
    case DispatchStep.working || DispatchStep.pushed:
      return TeamNow(
        kind: TeamNowKind.working,
        since: reached[DispatchStep.claimed],
        agentName: name,
        workTitle: item.title,
      );
    case DispatchStep.handedToMerge || DispatchStep.merged:
      return TeamNow(
        kind: TeamNowKind.review,
        since:
            reached[DispatchStep.handedToMerge] ?? reached[DispatchStep.pushed],
        workTitle: item.title,
      );
  }
}

/// The agent's state as its session tells it. Gas City's `/agents` can lag
/// (it said `stopped` while `/sessions` said `active`, running): the
/// session wins, except for waiting and blocked, which come from the
/// host's pending interactions and waits.
AgentState teamSessionState(OrchestrationAgent agent) {
  if (agent.state == AgentState.waiting || agent.state == AgentState.blocked) {
    return agent.state;
  }
  final state = agent.sessionState?.trim().toLowerCase();
  if (agent.sessionRunning == true) return AgentState.working;
  switch (state) {
    case 'active' || 'running' || 'busy' || 'working':
      return AgentState.working;
    case 'asleep' || 'sleeping' || 'idle':
      return AgentState.idle;
    case 'stopped' || 'suspended' || 'closed' || 'exited':
      return AgentState.stopped;
    case 'error' || 'failed' || 'crashed':
      return AgentState.crashed;
  }
  return agent.state;
}

/// The agent's own name ("furiosa" from `ocproof/gastown.furiosa`), or null
/// when its name is only its kind (`gastown.refinery`, `gastown.dog-2`):
/// then the role word says who it is.
String? teamAgentShortName(OrchestrationAgent agent) => _shortName(agent.name);

/// The workers and the reviewer on this task, one each: the agents whose
/// work is one of [work]'s items, and the project's refinery once a step
/// was handed to review. Working first, otherwise in the host's order.
List<OrchestrationAgent> teamConversationAgents({
  required List<OrchestrationAgent> agents,
  required List<WorkItem> work,
  required DispatchCycle Function(String workId) cycleOf,
}) {
  final ids = {for (final item in work) item.id};
  final picked = <String, OrchestrationAgent>{};
  for (final agent in agents) {
    if (ids.contains(agent.currentWorkId)) {
      picked.putIfAbsent(agent.id, () => agent);
    }
  }
  final reviewed = work.any(
    (item) => cycleOf(item.id).isDone(DispatchStep.handedToMerge),
  );
  if (reviewed) {
    final rigs = {
      for (final item in work)
        if (item.projectId case final rig? when rig.isNotEmpty) rig,
    };
    for (final agent in agents) {
      if (!isRefineryName(agent.pool ?? agent.name) &&
          !isRefineryName(agent.name)) {
        continue;
      }
      if (rigs.isNotEmpty &&
          !rigs.any((rig) => agent.name.startsWith('$rig/'))) {
        continue;
      }
      picked.putIfAbsent(agent.id, () => agent);
    }
  }
  final list = picked.values.toList();
  return [
    for (final agent in list)
      if (teamSessionState(agent) == AgentState.working) agent,
    for (final agent in list)
      if (teamSessionState(agent) != AgentState.working) agent,
  ];
}

const _templateWords = {
  'polecat',
  'polecats',
  'refinery',
  'mayor',
  'witness',
  'deacon',
  'boot',
  'dog',
  'dogs',
};

String? _shortName(String? name) {
  if (name == null) return null;
  var tail = name.trim().split('/').last;
  tail = tail.split('.').last;
  tail = tail.replaceFirst(RegExp(r'-\d+$'), '');
  if (tail.isEmpty || _templateWords.contains(tail.toLowerCase())) return null;
  return tail;
}

/// The agent working on [item], if the snapshot names one.
OrchestrationAgent? _agentOn(WorkItem item, List<OrchestrationAgent> agents) {
  for (final agent in agents) {
    if (agent.currentWorkId == item.id) return agent;
  }
  return null;
}

/// The short name of whoever works on [item]: the agent on it, else its
/// assignee.
String? _workerName(WorkItem item, List<OrchestrationAgent> agents) {
  final agent = _agentOn(item, agents);
  if (agent != null) return teamAgentShortName(agent);
  return _shortName(item.assignee);
}

bool _lessAdvanced(DispatchCycle a, DispatchCycle b) {
  final byStep = a.step.index.compareTo(b.step.index);
  if (byStep != 0) return byStep < 0;
  final aSince = a.since, bSince = b.since;
  if (aSince == null || bSince == null) return false;
  return aSince.isBefore(bSince);
}

String? _lastError(WorkItem item) {
  final metadata = item.raw['metadata'];
  if (metadata is Map) return _clean(metadata['last_error']?.toString());
  return _clean(item.raw['last_error']?.toString());
}

String? _clean(String? value) {
  final text = value?.trim();
  return text == null || text.isEmpty ? null : text;
}
