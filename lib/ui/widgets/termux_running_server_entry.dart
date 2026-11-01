import 'dart:async';

import 'package:flutter/material.dart';

import '../../builtin/builtin_server.dart' show looksLikeInAppServer;
import '../../l10n/app_localizations.dart';
import '../../platform/platform_capabilities.dart';
import '../../state/local_agent_server.dart';
import '../../state/local_server_controls.dart';
import '../../state/profiles.dart';
import '../../state/termux_running_server.dart';
import '../../termux/bridge.dart';
import '../../termux/termux_reach.dart';
import '../kit/kit.dart';
import 'local_server_row.dart';
import 'product_states.dart' show productErrorText;
import 'safety_confirms.dart';
import 'termux_problem_fix.dart';

/// What the card can do to the phone's server, injected so the card stays a
/// widget and tests can stand in for Termux.
class LocalServerCardActions {
  const LocalServerCardActions({required this.restart, required this.stop});

  /// Starts a stopped server or restarts a running one; completes when ready.
  final Future<void> Function() restart;
  final Future<void> Function() stop;
}

enum _Operation { starting, restarting, stopping }

/// The server on this phone, first on the Servers screen and controlled in
/// place: one "This phone" row (docs/design/phone-server-screens-cleanup-
/// 2026-09-24.md §1).
///
/// A server the app itself set up is the closest thing to "your server" a
/// phone-first person has, so it leads the list. Tapping the row connects
/// (or starts a stopped server); Restart, Stop, Details (the setup screen),
/// Disconnect and forgetting the saved sign-in are in its menu. The saved
/// sign-in is this row: the list does not show it a second time.
///
/// The observation is read on mount, on app resume, whenever [revision]
/// changes, and after every control.
class TermuxRunningServerEntry extends StatefulWidget {
  const TermuxRunningServerEntry({
    super.key,
    required this.profiles,
    required this.busy,
    required this.revision,
    required this.onConnect,
    required this.onEnterCredentials,
    this.connectedProfileID,
    this.actions,
    this.busyConversations = 0,
    this.onDisconnect,
    this.onForget,
    this.onManage,
    this.onOpenSaved,
    this.dividerAbove = false,
    this.lead = false,
    this.onObserved,
  });

  /// The first screen with nothing saved: what the phone has leads the
  /// page as a heading, one line and one primary act, in place of a row.
  final bool lead;

  /// Each finished look at the phone, so a host can arrange itself around
  /// what was found (the first screen drops its welcome when Termux is).
  final ValueChanged<TermuxRunningServer>? onObserved;

  final List<ServerProfile> profiles;

  /// Shown in a list after other rows: the hairline above this row.
  final bool dividerAbove;

  /// True while the host screen runs its own server operation.
  final bool busy;

  /// Bumped by the host when something may have changed the phone's server.
  final int revision;

  /// The profile the app is connected through right now, if any.
  final String? connectedProfileID;

  final ValueChanged<ServerProfile> onConnect;

  final void Function(TermuxRunningServer, ServerProfile?) onEnterCredentials;

  /// Null hides Start, Restart and Stop (a host that cannot control Termux).
  final LocalServerCardActions? actions;

  /// Running conversations a restart or stop would interrupt.
  final int busyConversations;

  /// Leaves the connection and keeps the server running.
  final Future<void> Function()? onDisconnect;

  /// Forgets the saved server on this device; the server itself is untouched.
  final ValueChanged<ServerProfile>? onForget;

  /// Opens the setup wizard.
  final VoidCallback? onManage;

  /// Opens the saved server the ordinary way while the phone cannot say
  /// whether it runs (no access, no answer, still checking): connecting may
  /// still work, and a choice between OpenCode versions goes to setup. Null
  /// opens [onManage] instead.
  final ValueChanged<ServerProfile>? onOpenSaved;

  @override
  State<TermuxRunningServerEntry> createState() =>
      _TermuxRunningServerEntryState();
}

class _TermuxRunningServerEntryState extends State<TermuxRunningServerEntry>
    with WidgetsBindingObserver {
  TermuxRunningServer? _server;
  bool _checking = false;
  bool _recheckQueued = false;
  int _epoch = 0;
  TermuxDiscoveryCancellation? _observation;
  _Operation? _operation;
  String? _failure;

  /// A fix was made (access asked, Termux opened, a line to paste): the
  /// next look that finds OpenCode running connects without another tap.
  bool _connectWhenRunning = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_check());
  }

  @override
  void didUpdateWidget(TermuxRunningServerEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) unawaited(_check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _epoch++;
    _observation?.cancel();
    super.dispose();
  }

  bool get _locked => widget.busy || _checking || _operation != null;

  Future<void> _check() async {
    if (!platformCapabilities.supportsTermux) {
      if (_server != null && mounted) setState(() => _server = null);
      return;
    }
    if (_checking) {
      _recheckQueued = true;
      return;
    }
    final epoch = ++_epoch;
    setState(() => _checking = true);
    final observation = TermuxDiscoveryCancellation();
    _observation = observation;
    final result = await detectTermuxRunningServer(
      profiles: widget.profiles,
      cancellation: observation,
    );
    if (!mounted || epoch != _epoch) return;
    setState(() {
      _server = result;
      _checking = false;
    });
    widget.onObserved?.call(result);
    if (_recheckQueued) {
      _recheckQueued = false;
      unawaited(_check());
      return;
    }
    if (_connectWhenRunning && result.problem == null) {
      _connectWhenRunning = false;
      if (result.isRunning) _open(result);
    }
  }

  /// Opens the running [server]: the saved sign-in, or the app's own
  /// password taken back from the phone.
  void _open(TermuxRunningServer server) {
    final saved = savedProfileForTermuxServer(widget.profiles, server);
    if (saved == null ||
        server.needsCredentials ||
        saved.requiresPasswordReentry) {
      widget.onEnterCredentials(server, saved);
    } else {
      widget.onConnect(saved);
    }
  }

  /// The one act that fixes [problem]; when it could be done in the app,
  /// the phone is read again at once, else when the person comes back.
  Future<void> _fix(TermuxProblem problem) async {
    if (_locked) return;
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final actions = widget.actions;
    _connectWhenRunning = true;
    final again = await fixTermuxProblem(
      context,
      problem,
      restart: actions == null
          ? null
          : () => _run(
              _Operation.restarting,
              actions.restart,
              l10n.phoneServerRestartFailed,
            ),
      retry: _check,
    );
    if (!mounted) return;
    if (again && problem != TermuxProblem.notAnswering) {
      await _check();
    }
  }

  /// Connect always acts on a fresh look: the card may have been on screen
  /// for minutes, and Android stops Termux without telling anyone.
  Future<void> _connect() async {
    if (_locked) return;
    setState(() {
      _checking = true;
      _failure = null;
    });
    final observation = TermuxDiscoveryCancellation();
    _observation = observation;
    final fresh = await detectTermuxRunningServer(
      profiles: widget.profiles,
      cancellation: observation,
    );
    if (!mounted) return;
    setState(() {
      _server = fresh;
      _checking = false;
    });
    if (_recheckQueued) {
      _recheckQueued = false;
      unawaited(_check());
      return;
    }
    widget.onObserved?.call(fresh);
    if (!fresh.isRunning) return;
    _open(fresh);
  }

  Future<void> _run(
    _Operation operation,
    Future<void> Function() action,
    String fallbackFailure,
  ) async {
    setState(() {
      _operation = operation;
      _failure = null;
    });
    try {
      await action();
    } on LocalServerControlFailure catch (error) {
      if (mounted) {
        setState(
          () => _failure = error.message.trim().isEmpty
              ? fallbackFailure
              : productErrorText(error),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _failure = fallbackFailure);
    } finally {
      if (mounted) {
        setState(() => _operation = null);
        unawaited(_check());
      }
    }
  }

  Future<void> _start(AppLocalizations l10n) async {
    final actions = widget.actions;
    if (_locked || actions == null) return;
    await _run(
      _Operation.starting,
      actions.restart,
      l10n.phoneServerStartFailed,
    );
  }

  Future<void> _restart(AppLocalizations l10n) async {
    final actions = widget.actions;
    if (_locked || actions == null) return;
    final confirmed = await confirmRestartLocalServer(
      context,
      busyConversations: widget.busyConversations,
    );
    if (!confirmed || !mounted || _locked) return;
    await _run(
      _Operation.restarting,
      actions.restart,
      l10n.phoneServerRestartFailed,
    );
  }

  Future<void> _stop(AppLocalizations l10n) async {
    final actions = widget.actions;
    if (_locked || actions == null) return;
    if (!await confirmStopLocalServer(context)) return;
    if (!mounted || _locked) return;
    await _run(_Operation.stopping, actions.stop, l10n.phoneServerStopFailed);
  }

  String _runtimeName(AppLocalizations l10n, TermuxRuntime? runtime) =>
      l10n.setupRuntimeTwo;

  @override
  Widget build(BuildContext context) {
    if (!platformCapabilities.supportsTermux) return const SizedBox.shrink();
    final server = _server;
    final saved = savedManagedPhoneProfile(widget.profiles);
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    // The saved sign-in for the phone's server is this row: the list shows
    // no second row for it. So a saved server stays on the list while the
    // phone is checked, and when Termux cannot say whether it runs.
    final problem = server?.problem;
    if (server == null ||
        server.state == TermuxRunningServerState.unsupported ||
        server.state == TermuxRunningServerState.absent) {
      if (saved == null) return const SizedBox.shrink();
      // Termux itself is gone: said, with the way to get it back.
      if (problem != null && !_checking && !widget.lead) {
        return _problemRow(l10n, saved, server!, problem);
      }
      return _unknownRow(
        l10n,
        saved,
        server == null || _checking
            ? l10n.phoneServerCardChecking
            : l10n.phoneServerRowNotRunning,
      );
    }
    if (!server.isRunning && !server.isStopped) {
      final cause = problem ?? TermuxProblem.unknown;
      if (widget.lead) return _lead(l10n, server, cause);
      return _problemRow(l10n, saved, server, cause);
    }
    if (widget.lead) return _lead(l10n, server, null);

    final profile = savedProfileForTermuxServer(widget.profiles, server);
    final connected =
        server.isRunning &&
        profile != null &&
        profile.id == widget.connectedProfileID;
    final runtime = _runtimeName(l10n, server.runtime);
    final state = switch (_operation) {
      _Operation.starting => l10n.phoneServerCardStarting,
      _Operation.restarting => l10n.phoneServerRowRestarting,
      _Operation.stopping => l10n.phoneServerCardStopping,
      null when server.isStopped => l10n.phoneServerCardStopped,
      null => l10n.phoneServerCardRunning,
    };
    final actions = widget.actions;

    // The look is shared with the Claude Code daemon's row; what this entry
    // owns is the OpenCode server's state and what its controls do.
    return LocalServerRow(
      dividerAbove: widget.dividerAbove,
      keyPrefix: 'termux-running-server',
      title: l10n.phoneServerTermuxTitle,
      status: l10n.phoneServerRowStatus(runtime, state),
      connectedLabel: l10n.serverRowConnected,
      stopped: server.isStopped,
      locked: _locked,
      inProgress: _operation != null,
      connected: connected,
      failure: _failure,
      menuTooltip: l10n.phoneServerMore,
      menuItems: [
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
      ],
      startLabel: l10n.phoneServerStart,
      restartLabel: l10n.termuxRestartConfirm,
      stopLabel: l10n.phoneServerStop,
      onStart: actions == null ? null : () => unawaited(_start(l10n)),
      onConnect: () => unawaited(_connect()),
      tapOpensPage: widget.onOpenSaved != null,
      connectLabel: l10n.settingsV3ConnectTo(l10n.phoneServerTermuxTitle),
      onRestart: actions == null ? null : () => unawaited(_restart(l10n)),
      onStop: actions == null ? null : () => unawaited(_stop(l10n)),
      onOpen: profile != null && widget.onOpenSaved != null
          ? () => widget.onOpenSaved!(profile)
          : widget.onManage,
    );
  }

  /// The words of [problem] for [server].
  TermuxProblemWords _words(
    AppLocalizations l10n,
    TermuxRunningServer server,
    TermuxProblem problem,
  ) => termuxProblemWords(
    l10n,
    problem,
    heard: server.heardOnPhone,
    runtime: server.runtime == null ? null : _runtimeName(l10n, server.runtime),
  );

  /// The phone's server when something keeps the app from it: the cause
  /// in plain words after the one "Needs you", and the one act that fixes
  /// it (the row's tap does the same). "Try again" only where it can help.
  Widget _problemRow(
    AppLocalizations l10n,
    ServerProfile? saved,
    TermuxRunningServer server,
    TermuxProblem problem,
  ) {
    final words = _words(l10n, server, problem);
    return LocalServerRow(
      dividerAbove: widget.dividerAbove,
      tapOpensPage: widget.onOpenSaved != null,
      keyPrefix: 'termux-running-server',
      title: l10n.phoneServerTermuxTitle,
      status: words.line,
      needsYou: true,
      fixLabel: words.action,
      onFix: () => unawaited(_fix(problem)),
      // Not knowing why is not knowing it is down: the saved server may
      // still connect, so the row opens it and the fix is the button.
      onOpen:
          problem == TermuxProblem.unknown &&
              saved != null &&
              widget.onOpenSaved != null
          ? () => widget.onOpenSaved!(saved)
          : null,
      connectedLabel: l10n.serverRowConnected,
      stopped: false,
      running: false,
      locked: _locked,
      inProgress: _checking || _operation != null,
      connected: false,
      failure: _failure,
      menuTooltip: l10n.phoneServerMore,
      menuItems: [
        if (widget.onManage != null)
          LocalServerRowMenuItem(
            keySuffix: 'manage',
            label: l10n.phoneServerRowDetails,
            onSelected: widget.onManage!,
          ),
        if (saved != null && widget.onForget != null)
          LocalServerRowMenuItem(
            keySuffix: 'forget',
            label: l10n.phoneServerForget,
            onSelected: () => widget.onForget!(saved),
          ),
      ],
      startLabel: l10n.phoneServerStart,
      restartLabel: l10n.termuxRestartConfirm,
      stopLabel: l10n.phoneServerStop,
    );
  }

  /// The first screen with nothing saved and something found in Termux:
  /// what was found as the heading, one line, and the one act.
  Widget _lead(
    AppLocalizations l10n,
    TermuxRunningServer server,
    TermuxProblem? problem,
  ) {
    final tokens = KitTokens.of(context);
    final String heading;
    final String line;
    final KitAction action;
    final working = _locked;
    if (problem != null) {
      final words = _words(l10n, server, problem);
      heading = server.heardOnPhone
          ? l10n.termuxLeadRunning
          : problem == TermuxProblem.notAnswering
          ? l10n.termuxLeadSetUp
          : l10n.termuxLeadTermuxOnly;
      // The heading already says OpenCode runs: the line does not repeat it.
      line =
          server.heardOnPhone &&
              (problem == TermuxProblem.accessNeeded ||
                  problem == TermuxProblem.accessBlocked)
          ? (problem == TermuxProblem.accessNeeded
                ? l10n.termuxLeadAccessLine
                : words.line)
          : words.line;
      action = KitAction(
        key: const ValueKey('termux-lead-fix'),
        label: words.action,
        working: working,
        onPressed: working ? null : () => unawaited(_fix(problem)),
      );
    } else if (server.isStopped) {
      heading = l10n.termuxLeadSetUp;
      line = l10n.termuxLeadStoppedBody;
      action = KitAction(
        key: const ValueKey('termux-lead-start'),
        label: l10n.termuxLeadStart,
        working: working,
        onPressed: working || widget.actions == null
            ? null
            : () => unawaited(_start(l10n)),
      );
    } else {
      heading = l10n.termuxLeadRunning;
      line = l10n.termuxLeadRunningBody;
      action = KitAction(
        key: const ValueKey('termux-lead-connect'),
        label: l10n.termuxLeadConnect,
        working: working,
        onPressed: working ? null : () => unawaited(_connect()),
      );
    }
    final failure = _failure;
    return Padding(
      key: const ValueKey('termux-lead'),
      padding: EdgeInsetsDirectional.symmetric(horizontal: tokens.gutter),
      child: Semantics(
        container: true,
        liveRegion: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              header: true,
              child: KitText(
                heading,
                key: const ValueKey('termux-lead-heading'),
                role: KitTextRole.largeTitle,
              ),
            ),
            SizedBox(height: tokens.space2),
            KitText(
              line,
              key: const ValueKey('termux-lead-line'),
              tone: KitTextTone.secondary,
            ),
            if (failure != null) ...[
              SizedBox(height: tokens.space2),
              KitText(failure, role: KitTextRole.secondary),
            ],
            SizedBox(height: tokens.space4),
            KitActionBlock(primary: action),
          ],
        ),
      ),
    );
  }

  /// The phone's server when Termux cannot say whether it runs: still
  /// checking, no access, no answer, or not set up there. Tapping opens its
  /// details (phone setup), where each of those is fixed; the menu checks
  /// again or forgets the saved sign-in.
  Widget _unknownRow(
    AppLocalizations l10n,
    ServerProfile? saved,
    String state,
  ) => LocalServerRow(
    dividerAbove: widget.dividerAbove,
    tapOpensPage: widget.onOpenSaved != null,
    keyPrefix: 'termux-running-server',
    title: l10n.phoneServerTermuxTitle,
    status: state,
    connectedLabel: l10n.serverRowConnected,
    stopped: false,
    running: false,
    locked: false,
    inProgress: _checking,
    connected: false,
    menuTooltip: l10n.phoneServerMore,
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
      if (saved != null && widget.onForget != null)
        LocalServerRowMenuItem(
          keySuffix: 'forget',
          label: l10n.phoneServerForget,
          onSelected: () => widget.onForget!(saved),
        ),
    ],
    startLabel: l10n.phoneServerStart,
    restartLabel: l10n.termuxRestartConfirm,
    stopLabel: l10n.phoneServerStop,
    onOpen: saved != null && widget.onOpenSaved != null
        ? () => widget.onOpenSaved!(saved)
        : widget.onManage ?? () => unawaited(_check()),
  );
}

/// The saved server the phone's own OpenCode (in Termux) is reached
/// through, whichever OpenCode version it was saved for: the Servers list
/// shows it as the one "This phone" row, never as a second saved row.
ServerProfile? savedManagedPhoneProfile(Iterable<ServerProfile> profiles) {
  for (final profile in profiles) {
    if (isManagedPhoneProfile(profile)) return profile;
  }
  return null;
}

/// Whether [profile] is shown as one of the phone's own server rows ("This
/// phone", or Claude Code on this phone) rather than as a saved server of
/// its own: the Servers list and the server switcher never list it twice.
/// Those rows always draw themselves when a saved sign-in exists.
///
/// Only one saved server per Claude Code endpoint is folded in: given
/// [among] (all saved servers) and [preferID] (the connected one), any other
/// profile at the same endpoint stays a normal row, so it can be opened or
/// forgotten.
bool shownAsPhoneRow(
  ServerProfile profile, {
  Iterable<ServerProfile>? among,
  String? preferID,
}) {
  if (!platformCapabilities.supportsTermux) return false;
  if (isManagedPhoneProfile(profile)) return true;
  if (!isLocalAgentProfile(profile)) return false;
  if (among == null) return true;
  return savedLocalAgentProfile(among.toList(), preferID: preferID)?.id ==
      profile.id;
}

/// Whether [profile] is a server this phone runs itself: the in-app
/// server, the Termux server this app manages, or Claude Code on this
/// phone. Only these lead with the phone mark; any other loopback address
/// (a forwarded port, `adb reverse`, a server started by hand) is drawn as
/// a server like any other.
bool isPhoneOwnServer(ServerProfile profile) =>
    looksLikeInAppServer(profile) || shownAsPhoneRow(profile);

/// Whether [profile] reaches the OpenCode server this app runs in Termux.
bool isManagedPhoneProfile(ServerProfile profile) =>
    profile.backend == ServerBackend.openCode &&
    TermuxBridge.managesServerUrl(profile.baseUrl);
