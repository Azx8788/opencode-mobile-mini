import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../builtin/setup/components.dart' show SetupComponentIds;
import '../../../builtin/setup/setup_contract.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/connection.dart';
import '../../../state/termux_host_setup.dart';
import '../../../termux/bridge.dart';
import '../../kit/kit.dart';
import '../../widgets/external_link.dart';
import '../../widgets/setup_progress_view.dart';
import '../../widgets/setup_ui_messages.dart';
import 'phone_setup_termux_job_screen.dart';

/// Where Termux comes from: the current F-Droid build.
const termuxDownloadUrl = 'https://f-droid.org/en/packages/com.termux/';

/// Phone setup's progress screen (screen B) for the Termux host: the old
/// Termux wizard's steps as the same checklist the in-app setup shows.
///
/// "Get Termux" and "Allow Termux" are rows only the person can do; the
/// install, the switch between OpenCode 1 and 2, the update and the start
/// are rows the Termux manager works through while the log folds under
/// Details. A failure is a failed row with Continue setup. A first setup
/// ends in the app; an update or a switch ends back on This phone.
class PhoneSetupTermuxScreen extends ConsumerStatefulWidget {
  const PhoneSetupTermuxScreen({
    super.key,
    this.job = TermuxHostJob.install,
    this.target,
    this.firstSetup = false,
    this.setup,
    this.openLink,
    this.now,
  });

  final TermuxHostJob job;

  /// Where a [TermuxHostJob.switchRuntime] goes.
  final TermuxRuntime? target;

  /// Started from phone setup's start screen: it ends in the app.
  final bool firstSetup;

  /// Tests pass their own host; the app makes one from the providers.
  final TermuxHostSetup? setup;

  /// Opens the Termux download page; tests stand in for the browser.
  final Future<void> Function(BuildContext context, String url)? openLink;

  /// Tests advance wall time for the elapsed line.
  final DateTime Function()? now;

  @override
  ConsumerState<PhoneSetupTermuxScreen> createState() =>
      _PhoneSetupTermuxScreenState();
}

/// Opens the Termux host's progress for [job]. Installing is the v2 job
/// with Termux as its host (P1.2, [PhoneSetupTermuxJobScreen]); updating,
/// switching and starting still go through the Termux manager here until
/// the old wizard retires (P1.3).
Future<void> openPhoneSetupTermux(
  BuildContext context, {
  TermuxHostJob job = TermuxHostJob.install,
  TermuxRuntime? target,
  bool firstSetup = false,
  Set<String>? selection,
}) {
  if (job == TermuxHostJob.install) {
    return openPhoneSetupTermuxJob(
      context,
      selection: selection,
      firstSetup: firstSetup,
    );
  }
  return pushKitPage<void>(
    context,
    (_) => PhoneSetupTermuxScreen(
      job: job,
      target: target,
      firstSetup: firstSetup,
    ),
    settings: const RouteSettings(name: phoneSetupProgressTermuxRouteName),
  );
}

class _PhoneSetupTermuxScreenState extends ConsumerState<PhoneSetupTermuxScreen>
    with WidgetsBindingObserver {
  late final TermuxHostSetup _setup;
  late final bool _ownsSetup;
  bool _wentToTermux = false;
  bool _finished = false;

  /// The row the job was last at, so a failure lands on the row that failed.
  int _lastIndex = 0;
  Timer? _clock;

  AppLocalizations get _l10n =>
      lookupAppLocalizations(Localizations.localeOf(context));

  @override
  void initState() {
    super.initState();
    _ownsSetup = widget.setup == null;
    _setup =
        widget.setup ??
        TermuxHostSetup(
          store: ref.read(bootstrapProvider).store,
          connection: ref.read(connProvider),
          copy: () => _l10n,
        );
    _setup.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    // The elapsed line repaints from wall time, not by counting callbacks.
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _setup.phase == TermuxHostPhase.working) setState(() {});
    });
    if (TermuxBridge.supported) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_setup.begin(widget.job, target: widget.target));
        }
      });
    }
  }

  @override
  void dispose() {
    _clock?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _setup.removeListener(_changed);
    if (_ownsSetup) _setup.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _setup.openedTermux) {
      _wentToTermux = true;
    }
    if (state != AppLifecycleState.resumed) return;
    // A permission dialog also resumes the app: only a real trip to Termux
    // and back verifies the pasted line.
    if (_setup.openedTermux) {
      if (!_wentToTermux) return;
      _wentToTermux = false;
      unawaited(_setup.verifyAfterReturn());
      return;
    }
    if (_setup.busy) return;
    if (_setup.phase == TermuxHostPhase.needTermux ||
        _setup.phase == TermuxHostPhase.needAllow) {
      unawaited(_setup.check());
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (_finished || _setup.phase != TermuxHostPhase.ready) return;
    _finished = true;
    if (widget.firstSetup) {
      unawaited(
        Navigator.of(context).pushNamedAndRemoveUntil('/home', (_) => false),
      );
      return;
    }
    // The finished list shows for a moment, then This phone again.
    Future<void>.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  Future<void> _getTermux() async {
    final open = widget.openLink;
    if (open != null) return open(context, termuxDownloadUrl);
    await openExternalLink(context, termuxDownloadUrl);
  }

  Future<void> _allowTermux() =>
      _setup.allowTermux((text) => KitCopy.copy(context, text, redact: false));

  // --- The checklist -------------------------------------------------------

  List<String> get _rowIds => switch (widget.job) {
    TermuxHostJob.install => const [
      _termux,
      _allow,
      SetupComponentIds.linux,
      SetupComponentIds.openCode,
      SetupComponentIds.start,
    ],
    TermuxHostJob.update => const [
      SetupComponentIds.linux,
      SetupComponentIds.openCode,
      SetupComponentIds.start,
    ],
    TermuxHostJob.switchRuntime => const [
      SetupComponentIds.openCode,
      SetupComponentIds.start,
    ],
    TermuxHostJob.start => const [SetupComponentIds.start],
  };

  static const _termux = 'termux';
  static const _allow = 'termux-allow';

  String _runtimeName(AppLocalizations l10n, TermuxRuntime runtime) =>
      l10n.setupRuntimeTwo;

  List<SetupComponent> _components(AppLocalizations l10n) {
    SetupComponent row(String id, String title) => SetupComponent(
      id: id,
      title: title,
      shortTitle: title,
      checkScript: '',
      installScript: '',
    );
    final openCode = _runtimeName(
      l10n,
      widget.job == TermuxHostJob.switchRuntime
          ? widget.target ?? _setup.runtime
          : _setup.runtime,
    );
    return [
      for (final id in _rowIds)
        switch (id) {
          _termux => row(id, l10n.e7SetupGetTermux),
          _allow => row(id, l10n.termuxGuideTitle),
          SetupComponentIds.linux => row(id, l10n.phoneSetupLinuxTitle),
          SetupComponentIds.openCode => row(id, openCode),
          _ => row(id, l10n.phoneSetupStartTitle),
        },
    ];
  }

  /// Which row the manager's phase belongs to.
  int? _indexOfPhase(String phase) {
    final ids = _rowIds;
    final String id;
    switch (phase) {
      case 'queued' ||
          'preparing' ||
          'installing_dependencies' ||
          'installing_ubuntu':
        id = SetupComponentIds.linux;
      case 'installing_opencode' || 'refreshing_models':
        id = SetupComponentIds.openCode;
      case 'starting_server' || 'restarting' || 'ready':
        id = SetupComponentIds.start;
      default:
        return null;
    }
    final index = ids.indexOf(id);
    // A switch has no Linux row; its manager steps all belong to OpenCode
    // until the start.
    if (index < 0) return id == SetupComponentIds.start ? ids.length - 1 : 0;
    return index;
  }

  /// The job as the setup engine's progress, so the Termux host is drawn by
  /// the very view the in-app setup uses.
  SetupProgress _progress(AppLocalizations l10n) {
    final ids = _rowIds;
    final setup = _setup;
    final phase = setup.phase;
    final firstWork = ids.indexWhere((id) => id != _termux && id != _allow);
    int current;
    ComponentState currentState = ComponentState.running;
    String? stage;
    switch (phase) {
      case TermuxHostPhase.checking:
        current = _lastIndex;
        stage = l10n.e7SetupCheckingTermuxShort;
        currentState = ComponentState.checking;
      case TermuxHostPhase.needTermux:
        current = ids.indexOf(_termux);
        currentState = ComponentState.pending;
        stage = l10n.e7SetupInstallTermuxDetail;
      case TermuxHostPhase.needAllow:
        current = ids.indexOf(_allow);
        currentState = ComponentState.pending;
        final error = setup.error;
        stage = error == null
            ? l10n.phoneSetupTermuxAllowHow
            : termuxPlainError(l10n, error);
      case TermuxHostPhase.idle:
      case TermuxHostPhase.working:
        final status = setup.status;
        current =
            (status == null ? null : _indexOfPhase(status.phase)) ??
            math.max(firstWork, 0);
        final message = status?.message.trim();
        stage = message == null || message.isEmpty
            ? null
            : setupUiMessage(l10n, message);
      case TermuxHostPhase.connecting:
        current = ids.length - 1;
        stage = l10n.phoneSetupTermuxConnecting;
      case TermuxHostPhase.ready:
        current = ids.length;
      case TermuxHostPhase.failed:
        current = _lastIndex;
        currentState = ComponentState.failed;
    }
    if (current < 0) current = math.max(firstWork, 0);
    if (phase != TermuxHostPhase.failed && current < ids.length) {
      _lastIndex = current;
    }
    final error = setup.error;
    final version = setup.installedVersion;
    final rows = <ComponentProgress>[
      for (var i = 0; i < ids.length; i++)
        ComponentProgress(
          id: ids[i],
          state: i < current
              ? ComponentState.done
              : i == current
              ? currentState
              : ComponentState.pending,
          stage: i == current ? stage : null,
          version: i < current && ids[i] == SetupComponentIds.openCode
              ? version
              : null,
          error: i == current && currentState == ComponentState.failed
              ? (error == null ? null : termuxPlainError(l10n, error))
              : null,
        ),
    ];
    final done = rows.where((r) => r.state == ComponentState.done).length;
    final working = rows.any((r) => r.state == ComponentState.running);
    return SetupProgress(
      state: switch (phase) {
        TermuxHostPhase.ready => SetupState.done,
        TermuxHostPhase.failed => SetupState.failed,
        _ => SetupState.running,
      },
      components: rows,
      overall: ((done + (working ? .5 : 0)) / ids.length).clamp(0, 1),
      current: current < ids.length ? ids[current] : null,
      error: error == null ? null : termuxPlainError(l10n, error),
      logTail: setup.output,
      jobId: 'termux-${widget.job.name}',
    );
  }

  String? _elapsed(AppLocalizations l10n) {
    final startedAt = _setup.startedAtEpochSeconds;
    if (startedAt == null || _setup.phase != TermuxHostPhase.working) {
      return null;
    }
    final now = widget.now?.call() ?? DateTime.now();
    final seconds = math.max(0, now.millisecondsSinceEpoch ~/ 1000 - startedAt);
    return seconds < 60
        ? l10n.e7SetupElapsedSeconds(seconds)
        : l10n.e7SetupElapsedMinutes(seconds ~/ 60, seconds % 60);
  }

  String _title(AppLocalizations l10n) => switch (widget.job) {
    TermuxHostJob.install => l10n.phoneSetupProgressTitle,
    TermuxHostJob.update => l10n.phoneSetupTermuxUpdatingTitle,
    TermuxHostJob.switchRuntime => l10n.setupSwitchProgressTitle(
      _runtimeName(l10n, widget.target ?? _setup.runtime),
    ),
    TermuxHostJob.start => l10n.phoneSetupTermuxStartingTitle,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    // Termux is an Android app: said plainly, with the way that works.
    if (!TermuxBridge.supported) return const PhoneSetupUnsupportedScreen();
    final progress = _progress(l10n);
    final busy = _setup.busy;
    final permissionDenied = _setup.error == l10n.termuxPermissionDenied;
    return KitScreen(
      // B6: a saved server's connection problem is not about this
      // phone's own setup: one line, its ways out behind More.
      bodyQuiets: const {KitStatusKind.connection},
      topBar: KitTopBar(title: l10n.phoneSetupStartScreenTitle),
      width: KitScreenWidth.reading,
      body: KeyedSubtree(
        key: const ValueKey('phone-setup-termux'),
        child: SetupProgressView(
          progress: progress,
          components: _components(l10n),
          title: _title(l10n),
          note: widget.job == TermuxHostJob.install
              ? l10n.phoneSetupTermuxLeaveHint
              : null,
          timeLine: _elapsed(l10n),
          personActions: {
            _termux: KitAction(
              key: const ValueKey('phone-setup-termux-get'),
              label: l10n.e7SetupGetTermux,
              onPressed: busy ? null : () => unawaited(_getTermux()),
            ),
            _allow: permissionDenied
                ? KitAction(
                    key: const ValueKey('phone-setup-termux-app-settings'),
                    label: l10n.e7SetupAppSettings,
                    onPressed: () => unawaited(TermuxBridge.openAppSettings()),
                  )
                : KitAction(
                    key: const ValueKey('phone-setup-termux-allow'),
                    label: l10n.e7SetupCopyOpenTermux,
                    onPressed: busy ? null : () => unawaited(_allowTermux()),
                  ),
          },
          onContinue: busy ? null : () => unawaited(_setup.retry()),
        ),
      ),
    );
  }
}

/// A Termux failure in the person's words. The raw text stays in the log
/// and the copied report, where the exact bridge wording helps.
String termuxPlainError(AppLocalizations l10n, String raw) {
  if (raw.contains('command-result protocol')) {
    return l10n.e7SetupTermuxOutdated;
  }
  if (raw.contains('setup manager disappeared') ||
      raw.contains('without starting the setup manager')) {
    return l10n.e7SetupSetupNotStarted;
  }
  if (raw.contains('Could not read setup manager status')) {
    return raw.replaceFirst(
      'Could not read setup manager status',
      l10n.e7SetupSetupLost,
    );
  }
  return setupUiMessage(l10n, raw);
}
