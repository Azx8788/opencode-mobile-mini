import 'package:flutter/foundation.dart';

import '../domain/server_probe.dart';
import '../builtin/builtin_linux.dart';
import '../builtin/builtin_server.dart';
import '../builtin/team/builtin_team.dart';
import '../platform/app_exit.dart';
import 'profiles.dart';

/// Readiness observed now, never inferred from Android's historical exit record.
enum LifecycleReadiness {
  unchecked,
  checking,
  unavailable,
  stopped,
  unreachable,
  partial,
  ready,
}

/// Presentation-safe facts for a localised, one-line recovery notice.
///
/// Contains no native description, server response, profile or credentials.
/// `everythingBack` means the server and previously running services answer
/// health checks; it does not promise that interrupted agent tasks resumed.
@immutable
class LifecycleReport {
  const LifecycleReport({
    this.readiness = LifecycleReadiness.unchecked,
    this.exitKind,
    this.stoppedAt,
    this.hadServices = false,
    this.dismissed = false,
  });

  final LifecycleReadiness readiness;
  final AppExitKind? exitKind;
  final DateTime? stoppedAt;
  final bool hadServices;
  final bool dismissed;

  bool get showNotice =>
      !dismissed && hadServices && (exitKind?.notable ?? false);

  bool get everythingBack =>
      showNotice && readiness == LifecycleReadiness.ready;
}

/// Foreground, read-only companion to [BuiltinServerStarter] and
/// `AppExitRecovery`. Own one per app process and listen with ListenableBuilder.
///
/// Call [refresh] after the existing start/reconnect path completes. Call
/// [invalidate] before a start, on backgrounding, or on profile changes/deletion.
/// This service never starts a process, schedules retries, persists data, or
/// extends a background budget. Dispose it with its owner.
class LifecycleReportController extends ChangeNotifier {
  LifecycleReportController({
    required this.linux,
    AppLifecycleBridge? bridge,
    BuiltinTeam? team,
    ServerProbe? probe,
  }) : _bridge = bridge ?? AppLifecycleBridge(),
       _team = team ?? BuiltinTeam(linux: linux),
       _probe = probe ?? serverProbe;

  final BuiltinLinux linux;
  final AppLifecycleBridge _bridge;
  final BuiltinTeam _team;
  final ServerProbe _probe;
  Future<AppLaunchReport>? _launch;
  AppLaunchReport? _history;
  LifecycleReport _value = const LifecycleReport();
  int _epoch = 0;
  bool _disposed = false;
  bool _dismissed = false;

  LifecycleReport get value => _value;

  /// Removes previous health evidence immediately and rejects in-flight results.
  void invalidate() {
    if (_disposed) return;
    _epoch++;
    _publish(LifecycleReadiness.unchecked);
  }

  /// Dismissal lasts for this app process; there is no extra preference to erase.
  void dismiss() {
    if (_disposed || _dismissed) return;
    _dismissed = true;
    _publish(_value.readiness);
  }

  /// Checks only the built-in phone server, using its saved authentication.
  /// Remote and Termux profiles are unavailable and are never probed.
  /// A process/PID alone is insufficient evidence of recovery.
  Future<void> refresh(ServerProfile? profile) async {
    if (_disposed) return;
    final epoch = ++_epoch;
    bool current() => !_disposed && epoch == _epoch;
    if (!looksLikeInAppServer(profile)) {
      _publish(LifecycleReadiness.unavailable);
      return;
    }
    // Capture credentials before any await; never expose them in the report.
    final username = profile!.username;
    final password = profile.password;
    final requiresPasswordReentry = profile.requiresPasswordReentry;
    final teamConfigured = BuiltinTeam.isBuiltinConfig(profile.orchestration);
    _publish(LifecycleReadiness.checking);
    try {
      final history = await (_launch ??= _bridge.launchReport());
      if (!current()) return;
      _history = history;
      final status = await linux.status();
      if (!current()) return;
      if (!status.installed) {
        _publish(LifecycleReadiness.unavailable);
        return;
      }
      if (!status.serverRunning) {
        _publish(LifecycleReadiness.stopped);
        return;
      }
      if (password.isEmpty || requiresPasswordReentry) {
        _publish(LifecycleReadiness.unreachable);
        return;
      }
      final health = await _probe(
        baseUrl: BuiltinLinux.serverUrl,
        username: username,
        password: password,
      );
      if (!current()) return;
      if (!health.ok) {
        _publish(LifecycleReadiness.unreachable);
        return;
      }
      // Unknown services cannot silently be counted as recovered.
      if (history.previousServices.any(
        (name) =>
            name != BuiltinLinux.serverServiceName &&
            name != BuiltinTeam.serviceName,
      )) {
        _publish(LifecycleReadiness.partial);
        return;
      }
      final teamWasRunning = history.previousServices.contains(
        BuiltinTeam.serviceName,
      );
      if (teamWasRunning || teamConfigured) {
        if (!teamConfigured ||
            !status.serviceRunning(BuiltinTeam.serviceName)) {
          _publish(LifecycleReadiness.partial);
          return;
        }
        final supervisorReady = await _team.supervisorAnswers();
        if (!current()) return;
        final cityReady = supervisorReady && await _team.cityAnswers();
        if (!current()) return;
        if (!cityReady) {
          _publish(LifecycleReadiness.partial);
          return;
        }
      }
      _publish(LifecycleReadiness.ready);
    } catch (_) {
      if (!current()) return;
      // A failed launch read can be retried. No exception text is published.
      if (_history == null) _launch = null;
      _publish(LifecycleReadiness.unavailable);
    }
  }

  void _publish(LifecycleReadiness readiness) {
    _value = LifecycleReport(
      readiness: readiness,
      exitKind: _history?.exit?.kind,
      stoppedAt: _history?.exit?.timestamp,
      hadServices: _history?.previousServices.isNotEmpty ?? false,
      dismissed: _dismissed,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    super.dispose();
  }
}
