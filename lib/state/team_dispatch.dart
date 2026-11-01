import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/orchestration_gateway.dart';
import 'orchestration.dart';
import 'team_roles.dart';

/// Where one direct task attempt stands (P6.3,
/// docs/design/team-immediate-dispatch-contract.md). Each stage claims only
/// what the host confirmed: a receipt is not a worker, and a failure to
/// observe is not proof that nothing ran.
enum TeamDispatchPhase {
  /// Nothing sent yet.
  idle,

  /// The host cannot both create and assign work right now; nothing sent.
  unavailable,

  /// Empty title, project or target; nothing sent.
  invalidInput,

  /// The create request is on its way; no task ID yet.
  creating,

  /// The host created the task (its ID is known) and the assignment is on
  /// its way.
  sending,

  /// The host accepted the assignment; no worker session seen yet.
  awaitingWorker,

  /// A fresh snapshot shows a running session on exactly this task.
  workerObserved,

  /// The host refused to create the task: nothing exists.
  createRefused,

  /// The task exists, but the host refused to give it to the team. The
  /// task is kept (never re-created or deleted automatically).
  assignRefused,

  /// Whether the task was created is unknown (no answer, or no ID).
  createUnconfirmed,

  /// The task exists; whether it reached the team is unknown.
  dispatchUnconfirmed,

  /// The task was sent, but the team cannot be seen now (disconnected,
  /// stale or failing reads): what it is doing is unknown.
  unknown,
}

/// One user-triggered task attempt. Listen for receipt and snapshot changes.
///
/// Create one instance per deliberate task attempt ([TeamDispatchAttempts]
/// holds the latest per team so it outlives the sheet it began in) and
/// dispose it before its source. [submit] invokes the existing
/// create-then-assign path exactly once; later taps return the same future,
/// even after an uncertain result. A new instance is required for a
/// deliberately new task. Nothing retries, resumes a pool, adds a timer, or
/// persists additional state: host mutation records remain the
/// restart/deletion source of truth, and a fresh instance (after a restart
/// or a reopen) starts idle and never sends the old task again. This is not
/// a dispatch latency SLA.
class TeamDispatchController extends ChangeNotifier {
  TeamDispatchController(this._source, {DateTime Function()? now})
    : _now = now ?? DateTime.now {
    _source.addListener(_changed);
  }

  final OrchestrationController _source;
  final DateTime Function() _now;
  Future<void>? _submission;
  bool _disposed = false;
  bool _running = false;
  TeamDispatchPhase _phase = TeamDispatchPhase.idle;
  MutationRecord? _created;
  MutationRecord? _assigned;
  String? _title;
  DateTime? _startedAt;
  String? _observedSession;

  /// Both capabilities are required BEFORE creating any task.
  bool get canSubmit =>
      !_disposed &&
      _submission == null &&
      _source.phase == OrchestrationPhase.ready &&
      !_source.isStale &&
      _source.capabilities.controlCreateWork &&
      _source.capabilities.controlAssign;

  MutationRecord? get _currentCreated =>
      _created == null ? null : _source.mutation(_created!.key) ?? _created;
  MutationRecord? get _currentAssigned =>
      _assigned == null ? null : _source.mutation(_assigned!.key) ?? _assigned;

  /// The task's title as the person typed it (for this attempt only).
  String? get title => _title;

  /// When the person sent it, on this phone's clock.
  DateTime? get startedAt => _startedAt;

  String? get workId => _currentCreated?.receipt?.createdId;
  String? get createMutationKey => _created?.key;
  String? get assignMutationKey => _assigned?.key;
  MutationStatus? get createStatus => _currentCreated?.status;
  MutationStatus? get assignStatus => _currentAssigned?.status;
  MutationReceiptStatus? get assignmentReceipt =>
      _currentAssigned?.receipt?.status;

  /// The record of the step that failed or could not be confirmed, when
  /// any: its host words belong under Details only (redacted there).
  MutationRecord? get problemRecord => switch (phase) {
    TeamDispatchPhase.createRefused ||
    TeamDispatchPhase.createUnconfirmed => _currentCreated,
    TeamDispatchPhase.assignRefused || TeamDispatchPhase.dispatchUnconfirmed =>
      _currentAssigned ?? _currentCreated,
    _ => null,
  };

  /// The team can be observed right now: a ready, fresh, error-free source.
  bool get _observable =>
      _source.phase == OrchestrationPhase.ready &&
      !_source.isStale &&
      _source.lastError == null;

  /// Current snapshot evidence only: a named, explicitly running session
  /// attached to this exact task. An unrelated member of the same pool and
  /// an agent's generic working state are insufficient. Null is unknown,
  /// including after disconnect; it does not prove a worker never started.
  String? get workerSessionId {
    final id = workId;
    if (id == null || !_observable) return null;
    for (final agent in _source.snapshot.agents) {
      final session = agent.sessionId;
      if (agent.currentWorkId == id &&
          agent.sessionRunning == true &&
          session != null &&
          session.isNotEmpty) {
        return session;
      }
    }
    return null;
  }

  /// The session once seen running on this task (kept after it ends: it
  /// did start). Null until then.
  String? get observedSessionId => _observedSession;

  TeamDispatchPhase get phase {
    final created = _currentCreated;
    if (created == null) return _phase;
    final createdId = created.receipt?.createdId;
    // The create step.
    if (created.status == MutationStatus.rejected) {
      return TeamDispatchPhase.createRefused;
    }
    if (createdId == null ||
        created.receipt?.isAccepted != true ||
        created.status == MutationStatus.unconfirmed) {
      // Still waiting for the create's answer inside giveTask, or it came
      // back without an ID: the task may or may not exist.
      return _running && created.receipt == null
          ? TeamDispatchPhase.creating
          : TeamDispatchPhase.createUnconfirmed;
    }
    // The task exists. The assignment step.
    final assigned = _currentAssigned;
    if (assigned == null) {
      return _running
          ? TeamDispatchPhase.sending
          : TeamDispatchPhase.dispatchUnconfirmed;
    }
    if (assigned.status == MutationStatus.rejected) {
      return TeamDispatchPhase.assignRefused;
    }
    if (assigned.status == MutationStatus.unconfirmed ||
        assigned.receipt?.isAccepted != true) {
      return TeamDispatchPhase.dispatchUnconfirmed;
    }
    // Accepted: only a fresh observation may say more, and a team that
    // cannot be seen says nothing about its worker.
    if (!_observable) return TeamDispatchPhase.unknown;
    if (workerSessionId != null || _observedSession != null) {
      return TeamDispatchPhase.workerObserved;
    }
    return TeamDispatchPhase.awaitingWorker;
  }

  /// Explicit user action only. Unsupported/empty input sends nothing and
  /// remains editable. Task content is sent unchanged; the existing store
  /// redacts persisted records. A restart retry uses that redacted record.
  ///
  /// Raw transport errors/receipts are never surfaced here. An unexpected
  /// failure leaves [phase] unconfirmed: check host state before trying again.
  Future<void> submit({
    required String title,
    String? description,
    required String projectId,
    required String agentId,
    // Optional role: when both [role] and [roles] are given the task goes
    // through [giveTaskAsRole] (instructions in the description, role model
    // applied first).
    TeamRole? role,
    TeamRolesController? roles,
    String? teamModel,
    Future<void> Function(String? model)? applyModel,
  }) {
    if (_disposed) return Future<void>.value();
    final existing = _submission;
    if (existing != null) return existing;
    if (!canSubmit) {
      _phase = TeamDispatchPhase.unavailable;
      notifyListeners();
      return Future<void>.value();
    }
    if (title.trim().isEmpty ||
        projectId.trim().isEmpty ||
        agentId.trim().isEmpty) {
      _phase = TeamDispatchPhase.invalidInput;
      notifyListeners();
      return Future<void>.value();
    }
    final done = Completer<void>();
    _submission = done.future;
    _running = true;
    _title = title.trim();
    _startedAt = _now();
    _phase = TeamDispatchPhase.creating;
    notifyListeners();
    unawaited(() async {
      try {
        // The host answered the create: say so now, before the
        // assignment is sent (not inferred from elapsed time).
        void onCreated(MutationRecord record) {
          if (_disposed) return;
          _created = record;
          notifyListeners();
        }

        final result = role != null && roles != null
            ? await giveTaskAsRole(
                team: _source,
                roles: roles,
                role: role,
                title: title,
                description: description,
                projectId: projectId,
                agentId: agentId,
                teamModel: teamModel,
                applyModel: applyModel,
                onCreated: onCreated,
              )
            : await _source.giveTask(
                title: title,
                description: description,
                projectId: projectId,
                agentId: agentId,
                onCreated: onCreated,
              );
        if (!_disposed) {
          _created = result.created;
          _assigned = result.assigned;
        }
      } catch (_) {
        if (!_disposed) _phase = TeamDispatchPhase.createUnconfirmed;
      } finally {
        _running = false;
        if (!_disposed) {
          _remember();
          notifyListeners();
        }
        done.complete();
      }
    }());
    return done.future;
  }

  /// Keeps a worker session once seen, so a finished worker never reads
  /// as "waiting for a worker" again.
  void _remember() {
    _observedSession ??= workerSessionId;
  }

  void _changed() {
    if (_disposed) return;
    _remember();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _source.removeListener(_changed);
    super.dispose();
  }
}

/// The latest direct task attempt of each team, so its stage outlives the
/// sheet it began in and the team page's Now line can say it (P6.3).
///
/// Held per [OrchestrationController] (one per server profile): a profile
/// change or deletion replaces that controller, and its attempts go with
/// it. In memory only — after a restart there is no attempt, and nothing is
/// ever sent again from here.
class TeamDispatchAttempts extends ChangeNotifier {
  TeamDispatchAttempts._(this._source);

  static final _of = Expando<TeamDispatchAttempts>('team-dispatch');

  /// The attempts of [source].
  static TeamDispatchAttempts of(OrchestrationController source) =>
      _of[source] ??= TeamDispatchAttempts._(source);

  final OrchestrationController _source;
  TeamDispatchController? _latest;

  /// The latest attempt, until it is dismissed or replaced.
  TeamDispatchController? get latest => _latest;

  /// A new attempt for a deliberate tap; the previous one is let go.
  TeamDispatchController begin({DateTime Function()? now}) {
    _release();
    final attempt = TeamDispatchController(_source, now: now);
    attempt.addListener(notifyListeners);
    _latest = attempt;
    notifyListeners();
    return attempt;
  }

  /// The person closed the attempt's line. The host's records stay.
  void dismiss() {
    if (_latest == null) return;
    _release();
    notifyListeners();
  }

  void _release() {
    final old = _latest;
    _latest = null;
    if (old == null) return;
    old.removeListener(notifyListeners);
    // A submission still running keeps going (disposing never cancels the
    // two-step call); only its notifications stop.
    old.dispose();
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }
}
