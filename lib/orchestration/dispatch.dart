/// Derives a work item's [DispatchCycle] (TEAM-116) from what the app
/// already holds: the item's current fields, the timeline events that
/// name it (its bead, its session, the routed pool's sessions) and the
/// agent's transcript. Pure: the same inputs and the same [now] give the
/// same cycle. The controller calls [deriveDispatchCycle] on refresh, on
/// events and on a 30 s tick while any cycle is still moving.
///
/// Evidence → step (05-beads TEAM-116):
///
/// | Step | Evidence |
/// |---|---|
/// | Routed | `bead.updated` with `metadata.gc.routed_to`, or the item carries it |
/// | Agent starting | `session.woke` for the item's session, or for a session of the routed pool in the rig after routing (named by its template, by an agent of that pool, or by a session bead whose worktree is under the rig's `polecats/`), or such a session in the agents list |
/// | Claimed | `bead.updated` → status `in_progress` with an `assignee` |
/// | Working | `metadata.gc.work_dir` / `work_dir` present, `metadata.branch` set (the agent records its branch when it creates it, which can be minutes before any push), or the transcript has text |
/// | Pushed | `metadata.branch` set and the polecat session stopped afterwards (it drains only after pushing), or the assignee is the rig's refinery |
/// | Handed to merge | assignee is the rig's refinery, or the polecat session stopped after the branch appeared |
/// | Merged | `bead.closed` (not cancelled), the item completed, or the run completed |
///
/// Steps are reached in order: a later step known without an earlier one
/// fills the earlier one in at the same time, so the strip never shows a
/// hole.
///
/// Times (TEAM-117): an event stamps its step with its own `ts`. A step
/// inferred from the item's current fields is stamped with the bead's
/// `updated_at` when the bead carries one and left untimed otherwise
/// (`reachedAt[step] == null`: reached, since unknown) — never with the
/// moment the app first looked. Stall windows for such steps count from
/// the bead's `updated_at`, else its `created_at`.
library;

import 'events/orchestration_event.dart';
import 'models/agent.dart';
import 'models/dispatch_cycle.dart';
import 'models/work.dart';

/// Routed this long without an agent starting is a stall.
const dispatchHostStartWindow = Duration(minutes: 3);

/// A session that woke and stopped within this window flapped once.
const dispatchFlapWindow = Duration(seconds: 60);

/// Flaps within [dispatchFlapWindow] that make "the agent cannot start".
const dispatchFlapCount = 2;

/// Working (or claimed) this long without a push is a stall.
const dispatchWorkingWindow = Duration(minutes: 30);

/// Handed to merge this long without a merge is a stall.
const dispatchMergeWindow = Duration(minutes: 15);

/// What a transcript says when the model provider refused for quota
/// ("The usage limit has been reached", "rate limit exceeded", ...).
final dispatchProviderLimitPattern = RegExp(
  r'usage limit|quota|rate limit',
  caseSensitive: false,
);

/// The cycle of [item] at [now].
///
/// [timeline] is the controller's append-only event list (any order is
/// accepted; timestamps decide). [agents] is the snapshot's agent list,
/// for pool sessions the events did not name. [transcript] is the agent's
/// output so far, when the app has it. [runCompleted] (with
/// [runCompletedAt]) says the tracking run finished, which merges the
/// item.
DispatchCycle deriveDispatchCycle({
  required WorkItem item,
  required DateTime now,
  Iterable<OrchestrationEvent> timeline = const [],
  Iterable<OrchestrationAgent> agents = const [],
  String? transcript,
  bool runCompleted = false,
  DateTime? runCompletedAt,
}) {
  final evidence = _Evidence(item);
  evidence.indexAgents(agents);
  evidence.readItem();
  evidence.readTimeline(timeline);
  evidence.readAgents();
  if (transcript != null && transcript.trim().isNotEmpty) {
    evidence.transcriptSeen = true;
  }
  if (runCompleted) {
    evidence.reach(DispatchStep.merged, runCompletedAt ?? item.updatedAt);
  }
  final reachedAt = evidence.resolve();

  DispatchStep step = DispatchStep.merged;
  for (final candidate in DispatchStep.values) {
    if (!reachedAt.containsKey(candidate)) {
      step = candidate;
      break;
    }
  }
  final terminal = reachedAt.containsKey(DispatchStep.merged);

  DispatchStall? stall;
  if (!terminal) {
    // A step reached at an unknown time waits since the bead last
    // changed, or since it was created.
    final inferredSince = item.updatedAt ?? item.createdAt;
    DateTime? since(DispatchStep step) => reachedAt[step] ?? inferredSince;
    final limit =
        transcript != null && dispatchProviderLimitPattern.hasMatch(transcript);
    if (limit &&
        (step == DispatchStep.claimed ||
            step == DispatchStep.working ||
            step == DispatchStep.pushed)) {
      stall = DispatchStall.providerLimit;
    } else if ((step == DispatchStep.agentStarting ||
            step == DispatchStep.claimed) &&
        evidence.flaps >= dispatchFlapCount) {
      stall = DispatchStall.agentCannotStart;
    } else if (step == DispatchStep.agentStarting &&
        _waited(now, since(DispatchStep.routed), dispatchHostStartWindow)) {
      stall = DispatchStall.hostNotStarted;
    } else if (step == DispatchStep.pushed &&
        _waited(now, since(DispatchStep.working), dispatchWorkingWindow)) {
      stall = DispatchStall.workingLong;
    } else if (step == DispatchStep.working &&
        _waited(now, since(DispatchStep.claimed), dispatchWorkingWindow)) {
      stall = DispatchStall.workingLong;
    } else if (step == DispatchStep.merged &&
        _waited(now, since(DispatchStep.handedToMerge), dispatchMergeWindow)) {
      stall = DispatchStall.mergeWaiting;
    }
  }

  return DispatchCycle(
    step: step,
    reachedAt: Map.unmodifiable(reachedAt),
    stalled: stall != null,
    stallReason: stall,
    hint: !terminal && stall == null && step == DispatchStep.agentStarting
        ? DispatchHint.usualWait
        : null,
  );
}

bool _waited(DateTime now, DateTime? since, Duration window) =>
    since != null && now.difference(since) > window;

/// True when [item] is open and in the merge agent's hands (TEAM-117):
/// its assignee is a rig's refinery (`ocproof/gastown.refinery`). Such an
/// item waits for the merge, not for work: the mapper reads it as review
/// pending and the batch as waiting for merge.
bool workHandedToMerge(WorkItem item) {
  switch (item.state) {
    case WorkState.completed:
    case WorkState.cancelled:
    case WorkState.failed:
    case WorkState.blocked:
    case WorkState.needsInput:
      return false;
    case WorkState.queued:
    case WorkState.ready:
    case WorkState.working:
    case WorkState.waiting:
    case WorkState.review:
    case WorkState.unknown:
      break;
  }
  // The bead's own assignee; the mapper falls back to the pool routing
  // for [WorkItem.assignee], and a routing is not a hand-off.
  var assignee = _clean(_text(item.raw['assignee']));
  if (assignee == null && !item.raw.containsKey('assignee')) {
    final routedTo = _clean(_meta(item.raw, 'gc.routed_to'));
    final own = _clean(item.assignee);
    if (own != null && own != routedTo) assignee = own;
  }
  return assignee != null && isRefineryName(assignee);
}

/// True when [name] is a refinery's agent identity: it ends with
/// `refinery` (`ocproof/gastown.refinery`, `gastown.refinery`).
bool isRefineryName(String name) =>
    name.trim().toLowerCase().endsWith('refinery');

/// Collects the earliest time each step was seen, then resolves them into
/// an ordered, gap-free map.
class _Evidence {
  _Evidence(this.item) {
    routedTo = _clean(_meta(item.raw, 'gc.routed_to'));
    final sessionId = item.sessionId;
    if (sessionId != null) sessionIds.add(sessionId);
    rig = _rigOf(routedTo ?? item.assignee);
  }

  final WorkItem item;

  /// When each step was seen, earliest first; null for a step the item's
  /// fields prove reached at a time nothing states.
  final reached = <DispatchStep, DateTime?>{};
  final sessionIds = <String>{};

  /// Session beads whose worktree sits under the rig's `polecats/`: pool
  /// instances the events did not otherwise tie to the routed template.
  final polecatSessionIds = <String>{};
  String? routedTo;
  String? rig;
  bool transcriptSeen = false;

  /// Whether the bead names its branch, and the earliest known time it
  /// did. The polecat records the branch when it creates it; the push
  /// itself leaves no field, so the branch alone means "working".
  bool _branchSeen = false;
  DateTime? _branchAt;

  /// Sessions the events stopped, by id, at when: for the handoff (a
  /// polecat that drained after pushing) and the flap count.
  final _stops = <(String, DateTime)>[];
  final _wakes = <(String, DateTime)>[];

  /// Woke → stopped pairs within [dispatchFlapWindow].
  int flaps = 0;

  /// Notes [step] reached at [at]; the earliest known time wins, and a
  /// known time replaces an unknown one.
  void reach(DispatchStep step, DateTime? at) {
    if (!reached.containsKey(step)) {
      reached[step] = at;
      return;
    }
    final known = reached[step];
    if (at != null && (known == null || at.isBefore(known))) {
      reached[step] = at;
    }
  }

  /// The item's own fields: what it carries now, timed by the bead's
  /// `updated_at` when it has one, else untimed.
  void readItem() {
    final raw = item.raw;
    final at = item.updatedAt;
    if (routedTo != null || _clean(item.assignee) != null) {
      reach(DispatchStep.routed, at);
    }
    final assignee = _clean(_text(raw['assignee']));
    final status = _status(item.rawState);
    if (status == 'in_progress' && assignee != null) {
      reach(DispatchStep.claimed, at);
    }
    if (_clean(_meta(raw, 'gc.work_dir')) != null ||
        _clean(_meta(raw, 'work_dir')) != null) {
      reach(DispatchStep.working, at);
    }
    if (_clean(_meta(raw, 'branch')) != null) {
      reach(DispatchStep.working, at);
      _branchAt ??= at;
      _branchSeen = true;
    }
    if (assignee != null && _isRefinery(assignee)) {
      reach(DispatchStep.pushed, at);
      reach(DispatchStep.handedToMerge, at);
    }
    if (item.state == WorkState.completed) {
      reach(DispatchStep.merged, at);
    }
  }

  /// The events naming the bead, then the sessions (which the bead events
  /// may have named on the way).
  void readTimeline(Iterable<OrchestrationEvent> timeline) {
    final sessions = <SessionChanged>[];
    final sessionBeadsClosed = <(String, DateTime)>[];
    for (final event in timeline) {
      switch (event) {
        case BeadChanged():
          if (event.beadId == item.id) {
            _readBead(event);
          } else {
            _readOtherBead(event);
            if (event.change == BeadChange.closed) {
              final at = _eventTime(event);
              if (at != null) sessionBeadsClosed.add((event.beadId, at));
            }
          }
        case SessionChanged():
          sessions.add(event);
        default:
          break;
      }
    }
    final routedAt = reached[DispatchStep.routed];
    for (final event in sessions) {
      final at = _eventTime(event);
      if (at == null) continue;
      final named = sessionIds.contains(event.sessionId);
      final pooled =
          !named &&
          routedAt != null &&
          !at.isBefore(routedAt) &&
          _isPoolSession(event);
      if (!named && !pooled) continue;
      switch (event.change) {
        case SessionChange.woke:
          _wakes.add((event.sessionId, at));
          reach(
            DispatchStep.agentStarting,
            routedAt != null && at.isBefore(routedAt) ? routedAt : at,
          );
        case SessionChange.stopped:
          _stops.add((event.sessionId, at));
      }
    }
    // Gas City signals a swept pool session as `bead.closed` on the
    // session bead, with no `session.stopped`.
    for (final (id, at) in sessionBeadsClosed) {
      if (sessionIds.contains(id)) _stops.add((id, at));
    }
    _countFlaps();
    _handoffFromDrain();
  }

  void _readBead(BeadChanged event) {
    final at = _eventTime(event);
    if (at == null) return;
    final bead = _map(_map(event.raw['payload'])['bead']);
    final metadata = _map(bead['metadata']);
    final assignee = _clean(_text(bead['assignee']));
    final status = _status(_text(bead['status']));
    final sessionId = _clean(_text(metadata['gc.session_id']));
    if (sessionId != null) sessionIds.add(sessionId);
    final routed = _clean(_text(metadata['gc.routed_to']));
    if (routed != null) {
      routedTo ??= routed;
      rig ??= _rigOf(routed);
      reach(DispatchStep.routed, at);
    }
    if (status == 'in_progress' && assignee != null) {
      reach(DispatchStep.claimed, at);
    }
    if (_clean(_text(metadata['gc.work_dir'])) != null ||
        _clean(_text(metadata['work_dir'])) != null) {
      reach(DispatchStep.working, at);
    }
    if (_clean(_text(metadata['branch'])) != null) {
      reach(DispatchStep.working, at);
      if (_branchAt == null || at.isBefore(_branchAt!)) _branchAt = at;
      _branchSeen = true;
    }
    if (assignee != null && _isRefinery(assignee)) {
      reach(DispatchStep.pushed, at);
      reach(DispatchStep.handedToMerge, at);
    }
    if (event.change == BeadChange.closed) {
      final reason =
          _text(bead['close_reason']) ??
          _text(bead['closed_reason']) ??
          _text(bead['closeReason']);
      if (reason == null || !reason.toLowerCase().contains('cancel')) {
        reach(DispatchStep.merged, at);
      }
    }
  }

  /// Another bead's event: a session bead (Gas City 1.4.1 gives pool
  /// sessions one, keyed by the session id) whose worktree is under the
  /// rig's `polecats/` names a polecat instance.
  void _readOtherBead(BeadChanged event) {
    final pool = routedTo;
    if (pool == null || !pool.endsWith('.polecat')) return;
    final bead = _map(_map(event.raw['payload'])['bead']);
    final metadata = _map(bead['metadata']);
    final workDir =
        _clean(_text(metadata['gc.work_dir'])) ??
        _clean(_text(metadata['work_dir']));
    if (workDir == null || !workDir.contains('/polecats/')) return;
    final rigName = rig;
    if (rigName != null && !workDir.contains('/$rigName/')) return;
    polecatSessionIds.add(event.beadId);
  }

  /// A session event of the routed pool: the event names the pool as its
  /// template, its session bead is a polecat's in the rig, or its subject
  /// is the pool or an instance of it in the rig.
  bool _isPoolSession(SessionChanged event) {
    final pool = routedTo;
    if (pool == null) return false;
    final template = _text(_map(event.raw['payload'])['template']);
    if (template == pool) return true;
    if (polecatSessionIds.contains(event.sessionId)) return true;
    final subject = event.agentId;
    if (subject == null) return false;
    if (subject == pool) return true;
    final agent = agentsByName[subject] ?? agentsBySession[event.sessionId];
    return agent != null && agent.pool == pool;
  }

  /// The snapshot's agents by name, id and session id, for the pool
  /// check of session events.
  final agentsByName = <String, OrchestrationAgent>{};
  final agentsBySession = <String, OrchestrationAgent>{};
  final _agents = <OrchestrationAgent>[];

  void indexAgents(Iterable<OrchestrationAgent> agents) {
    for (final agent in agents) {
      _agents.add(agent);
      agentsByName[agent.name] = agent;
      agentsByName[agent.id] = agent;
      final sessionId = agent.sessionId;
      if (sessionId != null) agentsBySession[sessionId] = agent;
    }
  }

  /// The snapshot's agents as evidence: the named session's start, or a
  /// live instance of the routed pool that appeared after routing and is
  /// on this item or on nothing.
  void readAgents() {
    final routedAt = reached[DispatchStep.routed];
    for (final agent in _agents) {
      final sessionId = agent.sessionId;
      if (sessionId != null && sessionIds.contains(sessionId)) {
        final at = agent.sessionStartedAt;
        reach(
          DispatchStep.agentStarting,
          routedAt != null && at != null && at.isBefore(routedAt)
              ? routedAt
              : at,
        );
        continue;
      }
      if (routedAt == null || routedTo == null || agent.pool != routedTo) {
        continue;
      }
      if (agent.state == AgentState.stopped || agent.suspended) continue;
      final onOther =
          agent.currentWorkId != null && agent.currentWorkId != item.id;
      if (onOther) continue;
      final at = agent.sessionStartedAt;
      if (at == null || at.isBefore(routedAt)) continue;
      reach(DispatchStep.agentStarting, at);
    }
  }

  void _countFlaps() {
    final stops = List.of(_stops)..sort((a, b) => a.$2.compareTo(b.$2));
    final used = <int>{};
    for (final (id, wokeAt) in _wakes) {
      for (var i = 0; i < stops.length; i++) {
        if (used.contains(i)) continue;
        final (stopId, stopAt) = stops[i];
        if (stopId != id || stopAt.isBefore(wokeAt)) continue;
        if (stopAt.difference(wokeAt) <= dispatchFlapWindow) {
          flaps += 1;
          used.add(i);
        }
        break;
      }
    }
  }

  /// A polecat that drained after its branch appeared pushed it and
  /// handed it to the refinery, whether or not the bead was reassigned
  /// yet. Without the branch a stopped session is only a stop.
  void _handoffFromDrain() {
    if (!_branchSeen) return;
    final branchAt = _branchAt;
    for (final (id, at) in _stops) {
      if (!sessionIds.contains(id)) continue;
      if (branchAt != null && at.isBefore(branchAt)) continue;
      reach(DispatchStep.pushed, at);
      reach(DispatchStep.handedToMerge, at);
    }
  }

  /// Orders the steps: a later step reached without an earlier one fills
  /// the earlier one at the same time; an earlier step timed after a
  /// later one is pulled back to it; a step reached at an unknown time
  /// stays untimed unless a later step is timed. The transcript counts
  /// as working once the item is claimed.
  Map<DispatchStep, DateTime?> resolve() {
    if (transcriptSeen && reached.containsKey(DispatchStep.claimed)) {
      reach(DispatchStep.working, reached[DispatchStep.claimed]);
    }
    final out = <DispatchStep, DateTime?>{};
    var seen = false;
    DateTime? floor;
    final steps = DispatchStep.values;
    for (var i = steps.length - 1; i >= 0; i--) {
      final step = steps[i];
      if (!seen && !reached.containsKey(step)) continue;
      seen = true;
      var at = reached[step];
      if (at == null) {
        at = floor;
      } else if (floor != null && at.isAfter(floor)) {
        at = floor;
      }
      out[step] = at;
      floor = at;
    }
    return out;
  }

  bool _isRefinery(String assignee) {
    if (!isRefineryName(assignee)) return false;
    final assigneeRig = _rigOf(assignee);
    return rig == null || assigneeRig == null || assigneeRig == rig;
  }
}

DateTime? _eventTime(OrchestrationEvent event) {
  final raw = event.raw;
  final value = raw['ts'] ?? raw['timestamp'] ?? _map(raw['data'])['ts'];
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value.trim());
}

String? _meta(Map<String, Object?> raw, String key) =>
    _text(_map(raw['metadata'])[key]);

String? _text(Object? value) => value is String ? value : null;

String? _clean(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String _status(String? value) =>
    (value ?? '').trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');

Map<String, Object?> _map(Object? value) => value is Map
    ? {for (final entry in value.entries) '${entry.key}': entry.value}
    : const {};

String? _rigOf(String? identity) {
  if (identity == null) return null;
  final slash = identity.indexOf('/');
  return slash <= 0 ? null : identity.substring(0, slash);
}
