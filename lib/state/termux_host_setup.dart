import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;

import '../l10n/app_localizations.dart';
import '../domain/opencode_history_copy.dart';
import '../termux/bridge.dart';
import '../termux/managed_server_recovery.dart';
import '../ui/kit/kit_redact.dart';
import 'connection.dart';
import 'move_to_opencode2.dart';
import 'profiles.dart';

/// Where a Termux-hosted setup stands (phone setup v2, the Termux host).
enum TermuxHostPhase {
  /// Reading what Termux says.
  checking,

  /// Termux is not on the phone: a step only the person can do.
  needTermux,

  /// Termux is there but has not let the app run commands yet: a step only
  /// the person can do (paste one line in Termux).
  needAllow,

  /// Termux answers and nothing is running; the job has not started.
  idle,

  /// The Termux manager is installing, switching or starting OpenCode.
  working,

  /// OpenCode is ready in Termux and the app is connecting to it.
  connecting,

  /// OpenCode runs in Termux and the app is connected (or the job did not
  /// ask to connect).
  ready,

  /// Something failed: [TermuxHostSetup.error] says what.
  failed,
}

/// What the person asked the Termux host to do.
enum TermuxHostJob {
  /// First setup: Termux, the permission, Linux, OpenCode, start, connect.
  /// An OpenCode Termux already has is started rather than installed again.
  install,

  /// Install the pinned OpenCode of the runtime already chosen, then restart.
  update,

  /// Switch between OpenCode 1 and 2 ([TermuxHostSetup.target]).
  switchRuntime,

  /// Start the OpenCode already installed, then connect.
  start,
}

/// The Termux host of phone setup v2: everything the old Termux wizard did
/// to install, update, switch and start OpenCode in Termux, without its
/// pages. The v2 progress screen draws it as a checklist and This phone
/// hands it the update and switch jobs.
///
/// It talks to Termux only through [TermuxBridge] and runs the same manager
/// scripts the wizard ran, so an install begun by an older build is picked
/// up and continued, never started twice.
class TermuxHostSetup extends ChangeNotifier {
  TermuxHostSetup({
    required this.store,
    required this.connection,
    required this.copy,
    this.pollInterval = const Duration(seconds: 1),
    this.connectWhenReady = true,
  });

  final ProfileStore store;
  final ConnectionController connection;

  /// The person's language, for the few messages the host words itself.
  final AppLocalizations Function() copy;
  final Duration pollInterval;

  /// Whether a job that ends with OpenCode ready connects to it.
  final bool connectWhenReady;

  static const port = TermuxBridge.managedServerPort;
  static const localUrl = TermuxBridge.managedServerUrl;

  TermuxHostPhase _phase = TermuxHostPhase.checking;
  TermuxHostPhase get phase => _phase;

  TermuxHostJob? _job;
  TermuxHostJob? get job => _job;

  /// The runtime a [TermuxHostJob.switchRuntime] goes to.
  TermuxRuntime? _target;
  TermuxRuntime? get target => _target;

  TermuxSetupStatus? _status;
  TermuxSetupStatus? get status => _status;

  TermuxInstallation? _installation;
  TermuxInstallation? get installation => _installation;

  String _output = '';

  /// The manager's install log and server output, newest last.
  String get output => _output;

  String? _error;

  /// The raw failure: the exact bridge or manager wording, kept for the
  /// copied report; [TermuxHostSetup.plainError] is what a person reads.
  String? get error => _error;

  bool _monitoringFailed = false;

  /// The app lost track of a setup Termux may still be running: the way on
  /// is to look again, not to start over.
  bool get monitoringFailed => _monitoringFailed;

  bool _busy = false;
  bool get busy => _busy;

  /// The person went to Termux to paste the unlock line and has not come
  /// back yet.
  bool _openedTermux = false;
  bool get openedTermux => _openedTermux;

  bool _returnedFromTermux = false;
  bool get returnedFromTermux => _returnedFromTermux;

  String? _lastLaunchOutput;

  bool _jobStarted = false;
  bool _disposed = false;
  bool _polling = false;
  bool _launching = false;
  int _epoch = 0;
  int _snapshotFailures = 0;
  Timer? _poll;

  /// The manager operation this job waits for (a switch or a start); a
  /// ready snapshot of another operation is not this job's answer.
  String? _operationID;

  /// The runtime Termux runs or last ran.
  TermuxRuntime get runtime {
    final status = _status;
    if (status != null &&
        (status.runtimeSelected || status.version.isNotEmpty)) {
      return status.runtime;
    }
    final installation = _installation;
    if (installation != null &&
        (installation.runtimeSelected || installation.ubuntuInstalled)) {
      return installation.runtime;
    }
    for (final profile in store.profiles) {
      if (profile.backend == ServerBackend.openCode &&
          profile.baseUrl == localUrl) {
        return ManagedRuntimeFlavor.runtimeOf(profile);
      }
    }
    return TermuxRuntime.defaultForNewInstall;
  }

  /// The OpenCode version Termux reported, if any.
  String? get installedVersion {
    final version = _status?.version.trim();
    if (version != null && version.isNotEmpty) return version;
    return _installation?.openCodeVersion;
  }

  /// When the running operation began, for the elapsed time.
  int? get startedAtEpochSeconds => _status?.startedAtEpochSeconds;

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    super.dispose();
  }

  void _set(void Function() change) {
    if (_disposed) return;
    change();
    notifyListeners();
  }

  // --- Profiles ------------------------------------------------------------

  static bool _isManaged(ServerProfile profile, TermuxRuntime runtime) =>
      profile.backend == ServerBackend.openCode &&
      profile.baseUrl == localUrl &&
      ManagedRuntimeFlavor.runtimeOf(profile) == runtime;

  /// The saved profile of [runtime] with a password, if there is one.
  ServerProfile? localProfile([TermuxRuntime? runtime]) {
    final wanted = runtime ?? this.runtime;
    ServerProfile? fallback;
    for (final profile in store.profiles) {
      if (_isManaged(profile, wanted) && profile.password.isNotEmpty) {
        if (profile.id == store.activeId) return profile;
        fallback ??= profile;
      }
    }
    return fallback;
  }

  Future<ServerProfile> _ensureLocalProfile(
    TermuxRuntime runtime, {
    bool forSwitch = false,
  }) async {
    if (forSwitch && runtime == TermuxRuntime.openCode2) {
      final original = localProfile(TermuxRuntime.openCode1);
      if (original != null) return original;
    }
    ServerProfile? profile;
    for (final candidate in store.profiles) {
      if (_isManaged(candidate, runtime)) {
        profile = candidate;
        break;
      }
    }
    if (forSwitch && profile != null && profile.password.isNotEmpty) {
      return profile;
    }
    final l10n = copy();
    profile ??= ServerProfile(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: forSwitch
          ? l10n.setupSwitchProfileName(_runtimeName(l10n, runtime))
          : l10n.e7SetupThisDevice,
      baseUrl: localUrl,
      flavor: ManagedRuntimeFlavor.flavorOf(runtime),
      requiresOpenCode2Migration: runtime == TermuxRuntime.openCode1,
    );
    profile.username = 'opencode';
    if (profile.password.isEmpty) {
      final random = Random.secure();
      final bytes = List<int>.generate(32, (_) => random.nextInt(256));
      profile.password = base64UrlEncode(bytes).replaceAll('=', '');
    }
    await store.upsert(profile);
    return profile;
  }

  /// OpenCode is installed in Termux but the app holds no password for it (a
  /// reinstall, cleared app data): the app wrote that password into Termux
  /// at setup, so it takes it back from there.
  Future<void> restoreProfileIfMissing(TermuxRuntime runtime) async {
    await restoreManagedTermuxProfile(
      store,
      runtime,
      name: copy().e7SetupThisDevice,
    );
    _set(() {});
  }

  static String _runtimeName(AppLocalizations l10n, TermuxRuntime runtime) =>
      l10n.setupRuntimeTwo;

  // --- Checking Termux -----------------------------------------------------

  /// Starts [job] (a switch goes to [target]): checks Termux, waits on the
  /// person's steps when Termux is missing or not yet allowed, then runs.
  /// A setup Termux is already running is followed, never started again.
  Future<void> begin(TermuxHostJob job, {TermuxRuntime? target}) async {
    _job = job;
    _target = target;
    _jobStarted = false;
    await check();
  }

  /// Reads Termux again: after the app comes back from Termux or the F-Droid
  /// page, and on the person's "Try again".
  Future<void> check() async {
    if (_busy || _launching) return;
    final epoch = _epoch;
    _set(() {
      _phase = TermuxHostPhase.checking;
      _error = null;
    });
    try {
      final capabilities = await TermuxBridge.capabilities();
      if (_disposed || epoch != _epoch) return;
      if (!capabilities.installed) {
        _set(() => _phase = TermuxHostPhase.needTermux);
        return;
      }
      if (!capabilities.serviceAvailable || !capabilities.protocolSupported) {
        _set(() {
          _phase = TermuxHostPhase.failed;
          _error = copy().e7SetupTermuxOutdated;
        });
        return;
      }
      if (!capabilities.permissionGranted) {
        _set(() => _phase = TermuxHostPhase.needAllow);
        return;
      }
      try {
        await TermuxBridge.verifyBridge();
      } on TermuxBridgeException catch (error) {
        if (_disposed || epoch != _epoch) return;
        _set(() {
          _phase = TermuxHostPhase.needAllow;
          _error = error.code == 'command_timeout'
              ? copy().e7SetupTermuxNoAnswer
              : error.message;
        });
        return;
      }
      if (_disposed || epoch != _epoch) return;
      await _afterBridge();
    } on PlatformException catch (error) {
      if (_disposed || epoch != _epoch) return;
      _set(() {
        _phase = TermuxHostPhase.failed;
        _error = error.message ?? copy().e7SetupInspectTermuxFailed;
      });
    } catch (error) {
      // Anything else Termux answered with: said, never left spinning.
      if (_disposed || epoch != _epoch) return;
      _set(() {
        _phase = TermuxHostPhase.failed;
        _error = error.toString();
      });
    }
  }

  /// The bridge answers: what Termux already runs decides the next move.
  Future<void> _afterBridge() async {
    await _inspect();
    if (_disposed) return;
    final TermuxSetupSnapshot snapshot;
    try {
      snapshot = await TermuxBridge.setupSnapshot();
    } on TermuxBridgeException catch (error) {
      _set(() {
        _phase = TermuxHostPhase.failed;
        _error = error.message;
      });
      return;
    }
    if (_disposed) return;
    _status = snapshot.status;
    _output = snapshot.output;
    final status = snapshot.status;
    if (status.isRunning) {
      // A setup begun earlier (by this screen, the old wizard or a start
      // from the servers list) is still going: follow it.
      _jobStarted = true;
      _set(() => _phase = TermuxHostPhase.working);
      _startPolling();
      return;
    }
    if (status.switchPending && _job != TermuxHostJob.switchRuntime) {
      _set(() {
        _phase = TermuxHostPhase.failed;
        _error = status.isFailed
            ? _persistedFailure(status, snapshot.output)
            : copy().setupSwitchPending;
      });
      return;
    }
    final job = _job;
    if (job == null || _jobStarted) {
      _set(
        () => _phase = status.isReady
            ? TermuxHostPhase.ready
            : status.isFailed
            ? TermuxHostPhase.failed
            : TermuxHostPhase.idle,
      );
      if (status.isFailed) _error = _persistedFailure(status, snapshot.output);
      return;
    }
    if (status.isReady &&
        status.runtime == TermuxRuntime.openCode2 &&
        (job == TermuxHostJob.install || job == TermuxHostJob.switchRuntime)) {
      // OpenCode already runs in Termux: setting up is connecting.
      _jobStarted = true;
      await _finish();
      return;
    }
    await _startJob();
  }

  Future<void> _inspect() async {
    // An unreadable installation is not a fresh one. Let failure stop setup
    // before the new default can replace an unconfirmed runtime selection.
    final installation = await TermuxBridge.inspectInstallation();
    if (_disposed) return;
    _installation = installation;
    if (installation.openCodeVersion != null &&
        !(installation.runtime == TermuxRuntime.openCode2 &&
            localProfile(TermuxRuntime.openCode1) != null)) {
      await restoreProfileIfMissing(installation.runtime);
    }
  }

  // --- The person's steps --------------------------------------------------

  /// Asks Android for the command permission, puts the unlock line on the
  /// clipboard ([copyCommand]) and opens Termux, where the person pastes it.
  /// Coming back runs [verifyAfterReturn].
  Future<void> allowTermux(Future<void> Function(String) copyCommand) async {
    if (_busy) return;
    final l10n = copy();
    _set(() {
      _busy = true;
      _error = null;
      _openedTermux = false;
      _returnedFromTermux = false;
    });
    try {
      if (!await TermuxBridge.requestPermission()) {
        throw TermuxBridgeException(
          l10n.termuxPermissionDenied,
          code: 'permission_denied',
        );
      }
      await copyCommand(TermuxBridge.unlockCommand);
      _openedTermux = true;
      if (!await TermuxBridge.openTermux()) {
        throw TermuxBridgeException(l10n.termuxGuideOpenFailed);
      }
    } on TermuxBridgeException catch (error) {
      _openedTermux = false;
      _error = error.message;
    } on PlatformException catch (error) {
      _openedTermux = false;
      _error = error.message ?? l10n.termuxGuideCopyOpenFailed;
    } finally {
      _set(() => _busy = false);
    }
  }

  /// The person came back from Termux: check that the line took, and go on.
  Future<void> verifyAfterReturn() async {
    _set(() {
      _openedTermux = false;
      _returnedFromTermux = true;
    });
    await check();
  }

  // --- Jobs ----------------------------------------------------------------

  Future<void> _startJob() async {
    _jobStarted = true;
    if (runtime == TermuxRuntime.openCode1) {
      await _switch(TermuxRuntime.openCode2);
      return;
    }
    switch (_job!) {
      case TermuxHostJob.install:
        final installed = _installation?.openCodeVersion != null;
        if (installed && localProfile(_installation!.runtime) != null) {
          // Nothing to download: start what is there.
          await _start();
        } else {
          await _installAndServe();
        }
      case TermuxHostJob.update:
        await _installAndServe();
      case TermuxHostJob.switchRuntime:
        await _switch(_target ?? _otherRuntime(runtime));
      case TermuxHostJob.start:
        await _start();
    }
  }

  static TermuxRuntime _otherRuntime(TermuxRuntime runtime) =>
      TermuxRuntime.openCode2;

  void _beginOperation() {
    _stopPolling();
    _epoch++;
    _snapshotFailures = 0;
    _monitoringFailed = false;
    _phase = TermuxHostPhase.working;
    _status = null;
    _output = '';
    _error = null;
    _lastLaunchOutput = null;
  }

  Future<void> _suspendRecovery() async {
    for (final profile in store.profiles.where(
      (p) => TermuxBridge.managesServerUrl(p.baseUrl),
    )) {
      await ManagedServerRecovery.suspendForProfile(store.prefs, profile.id);
    }
  }

  Future<void> _installAndServe() async {
    final l10n = copy();
    final runtime = this.runtime;
    _operationID = null;
    var launchRequested = false;
    _set(() {
      _beginOperation();
      _busy = true;
      _launching = true;
    });
    try {
      await TermuxBridge.verifyBridge();
      final profile = await _ensureLocalProfile(runtime);
      if (_disposed) return;
      final command = TermuxBridge.installAndServeScript(
        port: port,
        password: profile.password,
        runtime: runtime,
      );
      await _suspendRecovery();
      if (_disposed) return;
      launchRequested = true;
      final launch = await TermuxBridge.run(command);
      if (_disposed) return;
      _lastLaunchOutput = [
        launch.stdout.trim(),
        launch.stderr.trim(),
      ].where((part) => part.isNotEmpty).join('\n');
      if (!TermuxBridge.isLaunchAcknowledged(launch.stdout)) {
        throw TermuxBridgeException(
          'Termux returned success without starting the setup manager.\n'
          '${_lastLaunchOutput?.isEmpty ?? true ? 'No launcher output was returned.' : _lastLaunchOutput}',
          code: 'invalid_launch_result',
        );
      }
      var initial = await TermuxBridge.status();
      for (
        var attempt = 0;
        attempt < 10 && initial.phase == 'idle' && !_disposed;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (_disposed) return;
        initial = await TermuxBridge.status();
      }
      if (_disposed) return;
      if (initial.phase == 'idle' ||
          initial.message.contains('manager is missing')) {
        throw TermuxBridgeException(
          'The setup manager disappeared immediately after launch.\n'
          'Launcher: $_lastLaunchOutput',
          code: 'manager_missing',
        );
      }
      _launching = false;
      _set(() => _status = initial);
      _startPolling();
      await _refreshStatus();
    } on TermuxBridgeException catch (error) {
      if (_disposed) return;
      _launching = false;
      if (launchRequested &&
          error.code == 'command_timeout' &&
          await _recoverAfterTimeout()) {
        return;
      }
      _set(() {
        _phase = error.code == 'permission_denied'
            ? TermuxHostPhase.needAllow
            : TermuxHostPhase.failed;
        _error = error.message;
      });
    } catch (error) {
      if (_disposed) return;
      _launching = false;
      _set(() {
        _phase = TermuxHostPhase.failed;
        _error = l10n.e7SetupStartFailed(error.toString());
      });
    } finally {
      _launching = false;
      if (!_disposed) {
        if (_phase != TermuxHostPhase.working) _stopPolling();
        _set(() => _busy = false);
      }
    }
  }

  Future<void> _start() async {
    final operation = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    _operationID = operation;
    _set(() {
      _beginOperation();
      _busy = true;
    });
    try {
      await _suspendRecovery();
      if (_disposed) return;
      await TermuxBridge.run(
        TermuxBridge.restartScript(port: port, operationID: operation),
        timeout: const Duration(seconds: 45),
      );
      if (_disposed) return;
      _startPolling();
      await _refreshStatus();
    } on TermuxBridgeException catch (error) {
      if (_disposed) return;
      if (error.code == 'command_timeout' && await _recoverAfterTimeout()) {
        return;
      }
      _set(() {
        _phase = TermuxHostPhase.failed;
        _error = copy().e7SetupRestartFailed(error.message);
      });
    } catch (_) {
      if (_disposed) return;
      _set(() {
        _phase = TermuxHostPhase.failed;
        _error = copy().e7SetupRestartFailed('');
      });
    } finally {
      if (!_disposed) {
        if (_phase != TermuxHostPhase.working) _stopPolling();
        _set(() => _busy = false);
      }
    }
  }

  Future<void> _switch(TermuxRuntime target) async {
    final l10n = copy();
    _set(() {
      _busy = true;
      _error = null;
    });
    try {
      await TermuxBridge.verifyBridge();
      // Refuse lost prior credentials: generating a replacement would make a
      // "return" silently change that runtime's authentication contract.
      final previous = _status?.switchPrevious ?? runtime;
      target.requireSupported();
      if (localProfile(previous) == null &&
          localProfile(TermuxRuntime.openCode1) == null) {
        throw StateError(l10n.setupSwitchMissingCredential);
      }
      await connection.prepareManagedRuntimeSwitch();
      final profile = await _ensureLocalProfile(target, forSwitch: true);
      await teamFollowsRuntime(
        store,
        profile,
        sameHost: (p) =>
            p.backend == ServerBackend.openCode &&
            TermuxBridge.managesServerUrl(p.baseUrl),
      );
      if (_disposed) return;
      final operation = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      _operationID = operation;
      _set(() {
        _beginOperation();
        _launching = true;
      });
      final result = await TermuxBridge.run(
        TermuxBridge.restartScript(
          operationID: operation,
          switchTarget: target,
          switchPassword: profile.password,
        ),
      );
      if (_disposed) return;
      if (!TermuxBridge.isLaunchAcknowledged(result.stdout)) {
        throw TermuxBridgeException(
          l10n.e7SetupSwitchNotStarted,
          code: 'invalid_launch_result',
        );
      }
      _launching = false;
      _startPolling();
      await _refreshStatus();
    } catch (error) {
      if (_disposed) return;
      _launching = false;
      _set(() {
        _phase = TermuxHostPhase.failed;
        _error = l10n.setupSwitchFailed;
        _lastLaunchOutput = KitRedact.text(error.toString());
      });
      // A native timeout may leave the manager alive: its journal answers.
      if (error is TermuxBridgeException && error.code == 'command_timeout') {
        _startPolling();
        await _refreshStatus();
      }
    } finally {
      _launching = false;
      if (!_disposed) _set(() => _busy = false);
    }
  }

  /// "Continue setup" after a failure: follow a setup the app lost track
  /// of, finish a half-done switch, connect again, or run the job again
  /// (the manager skips what is already installed).
  Future<void> retry() async {
    if (_busy) return;
    if (_monitoringFailed) {
      _set(() {
        _phase = TermuxHostPhase.working;
        _error = null;
        _monitoringFailed = false;
        _snapshotFailures = 0;
      });
      _startPolling();
      await _refreshStatus();
      return;
    }
    if (_status?.isReady == true && !(_status?.switchPending ?? false)) {
      await _finish();
      return;
    }
    if (_job == null) {
      await check();
      return;
    }
    if (_job == TermuxHostJob.switchRuntime) {
      await _switch(_target ?? _otherRuntime(runtime));
      return;
    }
    if (_phase == TermuxHostPhase.needAllow ||
        _phase == TermuxHostPhase.needTermux ||
        !_jobStarted) {
      await check();
      return;
    }
    _set(() => _busy = true);
    try {
      await _suspendRecovery();
      await TermuxBridge.run(TermuxBridge.stopScript(port: port));
    } on TermuxBridgeException catch (error) {
      _set(() {
        _busy = false;
        _error = error.message;
      });
      return;
    } catch (_) {
      _set(() {
        _busy = false;
        _error = copy().e7SetupRestartFailed('');
      });
      return;
    }
    _set(() => _busy = false);
    await _startJob();
  }

  // --- Following the manager -----------------------------------------------

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(pollInterval, (_) => unawaited(_refreshStatus()));
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  Future<void> _refreshStatus() async {
    if (_polling || _launching || _disposed) return;
    final epoch = _epoch;
    _polling = true;
    try {
      final snapshot = await TermuxBridge.setupSnapshot();
      if (_disposed || epoch != _epoch) return;
      final status = snapshot.status;
      final operation = _operationID;
      if (operation != null &&
          status.operationID != operation &&
          !status.isRunning) {
        // Another operation's answer, left from before this one began.
        _snapshotFailures++;
        if (_snapshotFailures < 10) {
          if (_poll == null) _startPolling();
          return;
        }
        _stopPolling();
        _set(() {
          _phase = TermuxHostPhase.failed;
          _error = _job == TermuxHostJob.switchRuntime
              ? copy().setupSwitchFailed
              : copy().e7SetupRestartUnconfirmed;
        });
        return;
      }
      _snapshotFailures = 0;
      _monitoringFailed = false;
      _status = status;
      _output = snapshot.output;
      if (status.isReady && status.version.isNotEmpty) {
        _installation = TermuxInstallation(
          ubuntuInstalled: true,
          openCodeVersion: status.version,
          runtime: status.runtime,
          runtimeSelected: true,
        );
      }
      if (status.isRunning) {
        _set(() => _phase = TermuxHostPhase.working);
        if (_poll == null) _startPolling();
        return;
      }
      _stopPolling();
      if (status.switchPending) {
        _set(() {
          _phase = TermuxHostPhase.failed;
          _error = status.isFailed
              ? _persistedFailure(status, snapshot.output)
              : copy().setupSwitchPending;
        });
        return;
      }
      if (status.isFailed) {
        _set(() {
          _monitoringFailed =
              status.message == 'Could not read setup manager status';
          _phase = TermuxHostPhase.failed;
          _error = _persistedFailure(status, snapshot.output);
        });
        return;
      }
      if (status.isReady) {
        _operationID = null;
        await _finish();
        return;
      }
      _set(() => _phase = TermuxHostPhase.idle);
    } on TermuxBridgeException catch (error) {
      if (_disposed || epoch != _epoch) return;
      _snapshotFailures++;
      final mayBeRunning =
          _phase == TermuxHostPhase.working || (_status?.isRunning ?? false);
      if (mayBeRunning && _snapshotFailures < 3) {
        if (_poll == null) _startPolling();
        return;
      }
      _stopPolling();
      _set(() {
        _monitoringFailed = mayBeRunning;
        _phase = TermuxHostPhase.failed;
        _error = mayBeRunning && _status != null
            ? _persistedFailure(_status!, _output, bridge: error.message)
            : error.message;
      });
    } finally {
      _polling = false;
    }
  }

  /// A launch that timed out may have started anyway: the manager's
  /// journal is the authority.
  Future<bool> _recoverAfterTimeout() async {
    try {
      final snapshot = await TermuxBridge.setupSnapshot();
      if (_disposed || snapshot.status.phase == 'idle') return false;
      _status = snapshot.status;
      _output = snapshot.output;
      if (snapshot.status.isRunning) {
        _set(() {
          _phase = TermuxHostPhase.working;
          _error = null;
        });
        _startPolling();
      } else if (snapshot.status.isFailed) {
        _set(() {
          _phase = TermuxHostPhase.failed;
          _error = _persistedFailure(snapshot.status, snapshot.output);
        });
      } else if (snapshot.status.isReady) {
        await _finish();
      } else {
        _set(() => _phase = TermuxHostPhase.idle);
      }
      return true;
    } on TermuxBridgeException {
      return false;
    }
  }

  String _persistedFailure(
    TermuxSetupStatus status,
    String output, {
    String? bridge,
  }) {
    final l10n = copy();
    final lines = output
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    String? cause;
    for (final line in lines.reversed) {
      if (line.contains('[oc] ERROR:') ||
          line.contains('CANNOT LINK EXECUTABLE') ||
          line.contains('cannot locate symbol') ||
          line.contains('SSL_') ||
          line.startsWith('E:')) {
        cause = line;
        break;
      }
    }
    cause ??= lines.isEmpty ? null : lines.last;
    return [
      status.message,
      if (cause != null && cause != status.message)
        l10n.e7SetupLastSetupDetail(cause),
      if (bridge != null) l10n.e7SetupBridgeDetail(bridge),
    ].join('\n');
  }

  // --- Connecting ----------------------------------------------------------

  /// OpenCode is ready in Termux: save what it reports and connect.
  Future<void> _finish() async {
    final l10n = copy();
    final status = _status;
    final runtime = status?.runtime ?? this.runtime;
    ServerProfile? upgradedProfile;
    if (status?.isReady == true && runtime == TermuxRuntime.openCode2) {
      final original = localProfile(TermuxRuntime.openCode1);
      if (original != null) {
        // A ready OC2 may have an independent history. Only the copy receipt
        // admission can adopt it as this legacy profile's upgrade.
        final admission = await TermuxBridge.setupRun(
          openCode1HistorySwitchCheckScript,
        );
        if (admission.exitCode != 0) {
          _set(() {
            _phase = TermuxHostPhase.failed;
            _error = l10n.setupSwitchFailed;
            _lastLaunchOutput = KitRedact.text(admission.failureMessage);
          });
          return;
        }
        // Native readiness proves the copy/start completed. Preserve every
        // local key by keeping the same ID; history still needs server proof.
        original
          ..requiresOpenCode2Migration = false
          ..openCode2HistoryPending = true
          ..flavor = ServerFlavor.v2;
        try {
          await store.upsert(original);
        } catch (_) {
          original
            ..requiresOpenCode2Migration = true
            ..openCode2HistoryPending = false;
          rethrow;
        }
        upgradedProfile = original;
      }
    }
    // The move belongs to this original identity. Another OC2 alias may
    // precede it in storage, but must never take its recovery or connection.
    final managedProfile = upgradedProfile ?? localProfile(runtime);
    if (status?.isReady == true && managedProfile != null) {
      await ManagedServerRecovery.resumeAfterManualStartForProfile(
        store.prefs,
        managedProfile.id,
      );
      if (_disposed) return;
    }
    if (!connectWhenReady) {
      _set(() => _phase = TermuxHostPhase.ready);
      return;
    }
    if (managedProfile == null) await restoreProfileIfMissing(runtime);
    final profile = managedProfile ?? localProfile(runtime);
    if (profile == null) {
      _set(() {
        _phase = TermuxHostPhase.failed;
        _error = l10n.e7SetupExistingMissingCredential;
      });
      return;
    }
    _set(() {
      _phase = TermuxHostPhase.connecting;
      _error = null;
    });
    final version = status?.version.trim() ?? '';
    if (version.isNotEmpty && profile.serverVersion != version) {
      final previous = profile.serverVersion;
      profile.serverVersion = version;
      try {
        await store.upsert(profile);
      } catch (_) {
        profile.serverVersion = previous;
      }
    }
    await connection.connect(profile);
    if (_disposed) return;
    if (!connection.hasConnectedServer) {
      _set(() {
        _phase = TermuxHostPhase.failed;
        _error = connection.lastError ?? l10n.e7SetupAuthFailed;
      });
      return;
    }
    _set(() => _phase = TermuxHostPhase.ready);
  }

  /// The failure report the person can copy: the launcher's answer, the
  /// failure as the app saw it, and Termux's own diagnostics.
  Future<String> failureReport() async {
    String diagnostics;
    try {
      diagnostics = await TermuxBridge.diagnostics();
    } on TermuxBridgeException catch (error) {
      diagnostics = copy().e7SetupDiagnosticsUnavailable(error.message);
    }
    return [
      if (_lastLaunchOutput?.isNotEmpty ?? false)
        '===== Last launcher result =====\n$_lastLaunchOutput',
      if (_error?.isNotEmpty ?? false) '===== Screen error =====\n$_error',
      diagnostics,
    ].join('\n');
  }
}

/// OpenCode is installed in Termux but the app holds no password for it (a
/// reinstall, cleared app data, an unreadable keystore). The app wrote that
/// password into Termux at setup, so it takes it back from there rather than
/// asking the person for a secret they were never shown. Saves the profile
/// of [runtime] under [name] when none exists. Returns whether a password
/// was restored.
Future<bool> restoreManagedTermuxProfile(
  ProfileStore store,
  TermuxRuntime runtime, {
  required String name,
}) async {
  ServerProfile? existing;
  for (final profile in store.profiles) {
    if (profile.backend != ServerBackend.openCode ||
        profile.baseUrl != TermuxBridge.managedServerUrl ||
        ManagedRuntimeFlavor.runtimeOf(profile) != runtime) {
      continue;
    }
    if (profile.password.isNotEmpty) return false;
    existing = profile;
    break;
  }
  final password = await TermuxBridge.managedServerPassword();
  if (password == null) return false;
  final profile =
      existing ??
      ServerProfile(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name,
        baseUrl: TermuxBridge.managedServerUrl,
        flavor: ManagedRuntimeFlavor.flavorOf(runtime),
        requiresOpenCode2Migration: runtime == TermuxRuntime.openCode1,
      );
  profile
    ..username = 'opencode'
    ..password = password
    ..requiresPasswordReentry = false;
  await store.upsert(profile);
  return true;
}

/// The two OpenCode generations as the Termux manager names them, mapped
/// onto a saved profile. Kept here so no screen compares flavours.
abstract final class ManagedRuntimeFlavor {
  static TermuxRuntime runtimeOf(ServerProfile profile) =>
      !profile.requiresOpenCode2Migration
      ? TermuxRuntime.openCode2
      : TermuxRuntime.openCode1;

  static ServerFlavor flavorOf(TermuxRuntime runtime) => ServerFlavor.v2;
}
