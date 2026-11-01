import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../platform/platform_capabilities.dart';
import '../../state/local_agent_server.dart';
import '../../state/profiles.dart';
import '../../termux/bridge.dart';
import '../../termux/local_agent_runtime.dart';
import '../app_theme.dart';
import '../kit/kit.dart';
import 'local_agent_onboarding.dart';
import 'local_server_row.dart';
import 'product_states.dart' show productErrorText;
import 'safety_confirms.dart';

enum _Operation { starting, restarting, stopping, removing, signingIn }

/// Claude Code on this phone, on the Servers screen and in the server
/// switcher, controlled where it is shown.
///
/// It sits beside the OpenCode server's row and looks the same
/// ([LocalServerRow], kit rows only), but its state is the daemon's:
/// `claude.sh status` read on mount, on app resume, whenever [revision]
/// changes and after every control. Installing and choosing a project folder
/// stay in the setup wizard (Details); the row appears once there is
/// something installed to control, or a saved server for it (the saved
/// server is this row, never a second one on the list).
///
/// States (map: embedded-local-agent-server-entry, proposal fix): running,
/// stopped, menu open, connected; signed out of Claude (the line says so and
/// the menu offers Sign in to Claude); starting for longer than 8 s ("Still
/// starting", KitSince); failed to start ("Didn't start" with the reason,
/// and a tap starts it again); Termux not answering (a saved server stays as
/// "Not answering" with Try again in the menu). The menu also offers Update
/// when this build pins a newer Paseo (it opens the page where updating
/// shows its progress) and Remove from this phone, confirmed first.
class LocalAgentServerEntry extends StatefulWidget {
  const LocalAgentServerEntry({
    super.key,
    required this.profiles,
    required this.busy,
    required this.revision,
    required this.onConnect,
    this.connectedProfileID,
    this.busyConversations = 0,
    this.onDisconnect,
    this.onForget,
    this.onManage,
    this.onOpenSaved,
    this.dividerAbove = false,
    this.runtime,
  });

  final List<ServerProfile> profiles;

  /// Shown in a list after other rows: the hairline above this row.
  final bool dividerAbove;

  /// True while the host screen runs its own server operation.
  final bool busy;

  /// Bumped by the host when something may have changed the daemon.
  final int revision;

  /// The profile the app is connected through right now, if any.
  final String? connectedProfileID;

  /// Connects through (or reopens) the saved server for the daemon.
  final ValueChanged<ServerProfile> onConnect;

  /// Running conversations a restart or stop would interrupt.
  final int busyConversations;

  final Future<void> Function()? onDisconnect;

  /// Forgets the saved server on this device; the daemon itself is untouched.
  final ValueChanged<ServerProfile>? onForget;

  /// Opens the setup wizard, where install, update and the project folder
  /// live. Also where Connect goes when no server is saved yet.
  final VoidCallback? onManage;

  /// Opens the saved server the ordinary way while the phone cannot say
  /// whether it runs (no access, no answer, still checking): connecting may
  /// still work, and a choice between OpenCode versions goes to setup. Null
  /// opens [onManage] instead.
  final ValueChanged<ServerProfile>? onOpenSaved;

  final LocalAgentRuntime? runtime;

  @override
  State<LocalAgentServerEntry> createState() => _LocalAgentServerEntryState();
}

class _LocalAgentServerEntryState extends State<LocalAgentServerEntry>
    with WidgetsBindingObserver {
  LocalAgentRuntime get _runtime => widget.runtime ?? localAgentRuntime;

  LocalAgentStatus? _status;
  bool _checking = false;
  bool _recheckQueued = false;
  int _epoch = 0;
  _Operation? _operation;

  /// When [_operation] began, for "Still starting" after 8 s (STATE-5).
  DateTime? _operationSince;
  String? _failure;

  /// The last Start or Restart ended in a failure: the row says it did not
  /// start rather than only "Stopped".
  bool _startFailed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_check());
  }

  @override
  void didUpdateWidget(LocalAgentServerEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) unawaited(_check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Also how a sign-in in Termux shows up: the person comes back here.
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _epoch++;
    super.dispose();
  }

  bool get _locked => widget.busy || _checking || _operation != null;

  Future<LocalAgentStatus?> _read() async {
    try {
      return await _runtime.status();
    } on LocalAgentFailure {
      // No Termux, no permission: there is nothing of ours to show.
      return null;
    }
  }

  Future<void> _check() async {
    if (!platformCapabilities.supportsTermux) return;
    if (_checking) {
      _recheckQueued = true;
      return;
    }
    final epoch = ++_epoch;
    setState(() => _checking = true);
    final status = await _read();
    if (!mounted || epoch != _epoch) return;
    setState(() {
      _status = status;
      _checking = false;
      if (status != null && status.isReady) _startFailed = false;
    });
    if (_recheckQueued) {
      _recheckQueued = false;
      unawaited(_check());
    }
  }

  /// Connect acts on a fresh look: Android stops Termux without telling
  /// anyone, and the card may have been on screen for minutes.
  Future<void> _connect() async {
    if (_locked) return;
    setState(() {
      _checking = true;
      _failure = null;
    });
    final status = await _read();
    if (!mounted) return;
    setState(() {
      _status = status;
      _checking = false;
    });
    if (status == null || !status.isReady) return;
    final saved = savedLocalAgentProfile(
      widget.profiles,
      preferID: widget.connectedProfileID,
    );
    if (saved == null || saved.codexDirectory.trim().isEmpty) {
      // No project folder chosen yet: that step lives in the wizard.
      widget.onManage?.call();
      return;
    }
    widget.onConnect(saved);
  }

  Future<void> _run(
    _Operation operation,
    Future<void> Function() action,
  ) async {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    setState(() {
      _operation = operation;
      _operationSince = clock.now();
      _failure = null;
    });
    var failed = false;
    try {
      await action();
    } on LocalAgentFailure catch (failure) {
      failed = true;
      if (mounted) {
        setState(
          () => _failure = l10n.localAgentCardActionFailed(
            localAgentFailureText(l10n, failure.kind, failure.message),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _operation = null;
          _operationSince = null;
          if (operation == _Operation.starting ||
              operation == _Operation.restarting) {
            _startFailed = failed;
          }
        });
        unawaited(_check());
      }
    }
  }

  Future<void> _start() async {
    if (_locked) return;
    await _run(_Operation.starting, _runtime.start);
  }

  Future<void> _restart() async {
    if (_locked) return;
    final confirmed = await confirmRestartLocalAgents(
      context,
      busyConversations: widget.busyConversations,
    );
    if (!confirmed || !mounted || _locked) return;
    await _run(_Operation.restarting, _runtime.restart);
  }

  Future<void> _stop() async {
    if (_locked) return;
    if (!await confirmStopLocalAgents(context)) return;
    if (!mounted || _locked) return;
    await _run(_Operation.stopping, _runtime.stop);
  }

  /// Removes Node, Paseo and Claude Code; the sign-in and projects stay
  /// (the confirmation says so). The saved server stays until forgotten.
  Future<void> _remove() async {
    if (_locked) return;
    if (!await confirmRemoveLocalAgents(context)) return;
    if (!mounted || _locked) return;
    await _run(_Operation.removing, _runtime.remove);
  }

  /// Opens Claude's own sign-in in Termux; the app never sees the
  /// credential. Coming back to the app reads the status again.
  Future<void> _signIn() async {
    if (_locked) return;
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    setState(() {
      _operation = _Operation.signingIn;
      _operationSince = null;
      _failure = null;
    });
    String? problem;
    var opened = false;
    try {
      opened = await _runtime.openSignIn();
    } on LocalAgentFailure catch (failure) {
      problem = productErrorText(failure, l10n: l10n);
    }
    if (!mounted) return;
    setState(() {
      _operation = null;
      if (!opened) {
        _failure =
            problem ??
            l10n.localAgentSignInOpenFailed(
              TermuxBridge.localAgentsSignInCommand,
            );
      }
    });
  }

  /// Whether this build pins a newer Paseo than the one installed: a new
  /// Claude model arrives with an update (local_agent_onboarding.dart).
  static bool _updateAvailable(LocalAgentStatus status) {
    final installed = status.paseoVersion;
    final pinned = TermuxBridge.localAgentsPins['paseo_version'];
    return status.installed &&
        installed.isNotEmpty &&
        pinned != null &&
        installed != pinned;
  }

  @override
  Widget build(BuildContext context) {
    if (!platformCapabilities.supportsTermux) return const SizedBox.shrink();
    final status = _status;
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final profile = savedLocalAgentProfile(
      widget.profiles,
      preferID: widget.connectedProfileID,
    );
    // Nothing installed is the wizard's business, not a server to control;
    // but a saved server stays on the list as this one row.
    if (status == null || !status.installed) {
      if (profile == null) return const SizedBox.shrink();
      return LocalServerRow(
        dividerAbove: widget.dividerAbove,
        tapOpensPage: widget.onOpenSaved != null,
        keyPrefix: 'local-agent-server',
        mark: AppIconography.agent,
        title: l10n.localAgentTitle,
        status: status == null
            ? (_checking
                  ? l10n.phoneServerCardChecking
                  : l10n.phoneServerRowNotAnswering)
            : l10n.phoneServerRowNotRunning,
        connectedLabel: l10n.serverRowConnected,
        stopped: false,
        running: false,
        locked: false,
        inProgress: _checking,
        connected: false,
        failure: _failure,
        menuTooltip: l10n.localAgentMore,
        menuItems: [
          LocalServerRowMenuItem(
            keySuffix: 'recheck',
            label: l10n.commonRetry,
            onSelected: () => unawaited(_check()),
          ),
          if (widget.onManage != null)
            LocalServerRowMenuItem(
              keySuffix: 'manage',
              label: l10n.phoneServerRowDetails,
              onSelected: widget.onManage!,
            ),
          if (widget.onForget != null)
            LocalServerRowMenuItem(
              keySuffix: 'forget',
              label: l10n.phoneServerForget,
              onSelected: () => widget.onForget!(profile),
            ),
        ],
        startLabel: l10n.localAgentStartNamed,
        restartLabel: l10n.termuxRestartConfirm,
        stopLabel: l10n.localAgentStopNamed,
        onOpen: widget.onOpenSaved != null
            ? () => widget.onOpenSaved!(profile)
            : widget.onManage ?? () => unawaited(_check()),
      );
    }
    final running = status.isReady;
    final connected =
        running && profile != null && profile.id == widget.connectedProfileID;
    final failedToStart =
        !running &&
        _operation == null &&
        (_startFailed || status.phase == LocalAgentPhase.failed);
    final signedOut = status.signedIn == LocalAgentSignIn.no;
    final failure =
        _failure ??
        (status.phase == LocalAgentPhase.failed
            ? localAgentFailureText(
                l10n,
                status.failureKind ?? LocalAgentFailureKind.other,
                status.message,
              )
            : status.killedByAndroid
            ? l10n.localAgentKilled
            : null);

    return KitSince(
      since: _operationSince,
      builder: (context, wait) {
        final starting =
            _operation == _Operation.starting ||
            _operation == _Operation.restarting;
        final state = switch (_operation) {
          _ when starting && wait.isSlow => l10n.localAgentEntryStillStarting,
          _Operation.starting => l10n.phoneServerCardStarting,
          _Operation.restarting => l10n.phoneServerRowRestarting,
          _Operation.stopping => l10n.phoneServerCardStopping,
          _Operation.removing => l10n.localAgentEntryRemoving,
          _Operation.signingIn ||
          null when running => l10n.phoneServerCardRunning,
          _Operation.signingIn ||
          null when status.busy => l10n.phoneServerCardSettingUp,
          _Operation.signingIn ||
          null when failedToStart => l10n.localAgentEntryDidNotStart,
          _Operation.signingIn || null => l10n.phoneServerCardStopped,
        };
        return LocalServerRow(
          dividerAbove: widget.dividerAbove,
          keyPrefix: 'local-agent-server',
          mark: AppIconography.agent,
          title: l10n.localAgentTitle,
          status: signedOut ? l10n.localAgentEntrySignedOut(state) : state,
          connectedLabel: l10n.serverRowConnected,
          stopped: !running,
          locked: _locked || status.busy,
          inProgress: _operation != null || status.busy,
          connected: connected,
          failure: failure,
          menuTooltip: l10n.localAgentMore,
          menuItems: [
            if (signedOut)
              LocalServerRowMenuItem(
                keySuffix: 'sign-in',
                label: l10n.localAgentStepSignIn,
                onSelected: () => unawaited(_signIn()),
              ),
            if (_updateAvailable(status) && widget.onManage != null)
              LocalServerRowMenuItem(
                keySuffix: 'update',
                label: l10n.localAgentUpdate,
                onSelected: widget.onManage!,
              ),
            if (widget.onManage != null)
              LocalServerRowMenuItem(
                keySuffix: 'manage',
                label: l10n.phoneServerRowDetails,
                onSelected: widget.onManage!,
              ),
            if (connected && widget.onDisconnect != null)
              LocalServerRowMenuItem(
                keySuffix: 'disconnect',
                label: l10n.e7WorkspaceDisconnect,
                onSelected: () => unawaited(widget.onDisconnect!()),
              ),
            if (profile != null && widget.onForget != null)
              LocalServerRowMenuItem(
                keySuffix: 'forget',
                label: l10n.phoneServerForget,
                onSelected: () => widget.onForget!(profile),
              ),
            LocalServerRowMenuItem(
              keySuffix: 'remove',
              label: l10n.localAgentRemove,
              onSelected: () => unawaited(_remove()),
            ),
          ],
          startLabel: l10n.localAgentStartNamed,
          restartLabel: l10n.termuxRestartConfirm,
          stopLabel: l10n.localAgentStopNamed,
          onStart: () => unawaited(_start()),
          onConnect: () => unawaited(_connect()),
          tapOpensPage: widget.onOpenSaved != null,
          connectLabel: l10n.settingsV3ConnectTo(l10n.localAgentTitle),
          onRestart: () => unawaited(_restart()),
          onStop: () => unawaited(_stop()),
          onOpen: profile != null && widget.onOpenSaved != null
              ? () => widget.onOpenSaved!(profile)
              : widget.onManage,
        );
      },
    );
  }
}
