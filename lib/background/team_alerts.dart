/// AI Team notifications (TEAM-203, 02-ux §6, 06 decision 8): which of the
/// plugin's changes deserve a push, decided from snapshots alone.
///
/// Four kinds push — a new decision (pending interaction), a failed run, a
/// run ready for review and a completed run; everything else stays silent.
/// One alert per gate or run id, ever: the tracker remembers what it
/// already announced, so a refetch, a reconnect or a flapping run never
/// posts twice. The first snapshot with data is the baseline and announces
/// nothing: what the person could already see in the app is not news.
///
/// The tracker only decides; posting, the settings toggle and the quiet
/// rules stay with `ConnectionController`, which also owns the app's
/// other alerts. Alerts carry ids only — the copy is fixed on the native
/// side and no title or prompt ever leaves the app.
library;

import '../domain/orchestration_gateway.dart';
import '../state/orchestration.dart';
import 'live_background.dart';

/// One alert the tracker asks for: the kind, the route id its tap opens
/// (a gate id, or a run id for [CodingAlertKind.teamCompleted]) and the
/// notification key that dedupes it on the platform side.
class TeamAlert {
  const TeamAlert({required this.kind, required this.id, required this.key});

  final CodingAlertKind kind;
  final String id;
  final String key;

  @override
  bool operator ==(Object other) =>
      other is TeamAlert &&
      other.kind == kind &&
      other.id == id &&
      other.key == key;

  @override
  int get hashCode => Object.hash(kind, id, key);

  @override
  String toString() => 'TeamAlert(${kind.name} $id)';
}

/// What one [TeamAlertTracker.observe] found: alerts to post and keys of
/// earlier alerts whose gate left the snapshot (answered or closed on the
/// host), which the caller dismisses.
class TeamAlertDiff {
  const TeamAlertDiff({this.alerts = const [], this.settled = const []});

  static const none = TeamAlertDiff();

  final List<TeamAlert> alerts;
  final List<String> settled;

  bool get isEmpty => alerts.isEmpty && settled.isEmpty;
}

/// The notification key of a gate alert on [profileId].
String teamGateAlertKey(String profileId, String gateId) =>
    'team:$profileId:gate:$gateId';

/// The notification key of a completed-run alert on [profileId].
String teamRunAlertKey(String profileId, String runId) =>
    'team:$profileId:run:$runId';

/// The alert kind a gate maps to; null for kinds that stay silent (gate
/// beads and blocked agents are seen in the app, not pushed).
CodingAlertKind? teamAlertKindFor(GateKind kind) => switch (kind) {
  GateKind.choice ||
  GateKind.confirmation ||
  GateKind.freeText ||
  GateKind.unknown => CodingAlertKind.teamDecision,
  GateKind.runFailed => CodingAlertKind.teamRunFailed,
  GateKind.reviewReady => CodingAlertKind.teamReview,
  GateKind.gateBead => null,
};

/// Folds successive snapshots of one profile's plugin into alerts.
class TeamAlertTracker {
  TeamAlertTracker({required this.profileId});

  final String profileId;

  bool _primed = false;
  final _knownGates = <String>{};
  final _runStates = <String, RunState>{};
  final _announced = <String>{};

  /// Keys of gate alerts posted and not yet settled, by gate id.
  final _openGateAlerts = <String, String>{};

  /// True once a snapshot with data set the baseline.
  bool get primed => _primed;

  /// Ids already announced; never announced again.
  Set<String> get announced => Set.unmodifiable(_announced);

  /// Feeds the latest snapshot and returns what changed since the last
  /// call. Nothing before the first snapshot with data; that snapshot
  /// itself only sets the baseline.
  TeamAlertDiff observe(OrchestrationSnapshot snapshot) {
    if (!snapshot.hasData) return TeamAlertDiff.none;
    final gateIds = {for (final gate in snapshot.gates) gate.id};
    final runStates = {for (final run in snapshot.runs) run.id: run.state};
    if (!_primed) {
      _primed = true;
      _knownGates.addAll(gateIds);
      _runStates.addAll(runStates);
      return TeamAlertDiff.none;
    }

    final alerts = <TeamAlert>[];
    final settled = <String>[];

    for (final gate in snapshot.gates) {
      if (_knownGates.contains(gate.id)) continue;
      final kind = teamAlertKindFor(gate.kind);
      if (kind == null || !_announced.add(gate.id)) continue;
      final key = teamGateAlertKey(profileId, gate.id);
      _openGateAlerts[gate.id] = key;
      alerts.add(TeamAlert(kind: kind, id: gate.id, key: key));
    }
    for (final entry in _openGateAlerts.entries.toList()) {
      if (gateIds.contains(entry.key)) continue;
      _openGateAlerts.remove(entry.key);
      settled.add(entry.value);
    }
    _knownGates
      ..clear()
      ..addAll(gateIds);

    for (final entry in runStates.entries) {
      final before = _runStates[entry.key];
      // A run the tracker never saw and that is already complete is
      // history, not news; a known run that just completed is.
      if (entry.value != RunState.completed ||
          before == null ||
          before == RunState.completed) {
        continue;
      }
      final id = 'run:${entry.key}';
      if (!_announced.add(id)) continue;
      alerts.add(
        TeamAlert(
          kind: CodingAlertKind.teamCompleted,
          id: entry.key,
          key: teamRunAlertKey(profileId, entry.key),
        ),
      );
    }
    _runStates
      ..clear()
      ..addAll(runStates);

    return TeamAlertDiff(alerts: alerts, settled: settled);
  }

  /// Every key this tracker asked to post and did not settle, for a
  /// dismiss-all.
  List<String> get openKeys => _openGateAlerts.values.toList();

  /// Forgets the open gate alerts (they were dismissed); announced ids
  /// stay announced.
  void clearOpen() => _openGateAlerts.clear();
}
