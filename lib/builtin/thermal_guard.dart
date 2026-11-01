import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../diagnostics/app_diagnostics.dart';
import '../diagnostics/perf_trace.dart';
import '../l10n/app_localizations.dart';
import '../platform/thermal.dart';
import '../background/thermal_pause_signal.dart';
import '../state/automation_policy.dart';

/// What the guard does next.
enum ThermalAction { none, pause, stop, resume }

/// What the guard holds on the team right now.
enum ThermalHold { none, paused, stopped }

/// The rules, with no platform in them (unit-tested on their own):
///
/// - SEVERE, or a 30-second forecast at [pauseHeadroom] or above: pause the
///   team.
/// - CRITICAL, EMERGENCY or SHUTDOWN: stop it (paused first, so its work is
///   saved).
/// - Resume only what the guard itself paused or stopped, and only once
///   the phone has stayed at MODERATE or below (forecast under
///   [pauseHeadroom]) for [coolFor]: a hot reading in between starts the
///   wait again, so it never flaps.
/// - Turned off, the guard starts nothing new, but still gives back what it
///   holds once the phone is cool.
class ThermalPolicy {
  ThermalPolicy({this.coolFor = const Duration(minutes: 2)});

  static const pauseAt = ThermalStatus.severe;
  static const stopAt = ThermalStatus.critical;
  static const pauseHeadroom = 0.95;

  final Duration coolFor;

  ThermalHold hold = ThermalHold.none;

  /// Since when the phone has been cool while the guard holds the team.
  DateTime? coolSince;

  static bool veryHot(ThermalReading reading) => reading.status.atLeast(stopAt);

  static bool hot(ThermalReading reading) =>
      reading.status.atLeast(pauseAt) ||
      (reading.headroom ?? 0) >= pauseHeadroom;

  static bool cool(ThermalReading reading) => !hot(reading);

  /// When the wait for a cool phone ends; null when not waiting.
  DateTime? get resumeAt =>
      hold == ThermalHold.none ? null : coolSince?.add(coolFor);

  ThermalAction decide(
    ThermalReading reading,
    DateTime now, {
    required bool enabled,
  }) {
    switch (hold) {
      case ThermalHold.none:
        coolSince = null;
        if (!enabled) return ThermalAction.none;
        if (veryHot(reading)) return ThermalAction.stop;
        if (hot(reading)) return ThermalAction.pause;
        return ThermalAction.none;
      case ThermalHold.paused:
      case ThermalHold.stopped:
        if (enabled && hold == ThermalHold.paused && veryHot(reading)) {
          coolSince = null;
          return ThermalAction.stop;
        }
        if (!cool(reading)) {
          coolSince = null;
          return ThermalAction.none;
        }
        final since = coolSince ??= now;
        return now.difference(since) >= coolFor
            ? ThermalAction.resume
            : ThermalAction.none;
    }
  }

  /// The guard did [action]; a failed or empty action is not reported.
  void applied(ThermalAction action) {
    switch (action) {
      case ThermalAction.pause:
        hold = ThermalHold.paused;
      case ThermalAction.stop:
        hold = ThermalHold.stopped;
      case ThermalAction.resume:
        hold = ThermalHold.none;
      case ThermalAction.none:
        return;
    }
    coolSince = null;
  }
}

/// A team on this phone the guard can pause: the built-in one, or a Gas
/// City team in Termux that the app reaches on loopback.
@immutable
class ThermalTeam {
  const ThermalTeam({
    required this.id,
    required this.url,
    this.city = '',
    this.builtin = false,
  });

  /// The profile it belongs to; the episode is saved under
  /// `oc.thermalPause.<id>` so deleting the profile sweeps it.
  final String id;
  final String url;
  final String city;

  /// The team inside this app: stopping it stops its service.
  final bool builtin;

  @override
  bool operator ==(Object other) =>
      other is ThermalTeam &&
      other.id == id &&
      other.url == url &&
      other.city == city &&
      other.builtin == builtin;

  @override
  int get hashCode => Object.hash(id, url, city, builtin);
}

/// What the guard paused on one team, so it gives back exactly that.
@immutable
class ThermalTeamHold {
  const ThermalTeamHold({
    required this.team,
    required this.since,
    this.sessions = const [],
    this.serviceStopped = false,
    this.status = ThermalStatus.unknown,
  });

  final ThermalTeam team;
  final DateTime since;

  /// Sessions that were running and that the guard suspended (their
  /// state is saved; a wake continues them).
  final List<String> sessions;

  /// The built-in team's supervisor, stopped by the guard.
  final bool serviceStopped;
  final ThermalStatus status;

  ThermalTeamHold copyWith({bool? serviceStopped, ThermalStatus? status}) =>
      ThermalTeamHold(
        team: team,
        since: since,
        sessions: sessions,
        serviceStopped: serviceStopped ?? this.serviceStopped,
        status: status ?? this.status,
      );

  Map<String, Object?> toJson() => {
    'url': team.url,
    'city': team.city,
    'builtin': team.builtin,
    'since': since.toUtc().toIso8601String(),
    'sessions': sessions,
    'serviceStopped': serviceStopped,
    'status': status.name,
  };

  static ThermalTeamHold? fromJson(String id, Object? raw) {
    if (raw is! Map) return null;
    final url = raw['url'];
    final since = DateTime.tryParse('${raw['since']}');
    if (url is! String || url.isEmpty || since == null) return null;
    final sessions = raw['sessions'];
    return ThermalTeamHold(
      team: ThermalTeam(
        id: id,
        url: url,
        city: '${raw['city'] ?? ''}',
        builtin: raw['builtin'] == true,
      ),
      since: since,
      sessions: [
        if (sessions is List)
          for (final s in sessions)
            if (s is String && s.isNotEmpty) s,
      ],
      serviceStopped: raw['serviceStopped'] == true,
      status: ThermalStatus.parse(raw['status']),
    );
  }
}

/// How the guard reaches the teams on this phone (thermal_guard_teams.dart
/// for Gas City; a fake in tests).
abstract class ThermalTeamPort {
  /// Teams that run on this phone and are working now; a team the person
  /// suspended is not listed.
  Future<List<ThermalTeam>> runningHere();

  /// Suspends [team] so its work and sessions are kept; null when there
  /// was nothing to pause (the person had paused it, or it is gone).
  Future<ThermalTeamHold?> pause(ThermalTeam team, {required DateTime now});

  /// Stops [hold]'s team safely where the app can (the built-in team's
  /// service); the hold as it is afterwards.
  Future<ThermalTeamHold> stop(ThermalTeamHold hold);

  /// Gives back exactly what [hold] took. False when any session's wake is
  /// unconfirmed (the guard retains the durable hold and tries again later).
  /// Confirmed running or deleted sessions need no further wake.
  Future<bool> resume(ThermalTeamHold hold);
}

/// The one line the person sees about the guard.
enum ThermalNoticeKind { paused, stopped, resumed }

@immutable
class ThermalNotice {
  const ThermalNotice(this.kind, this.at);

  final ThermalNoticeKind kind;
  final DateTime at;
}

/// The words of [notice] (the shell's line and the notification).
String thermalNoticeText(AppLocalizations l10n, ThermalNoticeKind kind) =>
    switch (kind) {
      ThermalNoticeKind.paused => l10n.thermalPausedNotice,
      ThermalNoticeKind.stopped => l10n.thermalStoppedNotice,
      ThermalNoticeKind.resumed => l10n.thermalResumedNotice,
    };

/// Watches how hot the phone is and pauses the AI Team on this phone when
/// Android says it is hot ([ThermalPolicy]); resumes it once cool. Tells
/// the person once per episode: the shell line ([notice]) and, while the
/// app is in the background, one notification on the team's existing
/// status channel.
class ThermalGuard extends ChangeNotifier {
  ThermalGuard({
    required this.bridge,
    required this.port,
    required this.prefs,
    ThermalPolicy? policy,
    DateTime Function()? clock,
    bool Function()? inBackground,
    AppLocalizations Function()? strings,
    this.diagnostics,
    this.onReading,
    this.onAct,
  }) : policy = policy ?? ThermalPolicy(),
       _clock = clock ?? DateTime.now;

  static const enabledKey = 'oc.thermalGuard';
  static const holdKeyPrefix = 'oc.thermalPause.';

  final ThermalBridge bridge;
  final ThermalTeamPort port;
  final SharedPreferences prefs;
  final ThermalPolicy policy;
  AppDiagnosticsController? diagnostics;

  /// Sees every reading the guard acts on, e.g. the persisted problem
  /// report's thermal history. Reuses the guard's one native listener.
  final void Function(ThermalReading reading)? onReading;

  /// Told once per team after the guard CONFIRMED a pause, a stop or a
  /// resume ([kind]), with the episode's start ([since]) and the act's time:
  /// the app files it in that server's While you were away (P6.2).
  final void Function(
    ThermalNoticeKind kind,
    ThermalTeam team,
    DateTime since,
    DateTime at,
  )?
  onAct;
  final DateTime Function() _clock;

  final Map<String, ThermalTeamHold> _holds = {};
  ThermalReading _last = ThermalReading.unknown;
  ThermalNotice? _notice;
  StreamSubscription<ThermalReading>? _readings;
  Timer? _coolTimer;
  Future<void> _queue = Future.value();
  bool _started = false;
  bool _disposed = false;

  /// "Pause the AI Team when the phone is hot" (Settings); on by default.
  bool get enabled => prefs.getBool(enabledKey) ?? true;

  Future<void> setEnabled(bool value) async {
    await prefs.setBool(enabledKey, value);
    PerfTrace.mark('thermal.setting', attrs: {'enabled': value});
    _notify();
    await evaluate();
  }

  ThermalHold get hold => policy.hold;
  ThermalReading get lastReading => _last;
  Map<String, ThermalTeamHold> get holds => Map.unmodifiable(_holds);

  /// The line to show until dismissed.
  ThermalNotice? get notice => _notice;

  void dismiss() {
    if (_notice == null) return;
    _notice = null;
    _notify();
  }

  /// Once per process: what an earlier process held (it may have died while
  /// the team was paused), the current reading, then every change.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _restoreHolds();
    _readings = bridge.readings().listen(observe);
    await observe(await bridge.current());
  }

  /// One reading from Android (the stream, or a test).
  Future<void> observe(ThermalReading reading) {
    _last = reading;
    try {
      onReading?.call(reading);
    } catch (error, stack) {
      diagnostics?.record(error, stack, source: 'thermal');
    }
    return evaluate();
  }

  /// Applies the rules to the newest reading; one run at a time.
  Future<void> evaluate() => _queue = _queue
      .then((_) => _evaluate())
      .catchError((Object error, StackTrace stack) {
        diagnostics?.record(error, stack, source: 'thermal');
      });

  Future<void> _evaluate() async {
    if (_disposed) return;
    final now = _clock();
    final action = policy.decide(_last, now, enabled: enabled);
    switch (action) {
      case ThermalAction.none:
        break;
      case ThermalAction.pause:
        await _pause(now, alsoStop: false);
      case ThermalAction.stop:
        await _pause(now, alsoStop: true);
      case ThermalAction.resume:
        await _resume(now);
    }
    _scheduleCoolCheck(now);
  }

  Future<void> _pause(DateTime now, {required bool alsoStop}) async {
    final escalating = policy.hold == ThermalHold.paused;
    final paused = <ThermalTeamHold>[];
    if (!escalating) {
      for (final team in await port.runningHere()) {
        if (_holds.containsKey(team.id)) continue;
        final held = await port.pause(team, now: now);
        if (held != null) {
          _holds[team.id] = held.copyWith(status: _last.status);
          paused.add(held);
        }
      }
      if (_holds.isEmpty) return; // no team working on this phone
    }
    if (alsoStop) {
      for (final entry in _holds.entries.toList()) {
        _holds[entry.key] = (await port.stop(
          entry.value,
        )).copyWith(status: _last.status);
      }
    }
    for (final held in _holds.values) {
      await _saveHold(held);
    }
    final action = alsoStop ? ThermalAction.stop : ThermalAction.pause;
    policy.applied(action);
    final name = alsoStop ? 'thermal.stop' : 'thermal.pause';
    PerfTrace.mark(
      name,
      attrs: {
        ..._last.traceAttrs,
        'teams': _holds.length,
        'sessions': _holds.values.fold<int>(0, (n, h) => n + h.sessions.length),
      },
    );
    diagnostics?.record(
      '$name: ${_last.status.name}'
      '${_last.headroom == null ? '' : ', headroom ${_last.headroom!.toStringAsFixed(2)}'}'
      ', ${_holds.length} team(s)',
      null,
      source: 'thermal',
      at: now,
    );
    final kind = alsoStop
        ? ThermalNoticeKind.stopped
        : ThermalNoticeKind.paused;
    final act = onAct;
    if (act != null) {
      for (final held in alsoStop ? _holds.values : paused) {
        act(kind, held.team, held.since, now);
      }
    }
    _notice = ThermalNotice(kind, now);
    _notify();
    // The pause shows in the one status notification (thermalPauseActive);
    // the guard posts nothing of its own.
  }

  Future<void> _resume(DateTime now) async {
    final since = _holds.values.isEmpty
        ? now
        : _holds.values
              .map((hold) => hold.since)
              .reduce((a, b) => a.isBefore(b) ? a : b);
    var allBack = true;
    for (final entry in _holds.entries.toList()) {
      if (!_allowsRecovery(entry.key)) {
        allBack = false;
        continue;
      }
      if (await port.resume(entry.value)) {
        _holds.remove(entry.key);
        await _dropHold(entry.key);
        onAct?.call(
          ThermalNoticeKind.resumed,
          entry.value.team,
          entry.value.since,
          now,
        );
      } else {
        allBack = false;
      }
    }
    if (!allBack) {
      // Unreachable for now; the wait starts again and it is tried later.
      policy.coolSince = now;
      return;
    }
    policy.applied(ThermalAction.resume);
    final duration = now.difference(since);
    PerfTrace.recordDuration(
      'thermal.resume',
      duration,
      attrs: {..._last.traceAttrs, 'minutes': duration.inMinutes},
    );
    diagnostics?.record(
      'thermal.resume: ${_last.status.name} after ${duration.inMinutes} min',
      null,
      source: 'thermal',
      at: now,
    );
    _notice = ThermalNotice(ThermalNoticeKind.resumed, now);
    _notify();
  }

  void _scheduleCoolCheck(DateTime now) {
    _coolTimer?.cancel();
    _coolTimer = null;
    final at = policy.resumeAt;
    if (at == null || _disposed || !_holds.keys.any(_allowsRecovery)) {
      return;
    }
    final wait = at.difference(now);
    _coolTimer = Timer(
      wait.isNegative ? Duration.zero : wait + const Duration(seconds: 1),
      () => unawaited(evaluate()),
    );
  }

  // The optional recovery choice never disables protective pause/stop.
  bool _allowsRecovery(String profileId) =>
      AutomationPolicyController.forProfile(
        prefs,
        profileId,
      ).value.allows(AutomationBehavior.thermalRecovery);

  void _restoreHolds() {
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(holdKeyPrefix)) continue;
      final id = key.substring(holdKeyPrefix.length);
      ThermalTeamHold? held;
      try {
        held = ThermalTeamHold.fromJson(
          id,
          jsonDecode(prefs.getString(key) ?? ''),
        );
      } on Object {
        held = null;
      }
      if (held == null) {
        unawaited(prefs.remove(key));
      } else {
        _holds[id] = held;
      }
    }
    if (_holds.isEmpty) return;
    policy.hold = _holds.values.any((hold) => hold.serviceStopped)
        ? ThermalHold.stopped
        : ThermalHold.paused;
    PerfTrace.mark('thermal.restore', attrs: {'teams': _holds.length});
  }

  Future<void> _saveHold(ThermalTeamHold held) => prefs.setString(
    '$holdKeyPrefix${held.team.id}',
    jsonEncode(held.toJson()),
  );

  Future<void> _dropHold(String id) => prefs.remove('$holdKeyPrefix$id');

  void _notify() {
    if (_disposed) return;
    thermalPauseActive.value = policy.hold != ThermalHold.none;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    thermalPauseActive.value = false;
    _coolTimer?.cancel();
    unawaited(_readings?.cancel());
    super.dispose();
  }
}
