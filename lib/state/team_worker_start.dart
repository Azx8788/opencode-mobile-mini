/// What the app can see of a worker's start, and how long the last one took
/// on this phone. Pure state plus one tiny per-profile preference; nothing
/// here reaches the network.
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../orchestration/models/agent.dart';

/// Where a starting worker stands, from what the host says of its session.
/// Never displayed as a name: the UI localises each value.
enum TeamWorkerStage {
  /// The host is making the worker's workspace and starting its program
  /// (session `creating` or `start-pending`).
  preparing,

  /// The worker's program is running but the host has not yet reported the
  /// task handed to it.
  running,

  /// The host reports the task delivered to the running worker; it is
  /// reading it and about to begin.
  taskDelivered,
}

/// The stage [agent]'s session is at, or null when the host names none the
/// app can read (then the line says only what is true: a worker is
/// starting).
TeamWorkerStage? teamWorkerStage(OrchestrationAgent? agent) {
  if (agent == null) return null;
  final raw = agent.sessionState?.trim().toLowerCase().replaceAll('_', '-');
  switch (raw) {
    case 'creating' || 'start-pending' || 'awake':
      return TeamWorkerStage.preparing;
    case 'active' || 'running':
      if (agent.sessionRunning == false) return TeamWorkerStage.preparing;
      final delivered = agent.raw['last_nudge_delivered_at'];
      if (delivered is String && delivered.isNotEmpty) {
        return TeamWorkerStage.taskDelivered;
      }
      return TeamWorkerStage.running;
  }
  return null;
}

/// A start longer or shorter than this is not a measurement of a normal
/// start (a clock jump, a session revived hours later).
const _plausible = (min: Duration(seconds: 1), max: Duration(minutes: 30));

/// The measured time from the worker's session being created to the worker
/// beginning the task, or null when it is not a plausible measurement.
Duration? teamWorkerStartMeasured({
  required DateTime? sessionStartedAt,
  required DateTime? began,
}) {
  if (sessionStartedAt == null || began == null) return null;
  final took = began.difference(sessionStartedAt);
  if (took < _plausible.min || took > _plausible.max) return null;
  return took;
}

/// The last worker start measured on this phone, per profile
/// (`oc.teamWorkerStart.<profileId>`, milliseconds). Swept with the profile
/// by the scoped-preference deletion.
class TeamWorkerStartStore {
  const TeamWorkerStartStore(this._prefs);

  final SharedPreferences _prefs;

  static String key(String profileId) => 'oc.teamWorkerStart.$profileId';

  Duration? read(String profileId) {
    try {
      final ms = _prefs.getInt(key(profileId));
      if (ms == null || ms <= 0) return null;
      return Duration(milliseconds: ms);
    } catch (_) {
      return null;
    }
  }

  /// Stores [took] when it differs from what is stored.
  Future<void> record(String profileId, Duration took) async {
    try {
      if (_prefs.getInt(key(profileId)) == took.inMilliseconds) return;
      await _prefs.setInt(key(profileId), took.inMilliseconds);
    } catch (_) {
      // A measurement that cannot be kept is only a missing estimate.
    }
  }
}
