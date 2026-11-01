import 'dart:async';

import '../termux/bridge.dart';
import '../termux/managed_server_recovery.dart';
import 'connection.dart';
import 'profiles.dart';
import 'termux_host_setup.dart' show ManagedRuntimeFlavor;

/// Why an in-place control of the phone's server did not finish.
class LocalServerControlFailure implements Exception {
  const LocalServerControlFailure(this.message);

  /// The manager's own message when it gave one, otherwise empty: the caller
  /// supplies localized fallback copy.
  final String message;
}

/// Start, restart and stop for the app-managed server on this phone, for
/// surfaces that are not the setup wizard.
///
/// The wizard owns installation and runtime switching. These are the three
/// verbs a person needs on a server that is already set up, run through the
/// same manager scripts the wizard uses so both leave identical state behind.
class LocalServerControls {
  const LocalServerControls({required this.store, required this.connection});

  final ProfileStore store;
  final ConnectionController connection;

  static const _poll = Duration(seconds: 2);

  /// Starts a stopped server, or restarts a running one, and waits until it
  /// answers as ready. The manager treats both as one verb.
  Future<TermuxSetupStatus> restart({
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final operationID = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    try {
      for (final profile in store.profiles.where(
        (p) => TermuxBridge.managesServerUrl(p.baseUrl),
      )) {
        await ManagedServerRecovery.suspendForProfile(store.prefs, profile.id);
      }
      await TermuxBridge.run(
        TermuxBridge.restartScript(operationID: operationID),
        timeout: const Duration(seconds: 45),
      );
    } on TermuxBridgeException catch (error) {
      // The dispatcher can outlive the bridge's patience while the server is
      // still coming up; the status poll below is the authority.
      if (error.code != 'command_timeout') {
        throw LocalServerControlFailure(error.message);
      }
    }
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final TermuxSetupStatus status;
      try {
        status = await TermuxBridge.status();
      } on TermuxBridgeException catch (error) {
        throw LocalServerControlFailure(error.message);
      }
      if (status.isReady && status.operationID == operationID) {
        for (final profile in store.profiles.where(
          (p) =>
              TermuxBridge.managesServerUrl(p.baseUrl) &&
              ManagedRuntimeFlavor.runtimeOf(p) == status.runtime,
        )) {
          await ManagedServerRecovery.resumeAfterManualStartForProfile(
            store.prefs,
            profile.id,
          );
        }
        return status;
      }
      if (status.isFailed) throw LocalServerControlFailure(status.message);
      if (!status.isRunning || DateTime.now().isAfter(deadline)) {
        throw const LocalServerControlFailure('');
      }
      await Future<void>.delayed(_poll);
    }
  }

  /// Stops the server and suspends recovery without changing the person's
  /// restart preference. An explicit successful start resumes monitoring.
  Future<void> stop() async {
    for (final profile in store.profiles.where(
      (p) => TermuxBridge.managesServerUrl(p.baseUrl),
    )) {
      try {
        await ManagedServerRecovery.suspendForProfile(store.prefs, profile.id);
      } catch (_) {
        // Stop stays available when preference storage fails: the stop script
        // revokes the recovery permit itself before stopping the manager.
      }
    }
    try {
      await TermuxBridge.run(TermuxBridge.stopScript());
    } on TermuxBridgeException catch (error) {
      throw LocalServerControlFailure(error.message);
    }
    final connected = connection.profile;
    if (connection.api != null &&
        connected != null &&
        TermuxBridge.managesServerUrl(connected.baseUrl)) {
      await connection.disconnect(keepActive: true);
    }
  }
}
