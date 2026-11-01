import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import '../../../builtin/setup/phone_setup.dart';
import '../../../builtin/setup/setup_contract.dart';
import '../../../builtin/setup/setup_engine.dart' show setupAddingTitle;
import '../../../l10n/app_localizations.dart';
import '../../../termux/bridge.dart';
import '../../app_iconography.dart';
import '../../kit/kit.dart';
import '../../setup_commands.dart';
import '../../widgets/external_link.dart';
import '../../widgets/product_states.dart'
    show productErrorDetails, productErrorText;
import '../../widgets/setup_progress_view.dart';
import '../servers_screen.dart' show ServersRouteRequest;
import 'phone_setup_routes.dart';
import 'phone_setup_selection.dart';
import 'phone_setup_termux_screen.dart' show termuxDownloadUrl;

/// Row ids of the two steps only the person can do.
const termuxGetRowId = 'termux';
const termuxAllowRowId = 'termux-allow';

/// Phone setup's progress (screen B) with Termux as the host (programme
/// P1.2): the same v2 job the in-app setup runs, with the same components,
/// checks and resume rule, run by Termux instead of the app's own Linux.
///
/// "Get Termux" and "Allow Termux" lead the list as rows only the person
/// can do, checked again whenever the app comes back. Then the job runs
/// through the Termux engine ([PhoneSetup.termux]); what Termux already has
/// passes its check and is skipped, a failure is a failed row with Continue
/// setup, and a job Termux kept running while the app was gone is followed,
/// never started twice. A first setup ends on "name your first project";
/// added tools end back where they were added.
class PhoneSetupTermuxJobScreen extends StatefulWidget {
  const PhoneSetupTermuxJobScreen({
    super.key,
    this.selection,
    this.adding = const {},
    this.firstSetup = false,
    this.resume = false,
    this.engine,
    this.openLink,
    this.openReady,
    this.installation,
  });

  /// The tools a first setup installs; the registry defaults when null.
  final Set<String>? selection;

  /// "Add tools": the optional tools this job adds. Empty for a setup.
  final Set<String> adding;

  /// Started as the phone's first setup: it ends on screen C.
  final bool firstSetup;

  /// Opened by "Continue setup" (the start screen): a job that stopped part
  /// way continues as soon as Termux answers, without a second tap.
  final bool resume;

  /// Tests pass a fake; the app uses [PhoneSetup.termux].
  final SetupEngine? engine;

  /// Opens the Termux download page; tests stand in for the browser.
  final Future<void> Function(BuildContext context, String url)? openLink;

  /// Screen C for the Termux host. A parameter so tests see the hand-over.
  final Future<void> Function(BuildContext context)? openReady;

  /// What Termux already has, for the OpenCode the job keeps. Defaults to
  /// [TermuxBridge.inspectInstallation]; tests stand in for Termux.
  final Future<TermuxInstallation> Function()? installation;

  @override
  State<PhoneSetupTermuxJobScreen> createState() =>
      _PhoneSetupTermuxJobScreenState();
}

/// Opens the Termux host's job: a first setup of [selection], or adding
/// [adding] to a phone already set up in Termux.
Future<void> openPhoneSetupTermuxJob(
  BuildContext context, {
  Set<String>? selection,
  Set<String> adding = const {},
  bool firstSetup = false,
  bool resume = false,
}) => pushKitPage<void>(
  context,
  (_) => PhoneSetupTermuxJobScreen(
    selection: selection,
    adding: adding,
    firstSetup: firstSetup,
    resume: resume,
  ),
  settings: const RouteSettings(name: phoneSetupProgressTermuxRouteName),
);

/// Route name of the Termux host's progress.
const phoneSetupProgressTermuxRouteName = 'phone-setup-progress-termux';

/// Where Termux stands for the person steps.
enum _Gate { checking, needTermux, needAllow, outdated, inspectFailed, ready }

class _PhoneSetupTermuxJobScreenState extends State<PhoneSetupTermuxJobScreen>
    with WidgetsBindingObserver {
  late final SetupEngine _engine = widget.engine ?? PhoneSetup.termux;

  _Gate _gate = _Gate.checking;

  /// Why the gate is where it is, when Termux said something ("Android
  /// denied…", "Termux did not answer…").
  String? _gateError;

  /// The technical text behind [_gateError], redacted, for the Details
  /// fold only (never the words).
  String? _gateDetails;
  bool _busy = false;
  bool _checking = false;

  /// The person went to Termux to paste the unlock line.
  bool _openedTermux = false;
  bool _wentToTermux = false;

  /// The engine's job when this screen opened, if it had already finished:
  /// its "done" must not hand over to screen C.
  String? _staleDone;
  bool _restored = false;
  bool _started = false;
  bool _handedOff = false;

  AppLocalizations get _l10n =>
      lookupAppLocalizations(Localizations.localeOf(context));

  /// Off Android there is no Termux: the page says what works instead and
  /// never wakes the Termux engine.
  final bool _supported = TermuxBridge.supported;

  @override
  void initState() {
    super.initState();
    if (!_supported) return;
    _engine.progress.addListener(_onProgress);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_begin());
    });
  }

  @override
  void dispose() {
    if (_supported) {
      WidgetsBinding.instance.removeObserver(this);
      _engine.progress.removeListener(_onProgress);
    }
    super.dispose();
  }

  Future<void> _begin() async {
    try {
      await _engine.restore().timeout(const Duration(seconds: 15));
    } catch (_) {
      // Unreadable now: the gate below and the next poll answer instead.
    }
    if (!mounted) return;
    final progress = _engine.progress.value;
    if (progress.state == SetupState.done) _staleDone = progress.jobId;
    _restored = true;
    if (progress.state == SetupState.running) {
      // Termux kept the job going while the app was away: follow it.
      setState(() => _gate = _Gate.ready);
      return;
    }
    await _check();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _openedTermux) {
      _wentToTermux = true;
    }
    if (state != AppLifecycleState.resumed) return;
    // A permission dialog also resumes the app: only a real trip to Termux
    // and back checks the pasted line.
    if (_openedTermux) {
      if (!_wentToTermux) return;
      _openedTermux = false;
      _wentToTermux = false;
      unawaited(_check());
      return;
    }
    // Back from the download page or Settings: the person steps again
    // (a too-old Termux too, once the current one may be installed).
    if (_gate == _Gate.needTermux ||
        _gate == _Gate.needAllow ||
        _gate == _Gate.outdated) {
      unawaited(_check());
    }
  }

  /// Reads Termux: there, allowed, answering. Once it answers, the job
  /// starts (or the stopped one waits on Continue setup).
  Future<void> _check() async {
    if (_checking || !mounted) return;
    _checking = true;
    setState(() {
      _gate = _Gate.checking;
      _gateError = null;
      _gateDetails = null;
    });
    final l10n = _l10n;
    var gate = _Gate.ready;
    String? error;
    String? details;
    try {
      final capabilities = await TermuxBridge.capabilities();
      if (!capabilities.installed) {
        gate = _Gate.needTermux;
      } else if (!capabilities.serviceAvailable ||
          !capabilities.protocolSupported) {
        gate = _Gate.outdated;
        error = l10n.e7SetupTermuxOutdated;
      } else if (!capabilities.permissionGranted) {
        gate = _Gate.needAllow;
      } else {
        try {
          await TermuxBridge.verifyBridge();
        } on TermuxBridgeException catch (failure) {
          gate = _Gate.needAllow;
          error = failure.code == 'command_timeout'
              ? l10n.e7SetupTermuxNoAnswer
              : productErrorText(failure, l10n: l10n);
          details = productErrorDetails(failure);
        }
      }
    } on PlatformException catch (failure) {
      gate = _Gate.outdated;
      error = l10n.e7SetupInspectTermuxFailed;
      details = productErrorDetails(failure);
    } catch (failure) {
      gate = _Gate.outdated;
      error = productErrorText(failure, l10n: l10n);
      details = productErrorDetails(failure);
    }
    _checking = false;
    if (!mounted) return;
    setState(() {
      _gate = gate;
      _gateError = error;
      _gateDetails = details;
    });
    if (gate == _Gate.ready) await _startIfNew();
  }

  /// Runs the job once Termux answers, unless one stopped part way: that
  /// one waits for Continue setup, which says what it continues.
  Future<void> _startIfNew() async {
    if (_started) return;
    final progress = _engine.progress.value;
    if (progress.state == SetupState.running) return;
    if (progress.canContinue && widget.adding.isEmpty) {
      if (widget.resume) await _continue();
      return;
    }
    _started = true;
    await _run(_ids());
  }

  Set<String> _ids() {
    if (widget.adding.isNotEmpty) return widget.adding;
    return widget.selection ??
        defaultSetupSelection(installableComponents(_engine.registry));
  }

  /// The OpenCode Termux already runs stays the one it runs: a job for the
  /// other generation would install beside it and then have nothing to
  /// start. Absent Ubuntu leaves the runtime to the engine: a saved job
  /// retains its selection, while a genuinely new job uses the fresh default.
  Future<Map<String, Map<String, String>>> _params() async {
    final facts = widget.adding.isNotEmpty
        ? SetupJobParams.adding(widget.adding)
        : widget.firstSetup
        ? SetupJobParams.firstSetup
        : const <String, Map<String, String>>{};
    final installed =
        await (widget.installation ?? TermuxBridge.inspectInstallation)()
            .timeout(const Duration(seconds: 15));
    final keep =
        installed.ubuntuInstalled ||
        installed.runtimeSelected ||
        installed.openCodeVersion != null;
    return {
      ...facts,
      if (keep) 'opencode': {'runtime': installed.runtime.wireName},
    };
  }

  Future<void> _run(Set<String> ids) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final Map<String, Map<String, String>> params;
      try {
        params = await _params();
      } catch (failure) {
        // A failed inventory is not evidence of a fresh installation. Keep
        // the existing runtime untouched and offer the gate's Continue retry.
        if (mounted) {
          setState(() {
            _started = false;
            _gate = _Gate.inspectFailed;
            _gateError = _l10n.e7SetupInspectTermuxFailed;
            _gateDetails = productErrorDetails(failure);
          });
        }
        return;
      }
      await _engine.run(ids, params: params);
    } catch (_) {
      // The engine publishes its own failure; nothing else to say here.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onProgress() {
    if (!mounted) return;
    setState(() {});
    final progress = _engine.progress.value;
    if (!_restored || _handedOff || progress.state != SetupState.done) return;
    if (progress.jobId == _staleDone) return;
    _handedOff = true;
    if (!widget.firstSetup) {
      // The finished list shows for a moment, then where tools were added.
      Future<void>.delayed(const Duration(milliseconds: 1200), () {
        if (mounted) Navigator.of(context).maybePop();
      });
      return;
    }
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    final openReady =
        widget.openReady ??
        (context) => openPhoneSetupReady(context, host: SetupHostKind.termux);
    unawaited(openReady(context));
    // Screen C takes this one's place, so Back never returns to a finished
    // setup (as on the in-app host).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route != null && route.isActive && !route.isCurrent) {
        navigator.removeRoute(route);
      }
    });
  }

  // --- The person's steps ----------------------------------------------------

  Future<void> _getTermux() async {
    final open = widget.openLink;
    if (open != null) return open(context, termuxDownloadUrl);
    await openExternalLink(context, termuxDownloadUrl);
  }

  /// Asks Android for the command permission, copies the unlock line and
  /// opens Termux, where the person pastes it; coming back checks it.
  Future<void> _allowTermux() async {
    if (_busy) return;
    final l10n = _l10n;
    setState(() {
      _busy = true;
      _gateError = null;
      _gateDetails = null;
    });
    String? error;
    String? details;
    try {
      if (!await TermuxBridge.requestPermission()) {
        error = l10n.termuxPermissionDenied;
      } else if (mounted) {
        await KitCopy.copy(context, TermuxBridge.unlockCommand, redact: false);
        _openedTermux = true;
        _wentToTermux = false;
        if (!await TermuxBridge.openTermux()) {
          _openedTermux = false;
          error = l10n.termuxGuideOpenFailed;
        }
      }
    } on PlatformException catch (failure) {
      _openedTermux = false;
      error = l10n.termuxGuideCopyOpenFailed;
      details = productErrorDetails(failure);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _gateError = error;
      _gateDetails = details;
    });
  }

  Future<void> _cancel() async {
    final l10n = _l10n;
    final stop = await showKitConfirm(
      context,
      title: l10n.phoneSetupProgressStopTitle,
      body: l10n.phoneSetupProgressStopMessage,
      confirmLabel: l10n.phoneSetupProgressStopConfirm,
      cancelLabel: l10n.phoneSetupProgressKeepGoing,
      icon: AppIconography.stop,
      kind: KitConfirmKind.stop,
      consequenceItems: [
        KitConsequence(
          l10n.phoneSetupProgressStopContinueLater,
          key: const Key('phone-setup-progress-stop-later'),
        ),
      ],
      confirmKey: const Key('phone-setup-progress-stop-confirm'),
    );
    if (!stop || !mounted) return;
    await _engine.cancel();
  }

  /// Continue setup: the person steps first when Termux is the problem,
  /// else the same components as the job that stopped (the checks skip what
  /// finished, and the job keeps its own OpenCode and facts).
  Future<void> _continue() async {
    if (_gate != _Gate.ready) {
      await _check();
      return;
    }
    final ids = {for (final c in _engine.progress.value.components) c.id};
    _started = true;
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _engine.run(ids.isEmpty ? _ids() : ids);
    } catch (_) {
      // Published by the engine.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // --- The list --------------------------------------------------------------

  List<SetupComponent> _components(AppLocalizations l10n) {
    SetupComponent person(String id, String title) => SetupComponent(
      id: id,
      title: title,
      shortTitle: title,
      checkScript: '',
      installScript: '',
    );
    final registry = _engine.registry;
    final selected = [
      ...expandSetupSelection(
        installableComponents(registry),
        _ids(),
        includeRequired: widget.adding.isEmpty,
      ),
      // Every job ends by starting OpenCode (a job step, not a tool).
      for (final component in registry)
        if (component.jobStep && component.required) component,
    ];
    return [
      person(termuxGetRowId, l10n.e7SetupGetTermux),
      person(termuxAllowRowId, l10n.termuxGuideTitle),
      // The job's own rows come with titles from the whole registry; before
      // it reports them, the selection is the honest guess.
      ...(_hasJob ? registry : selected),
    ];
  }

  bool get _hasJob {
    final progress = _engine.progress.value;
    return progress.components.isNotEmpty &&
        progress.jobId != _staleDone &&
        (_gate == _Gate.ready || progress.state == SetupState.running);
  }

  /// The person rows laid over the engine's progress, so the one view the
  /// in-app setup uses draws the Termux host too.
  SetupProgress _progress(AppLocalizations l10n) {
    final engine = _engine.progress.value;
    ComponentProgress row(String id, ComponentState state, [String? stage]) =>
        ComponentProgress(id: id, state: state, stage: stage);
    final String? termuxStage;
    final ComponentState termuxState;
    final String? allowStage;
    final ComponentState allowState;
    switch (_gate) {
      case _Gate.checking:
        termuxState = ComponentState.checking;
        termuxStage = l10n.e7SetupCheckingTermuxShort;
        allowState = ComponentState.pending;
        allowStage = null;
      case _Gate.needTermux:
        termuxState = ComponentState.pending;
        termuxStage = l10n.e7SetupInstallTermuxDetail;
        allowState = ComponentState.pending;
        allowStage = null;
      case _Gate.needAllow:
        termuxState = ComponentState.done;
        termuxStage = null;
        allowState = ComponentState.pending;
        allowStage = _gateError ?? l10n.phoneSetupTermuxAllowHow;
      case _Gate.outdated:
      case _Gate.inspectFailed:
        termuxState = ComponentState.failed;
        termuxStage = null;
        allowState = ComponentState.pending;
        allowStage = null;
      case _Gate.ready:
        termuxState = ComponentState.done;
        termuxStage = null;
        allowState = ComponentState.done;
        allowStage = null;
    }
    final people = [
      termuxState == ComponentState.failed
          ? ComponentProgress(
              id: termuxGetRowId,
              state: termuxState,
              error: _gateError,
            )
          : row(termuxGetRowId, termuxState, termuxStage),
      row(termuxAllowRowId, allowState, allowStage),
    ];
    if (_hasJob) {
      return SetupProgress(
        state: engine.state,
        components: [...people, ...engine.components],
        overall: engine.overall,
        current: engine.current,
        etaSeconds: engine.etaSeconds,
        error: engine.error,
        logTail: engine.logTail,
        jobId: engine.jobId,
        firstSetup: engine.firstSetup,
        adding: engine.adding,
      );
    }
    final rows = [
      ...people,
      for (final component in _components(l10n).skip(2))
        row(component.id, ComponentState.pending),
    ];
    return SetupProgress(
      state: _gate == _Gate.outdated || _gate == _Gate.inspectFailed
          ? SetupState.failed
          : SetupState.running,
      components: rows,
      overall: 0,
      current: switch (_gate) {
        _Gate.needAllow => termuxAllowRowId,
        _Gate.ready => null,
        _ => termuxGetRowId,
      },
      error: _gate == _Gate.outdated || _gate == _Gate.inspectFailed
          ? _gateError
          : null,
      // What the words leave out, under the view's Details fold.
      logTail: _gateDetails ?? '',
      jobId: 'termux-gate',
      firstSetup: widget.firstSetup,
      adding: widget.adding.toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    if (!_supported) return const PhoneSetupUnsupportedScreen();
    final progress = _progress(l10n);
    final permissionDenied = _gateError == l10n.termuxPermissionDenied;
    final running =
        _hasJob && _engine.progress.value.state == SetupState.running;
    return KitScreen(
      // B6: a saved server's connection problem is not about this
      // phone's own setup: one line, its ways out behind More.
      bodyQuiets: const {KitStatusKind.connection},
      topBar: KitTopBar(title: l10n.phoneSetupStartScreenTitle),
      width: KitScreenWidth.reading,
      body: KeyedSubtree(
        key: const ValueKey('phone-setup-termux-job'),
        child: SetupProgressView(
          progress: progress,
          components: _components(l10n),
          title: progress.adding.isEmpty
              ? l10n.phoneSetupProgressTitle
              : setupAddingTitle(l10n, _engine.registry, progress.adding),
          note: l10n.phoneSetupTermuxLeaveHint,
          personActions: {
            termuxGetRowId: KitAction(
              key: const ValueKey('phone-setup-termux-get'),
              label: l10n.e7SetupGetTermux,
              onPressed: _busy ? null : () => unawaited(_getTermux()),
            ),
            // Allowing is the next step only once Termux is there and
            // current: never offered beside a Termux that must change first.
            if (_gate == _Gate.needAllow)
              termuxAllowRowId: permissionDenied
                  ? KitAction(
                      key: const ValueKey('phone-setup-termux-app-settings'),
                      label: l10n.e7SetupAppSettings,
                      onPressed: () =>
                          unawaited(TermuxBridge.openAppSettings()),
                    )
                  : KitAction(
                      key: const ValueKey('phone-setup-termux-allow'),
                      label: l10n.e7SetupCopyOpenTermux,
                      onPressed: _busy ? null : () => unawaited(_allowTermux()),
                    ),
          },
          // A too-old Termux: its failed row's one way on is the current
          // one; Continue setup checks again once it is installed.
          failureActions: {
            if (_gate == _Gate.outdated)
              termuxGetRowId: KitAction(
                key: const ValueKey('phone-setup-termux-get-current'),
                label: l10n.phoneSetupTermuxGetCurrent,
                onPressed: () => unawaited(_getTermux()),
              ),
          },
          onCancel: running ? _cancel : null,
          onContinue: progress.canContinue && !_busy
              ? () => unawaited(_continue())
              : null,
        ),
      ),
    );
  }
}

/// Phone setup reached where it cannot run (not Android, so no Termux and
/// no on-device Linux): the way that works instead, said plainly — start
/// OpenCode on a computer with the command to copy, then add it here.
class PhoneSetupUnsupportedScreen extends StatelessWidget {
  const PhoneSetupUnsupportedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    return KitScreen(
      // B6: a saved server's connection problem is not about this
      // phone's own setup: one line, its ways out behind More.
      bodyQuiets: const {KitStatusKind.connection},
      topBar: KitTopBar(title: l10n.phoneSetupStartScreenTitle),
      width: KitScreenWidth.reading,
      body: KitStateView(
        key: const ValueKey('phone-setup-termux-unsupported'),
        icon: AppIconography.deviceOff,
        title: l10n.phoneSetupUnsupportedTitle,
        body: l10n.phoneSetupUnsupportedBody,
        content: const KitCodeBlock(
          key: ValueKey('phone-setup-unsupported-command'),
          text: SetupCommands.pair,
          kind: KitCodeKind.command,
        ),
        primary: KitAction(
          key: const ValueKey('phone-setup-unsupported-add-server'),
          label: l10n.e7SetupAddServer,
          onPressed: () => Navigator.of(
            context,
          ).pushNamed('/servers', arguments: const ServersRouteRequest.add()),
        ),
      ),
    );
  }
}
