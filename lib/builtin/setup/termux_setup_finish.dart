import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../../l10n/app_localizations.dart';
import '../../state/profiles.dart';
import '../../state/termux_host_setup.dart'
    show ManagedRuntimeFlavor, restoreManagedTermuxProfile;
import '../../termux/bridge.dart';
import '../../termux/managed_server_recovery.dart';
import '../../ui/kit/kit_redact.dart';
import 'setup_engine.dart';

/// The Termux server as the last step of a v2 setup job needs it: what it
/// runs now, a password and runtime handed to its manager, and a restart
/// that is waited on. [TermuxBridgeServerControl] is the real one; tests
/// stand in for Termux.
abstract class TermuxServerControl {
  /// What the manager reports now; idle before it was ever installed.
  Future<TermuxSetupStatus> status();

  /// Writes [runtime] and [password] where the manager reads them. Throws a
  /// [TermuxBridgeException] with code `runtime_mismatch` when Termux already
  /// serves the other OpenCode, and `switch_pending` during a switch: both
  /// belong to This phone's switch, never to a setup job.
  Future<void> stage({
    required TermuxRuntime runtime,
    required String password,
  });

  /// Restarts (or first starts) the server and waits until the manager says
  /// how that restart ended.
  Future<TermuxSetupStatus> restart();
}

/// [TermuxServerControl] through [TermuxBridge] and the Termux manager
/// (`~/.oc/manager.sh`), the one that already starts, stops and watches the
/// Termux server, so setup never starts it a second way.
class TermuxBridgeServerControl implements TermuxServerControl {
  TermuxBridgeServerControl({
    this.pollInterval = const Duration(seconds: 1),
    this.restartWait = const Duration(minutes: 3),
  });

  final Duration pollInterval;

  /// How long a restart may take before it counts as unconfirmed. The
  /// manager keeps its own journal, so the next attempt reads it again.
  final Duration restartWait;

  @override
  Future<TermuxSetupStatus> status() => TermuxBridge.status();

  @override
  Future<void> stage({
    required TermuxRuntime runtime,
    required String password,
  }) async {
    final result = await TermuxBridge.run(
      stageScript(runtime: runtime, password: password),
      timeout: const Duration(seconds: 20),
    );
    if (result.exitCode == 0) return;
    final said = '${result.stdout}\n${result.stderr}';
    if (said.contains('managed-runtime-switch-pending')) {
      throw const TermuxBridgeException(
        'A runtime switch is pending.',
        code: 'switch_pending',
      );
    }
    if (said.contains('managed-runtime-migration-required')) {
      throw const TermuxBridgeException(
        'Termux serves the other OpenCode.',
        code: 'runtime_mismatch',
      );
    }
    throw TermuxBridgeException(
      KitRedact.text(result.failureMessage),
      code: 'stage_failed',
    );
  }

  /// Hands the manager the runtime and the password the app keeps for this
  /// server. The password travels once, inside this command, and lands in
  /// a mode-600 file; it is never echoed.
  static String stageScript({
    required TermuxRuntime runtime,
    required String password,
  }) {
    runtime.requireSupported();
    if (password.isEmpty) {
      throw ArgumentError.value('', 'password', 'Must not be empty.');
    }
    final quoted = "'${password.replaceAll("'", r"'\''")}'";
    final wire = runtime.wireName;
    return '''
set -eu
OC_DIR="${TermuxBridge.termuxHome}/.oc"
mkdir -p "\$OC_DIR"
umask 077
[ ! -f "\$OC_DIR/runtime-switch" ] || { echo 'managed-runtime-switch-pending' >&2; exit 75; }
old_runtime=\$(cat "\$OC_DIR/runtime" 2>/dev/null || true)
old_version=\$(sed -n 's/^version=//p' "\$OC_DIR/state" 2>/dev/null || true)
if { [ -n "\$old_runtime" ] || [ -n "\$old_version" ]; } &&
   [ "\${old_runtime:-opencode1}" != '$wire' ]; then
  echo 'managed-runtime-migration-required' >&2
  exit 64
fi
printf '%s' '$wire' > "\$OC_DIR/runtime.tmp.\$\$"
mv "\$OC_DIR/runtime.tmp.\$\$" "\$OC_DIR/runtime"
password_tmp="\$OC_DIR/server.password.tmp.\$\$"
printf '%s' $quoted > "\$password_tmp"
chmod 600 "\$password_tmp"
mv "\$password_tmp" "\$OC_DIR/server.password"
echo staged
''';
  }

  @override
  Future<TermuxSetupStatus> restart() async {
    final operation = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    try {
      await TermuxBridge.run(
        TermuxBridge.restartScript(operationID: operation),
        timeout: const Duration(seconds: 45),
      );
    } on TermuxBridgeException catch (error) {
      // A restart that outlives the reply is still the manager's to finish:
      // its journal answers below.
      if (error.code != 'command_timeout') rethrow;
    }
    final deadline = DateTime.now().add(restartWait);
    while (true) {
      TermuxSetupStatus? status;
      try {
        status = await TermuxBridge.status();
      } on TermuxBridgeException {
        status = null;
      }
      if (status != null &&
          status.operationID == operation &&
          !status.isRunning) {
        return status;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const TermuxBridgeException(
          'The restart was not confirmed.',
          code: 'restart_unconfirmed',
        );
      }
      await Future<void>.delayed(pollInterval);
    }
  }
}

/// The last step of a Termux setup job ([SetupHostKind.termux]): start
/// OpenCode in Termux through its manager and connect to it, the way
/// [BuiltinSetupFinisher] does for the in-app host. Null only once the app
/// is connected; otherwise the reason, which the job shows on its start row
/// with Continue setup.
///
/// Idempotent, as the engine requires: a lost acknowledgement runs it again,
/// and a server already running the right OpenCode with the app connected
/// is left alone.
class TermuxSetupFinisher {
  TermuxSetupFinisher({
    required this.store,
    required this.connect,
    required this.isConnectedTo,
    required this.strings,
    TermuxServerControl? server,
  }) : server = server ?? TermuxBridgeServerControl();

  final ProfileStore store;

  /// Connects the app to [profile]; null on success, else why not.
  final Future<String?> Function(ServerProfile profile) connect;
  final bool Function(ServerProfile profile) isConnectedTo;
  final AppLocalizations Function() strings;
  final TermuxServerControl server;

  Future<String?> call(SetupFinishRequest request) async {
    final l10n = strings();
    // An in-app job must never touch the Termux server or its profile.
    if (request.host != SetupHostKind.termux) {
      return l10n.phoneSetupErrorCannotStart;
    }
    final runtime = request.runtime;
    try {
      // Setup ran before (an older build, cleared app data): the password
      // Termux holds is the one its server answers to, so it is taken back.
      await restoreManagedTermuxProfile(
        store,
        runtime,
        name: l10n.e7SetupThisDevice,
      );
      final profile = await _ensureProfile(runtime, l10n);
      TermuxSetupStatus? now;
      try {
        now = await server.status();
      } on TermuxBridgeException {
        now = null;
      }
      if (!request.openCodeChanged &&
          now != null &&
          now.isReady &&
          now.runtime == runtime &&
          isConnectedTo(profile)) {
        await ManagedServerRecovery.resumeAfterManualStartForProfile(
          store.prefs,
          profile.id,
        );
        return null;
      }
      await ManagedServerRecovery.suspendForProfile(store.prefs, profile.id);
      await server.stage(runtime: runtime, password: profile.password);
      final ended = await server.restart();
      if (!ended.isReady) {
        return l10n.e7SetupRestartFailed(KitRedact.text(ended.message));
      }
      await ManagedServerRecovery.resumeAfterManualStartForProfile(
        store.prefs,
        profile.id,
      );
      final version = ended.version.trim().isNotEmpty
          ? ended.version.trim()
          : request.version;
      if (version != null && profile.serverVersion != version) {
        profile.serverVersion = version;
        await store.upsert(profile);
      }
      return await connect(profile);
    } on TermuxBridgeException catch (error) {
      return switch (error.code) {
        'runtime_mismatch' => l10n.phoneSetupTermuxOtherRuntime,
        'switch_pending' => l10n.setupSwitchPending,
        'restart_unconfirmed' => l10n.e7SetupRestartUnconfirmed,
        _ => l10n.e7SetupRestartFailed(KitRedact.text(error.message)),
      };
    } catch (_) {
      return l10n.phoneSetupErrorCannotStart;
    }
  }

  static bool _isManaged(ServerProfile profile, TermuxRuntime runtime) =>
      profile.backend == ServerBackend.openCode &&
      profile.baseUrl == TermuxBridge.managedServerUrl &&
      ManagedRuntimeFlavor.runtimeOf(profile) == runtime;

  /// The saved Termux profile of [runtime], given a new password when it
  /// has none (a fresh install: nothing in Termux to take it back from).
  Future<ServerProfile> _ensureProfile(
    TermuxRuntime runtime,
    AppLocalizations l10n,
  ) async {
    ServerProfile? profile;
    for (final candidate in store.profiles) {
      if (_isManaged(candidate, runtime)) {
        profile = candidate;
        break;
      }
    }
    if (profile != null && profile.password.isNotEmpty) return profile;
    profile ??= ServerProfile(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: l10n.e7SetupThisDevice,
      baseUrl: TermuxBridge.managedServerUrl,
      flavor: ManagedRuntimeFlavor.flavorOf(runtime),
    );
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    profile
      ..username = 'opencode'
      ..password = base64UrlEncode(bytes).replaceAll('=', '')
      ..requiresPasswordReentry = false;
    await store.upsert(profile);
    return profile;
  }
}
