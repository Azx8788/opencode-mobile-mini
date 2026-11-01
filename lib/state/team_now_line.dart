/// Word-free state for the team's single Now line. No network or persistence.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/orchestration_gateway.dart';
import 'team_conversation.dart';
import 'team_planning.dart';
import 'team_worker_start.dart';

/// Localise these values; never display enum names as copy.
enum TeamNowActivity {
  planning,
  waitingForWorker,
  startingWorker,
  working,
  reviewing,
  needsYou,
  delayed,
  unconfirmed,
  refused,
  unavailable,
  completed,
  failed,
  cancelled,
}

enum TeamNowNext {
  plan,
  worker,
  work,
  review,
  finish,
  yourAnswer,
  checkActivity,
  none,
}

/// Factual explanations, including explicit unknowns, for the inline Why fold.
enum TeamNowReason {
  noPlanReported,
  noWorkerReported,
  workerStarting,
  workerPreparing,
  workerRunning,
  workerTaskDelivered,
  workInProgress,
  reviewPending,
  answerNeeded,
  workerCouldNotStart,
  providerLimit,
  workTakingLonger,
  confirmationMissing,
  requestRefused,
  connectionUnavailable,
  causeUnknown,
}

/// Suggestions only. Writes remain explicit, capability-gated user actions.
enum TeamNowAction { refresh, openActivity, answer, dismissRequest, cancelRun }

@immutable
class TeamNowInput {
  const TeamNowInput({
    required this.activityKey,
    required this.activity,
    required this.next,
    required this.reason,
    this.since,
    this.typicalUpperBound,
    this.workerStage,
    this.lastWorkerStart,
    this.canCancel = false,
    this.canDismiss = false,
  });

  /// Opaque profile + task + current work identity, never displayed or logged.
  /// Change it when the selected task/step changes, even if its phase does not.
  final String activityKey;
  final TeamNowActivity activity;
  final TeamNowNext next;
  final TeamNowReason? reason;

  /// Host time (or persisted request time), never a locally invented start.
  final DateTime? since;

  /// Optional evidence-backed usual upper bound, NOT a countdown or promise.
  /// Null means unknown. Do not supply a target or a stall timeout as an estimate.
  final Duration? typicalUpperBound;

  /// A starting worker: the stage its session reports, null when the host
  /// names none the app can read.
  final TeamWorkerStage? workerStage;

  /// How long this phone's last worker start took (measured), null when
  /// none was measured yet. Said as "took 42 s last time", never as a
  /// promise.
  final Duration? lastWorkerStart;
  final bool canCancel;
  final bool canDismiss;

  /// The same facts with the worker's start stage and last measured start.
  TeamNowInput withWorkerStart({
    TeamWorkerStage? stage,
    Duration? lastStart,
    Duration? typicalUpperBound,
  }) => TeamNowInput(
    activityKey: activityKey,
    activity: activity,
    next: next,
    reason: activity == TeamNowActivity.startingWorker
        ? switch (stage ?? workerStage) {
            TeamWorkerStage.preparing => TeamNowReason.workerPreparing,
            TeamWorkerStage.running => TeamNowReason.workerRunning,
            TeamWorkerStage.taskDelivered => TeamNowReason.workerTaskDelivered,
            null => reason,
          }
        : reason,
    since: since,
    typicalUpperBound: typicalUpperBound ?? this.typicalUpperBound,
    workerStage: stage ?? workerStage,
    lastWorkerStart: lastStart ?? lastWorkerStart,
    canCancel: canCancel,
    canDismiss: canDismiss,
  );

  /// Uses the existing conversation selection so the status has one source.
  /// [now] (host clock) lets a step quiet for `teamNoProgressAfter` read as
  /// delayed (P3.5's stalled-task detection).
  factory TeamNowInput.forRun({
    required String activityKey,
    required OrchestrationRun run,
    required List<WorkItem> work,
    required DispatchCycle Function(String workId) cycleOf,
    required List<OrchestrationAgent> agents,
    List<OrchestrationGate> gates = const [],
    bool connected = true,
    bool canCancel = false,
    Duration? typicalUpperBound,
    DateTime? now,
  }) {
    if (!connected) {
      return TeamNowInput(
        activityKey: activityKey,
        activity: TeamNowActivity.unavailable,
        next: TeamNowNext.checkActivity,
        reason: TeamNowReason.connectionUnavailable,
      );
    }
    final fact = teamNow(
      run: run,
      work: work,
      cycleOf: cycleOf,
      agents: agents,
      gates: gates,
      now: now,
    );
    final activity = switch (fact.kind) {
      TeamNowKind.needsYou => TeamNowActivity.needsYou,
      TeamNowKind.stalled => TeamNowActivity.delayed,
      TeamNowKind.waitingForWorker => TeamNowActivity.waitingForWorker,
      TeamNowKind.starting => TeamNowActivity.startingWorker,
      TeamNowKind.working => TeamNowActivity.working,
      TeamNowKind.review => TeamNowActivity.reviewing,
      TeamNowKind.finished => switch (run.state) {
        RunState.failed => TeamNowActivity.failed,
        RunState.cancelled => TeamNowActivity.cancelled,
        _ => TeamNowActivity.completed,
      },
    };
    final (next, reason) = switch (activity) {
      TeamNowActivity.needsYou => (
        TeamNowNext.yourAnswer,
        TeamNowReason.answerNeeded,
      ),
      TeamNowActivity.waitingForWorker => (
        TeamNowNext.worker,
        TeamNowReason.noWorkerReported,
      ),
      TeamNowActivity.startingWorker => (
        TeamNowNext.work,
        TeamNowReason.workerStarting,
      ),
      TeamNowActivity.working => (
        TeamNowNext.review,
        TeamNowReason.workInProgress,
      ),
      TeamNowActivity.reviewing => (
        TeamNowNext.finish,
        TeamNowReason.reviewPending,
      ),
      TeamNowActivity.delayed => (
        TeamNowNext.checkActivity,
        switch (fact.stall) {
          DispatchStall.hostNotStarted => TeamNowReason.noWorkerReported,
          DispatchStall.agentCannotStart => TeamNowReason.workerCouldNotStart,
          DispatchStall.providerLimit => TeamNowReason.providerLimit,
          DispatchStall.workingLong => TeamNowReason.workTakingLonger,
          DispatchStall.mergeWaiting => TeamNowReason.reviewPending,
          null => TeamNowReason.causeUnknown,
        },
      ),
      TeamNowActivity.failed => (
        TeamNowNext.checkActivity,
        TeamNowReason.causeUnknown,
      ),
      _ => (TeamNowNext.none, null),
    };
    return TeamNowInput(
      activityKey: activityKey,
      activity: activity,
      next: next,
      reason: reason,
      since: fact.since,
      canCancel: canCancel,
      typicalUpperBound: typicalUpperBound,
    ).withWorkerStart(stage: fact.workerStage);
  }

  /// Only unresolved requests; a matched run must use [TeamNowInput.forRun].
  factory TeamNowInput.forPlanning({
    required String activityKey,
    required TeamPlanningRequest request,
  }) {
    if (request.status == TeamPlanningStatus.started || request.run != null) {
      throw ArgumentError('Use forRun for a resolved planning request');
    }
    final (activity, reason) = switch (request.status) {
      TeamPlanningStatus.unconfirmed => (
        TeamNowActivity.unconfirmed,
        TeamNowReason.confirmationMissing,
      ),
      TeamPlanningStatus.refused => (
        TeamNowActivity.refused,
        TeamNowReason.requestRefused,
      ),
      _ => (TeamNowActivity.planning, TeamNowReason.noPlanReported),
    };
    return TeamNowInput(
      activityKey: activityKey,
      activity: activity,
      next: activity == TeamNowActivity.planning
          ? TeamNowNext.plan
          : TeamNowNext.checkActivity,
      reason: reason,
      since: request.sentAt,
      canDismiss: true,
    );
  }
}

@immutable
class TeamNowLineState {
  const TeamNowLineState._(this.input, this.explain);

  final TeamNowInput input;

  /// Show a plain-language reason and a way out, not a silent spinner.
  /// This reveals the Why affordance; the UI owns whether its fold is expanded.
  final bool explain;

  TeamNowActivity get activity => input.activity;
  TeamNowNext get next => input.next;
  DateTime? get since => input.since;
  TeamNowReason? get reason => input.reason;
  TeamWorkerStage? get workerStage => input.workerStage;
  Duration? get lastWorkerStart =>
      activity == TeamNowActivity.startingWorker ? input.lastWorkerStart : null;
  Duration? get typicalUpperBound =>
      _terminal(activity) || _urgent(activity) ? null : input.typicalUpperBound;

  List<TeamNowAction> get actions => List.unmodifiable([
    if (!_terminal(activity)) TeamNowAction.refresh,
    if (explain || _terminal(activity)) TeamNowAction.openActivity,
    if (activity == TeamNowActivity.needsYou) TeamNowAction.answer,
    if (input.canDismiss) TeamNowAction.dismissRequest,
    if (input.canCancel &&
        !_terminal(activity) &&
        activity != TeamNowActivity.unavailable)
      TeamNowAction.cancelRun,
  ]);
}

/// Own one per visible task/request; call [update] on orchestration changes.
/// A single timer reveals Why at 8 s even when no new server event arrives.
/// Dispose when leaving the task/profile; nothing is stored, so no deletion
/// sweep or secret redaction is needed. No raw server text enters this API.
class TeamNowLineController extends ValueNotifier<TeamNowLineState> {
  TeamNowLineController(TeamNowInput input, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now,
      super(TeamNowLineState._(input, false)) {
    _observedAt = _clock();
    _publish();
  }

  static const explainAfter = Duration(seconds: 8);
  final DateTime Function() _clock;
  late DateTime _observedAt;
  Timer? _timer;

  void update(TeamNowInput input) {
    final previous = value.input;
    if (previous.activityKey != input.activityKey ||
        previous.activity != input.activity ||
        previous.since != input.since) {
      _observedAt = _clock();
    }
    _publish(input);
  }

  void _publish([TeamNowInput? nextInput]) {
    _timer?.cancel();
    final input = nextInput ?? value.input;
    final now = _clock();
    // Unknown/future host times stay unknown/future for display, but a clock
    // skew must not suppress the explanation indefinitely.
    final start = input.since;
    final effectiveStart = start != null && start.isBefore(_observedAt)
        ? start
        : _observedAt;
    final elapsed = now.difference(effectiveStart);
    final explain =
        !_terminal(input.activity) &&
        (_urgent(input.activity) || elapsed >= explainAfter);
    value = TeamNowLineState._(input, explain);
    if (!explain && !_terminal(input.activity)) {
      _timer = Timer(
        explainAfter - (elapsed.isNegative ? Duration.zero : elapsed),
        _publish,
      );
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

bool _terminal(TeamNowActivity activity) => switch (activity) {
  TeamNowActivity.completed ||
  TeamNowActivity.failed ||
  TeamNowActivity.cancelled => true,
  _ => false,
};

bool _urgent(TeamNowActivity activity) => switch (activity) {
  TeamNowActivity.needsYou ||
  TeamNowActivity.delayed ||
  TeamNowActivity.unconfirmed ||
  TeamNowActivity.refused ||
  TeamNowActivity.unavailable => true,
  _ => false,
};
