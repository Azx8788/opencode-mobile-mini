/// This phone › Running on this phone (TEAM-305, P5.3): every process the
/// app's Termux user owns, by what runs, refreshed on pull and every 10
/// seconds while open.
///
/// ONE list ordered by urgency (owner rule 2026-09-27), never split into
/// sections: processes left behind first (a warning mark and "Helper ·
/// Parent gone · Busy · 43 MB · running 1 h 1 min"), then by what runs in
/// the page's order (OpenCode server, AI Team, Claude Code, dev services,
/// terminals, helpers), each row naming its kind first in words beside the
/// kind's mark. "Busy" or "Idle" is measured between two readings (the
/// first comes a few seconds after the page opens), never `ps`'s lifetime
/// CPU average, which moves under Details. Memory is in MB; a missing
/// reading is left out, never shown as zero.
///
/// Above the list, the budget: "18 of 32 background processes", with what
/// the 32 is (Android's limit for all apps together, advisory: the owner
/// may have lifted it and other apps count too).
///
/// The OpenCode server and sshd are protected and say so in words; they
/// send the user to This phone. Stopping one process lives in its row's
/// menu and its details sheet ("Stop Gradle daemon"); a kind with two or
/// more processes also offers one stop for all of them in each of its
/// rows' menus ("Stop all 3 dev services"), asked once with every name;
/// the bulk stop for what was left behind is the last row. Each stop sends
/// exactly the processes the question named, checked again by Termux.
///
/// Built from kit parts only (KIT-1): a [KitScreen] page, [KitSkeletonRows]
/// while the first list is read, [KitStateView] for a list that could not
/// be read or is empty, one [KitRowGroup] of [KitRow]s, [KitNotice] for
/// what a stop did, a [showKitSheet] for a process's details with its
/// technical values in one [KitDetailsFold], and [showKitConfirm] for every
/// stop.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../termux/bridge.dart';
import '../../termux/processes.dart';
import '../app_theme.dart';
import '../kit/kit.dart';
import '../widgets/product_states.dart' show productErrorDetails;
import '../../state/phone_host.dart' show PhoneHostKind;
import 'this_phone_screen.dart';

AppLocalizations _copy(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

/// What runs, in the words that lead a row's line.
String phoneProcessKindLabel(AppLocalizations l10n, TermuxProcess process) {
  if (process.isHostApp) return l10n.termuxProcsKindHostApp;
  return switch (process.kind) {
    PhoneProcessKind.openCodeServer => l10n.termuxProcsKindOpenCode,
    PhoneProcessKind.aiTeam => l10n.termuxProcsKindAiTeam,
    PhoneProcessKind.claudeCode => l10n.termuxProcsKindClaudeCode,
    PhoneProcessKind.devServices => l10n.termuxProcsKindDevService,
    PhoneProcessKind.terminals => l10n.termuxProcsKindTerminal,
    PhoneProcessKind.helpers => l10n.termuxProcsKindHelper,
  };
}

/// The kind's mark: always beside its name in words.
IconData phoneProcessKindIcon(PhoneProcessKind kind) => switch (kind) {
  PhoneProcessKind.openCodeServer => AppIconography.server,
  PhoneProcessKind.aiTeam => AppIconography.kanban,
  PhoneProcessKind.claudeCode => AppIconography.code,
  PhoneProcessKind.devServices => AppIconography.tools,
  PhoneProcessKind.terminals => AppIconography.terminal,
  PhoneProcessKind.helpers => AppIconography.processor,
};

/// A kind in the plural, inside "Stop all 3 dev services".
String phoneProcessKindPlural(AppLocalizations l10n, PhoneProcessKind kind) =>
    switch (kind) {
      PhoneProcessKind.aiTeam => l10n.termuxProcsKindsAiTeam,
      PhoneProcessKind.claudeCode => l10n.termuxProcsKindsClaudeCode,
      PhoneProcessKind.devServices => l10n.termuxProcsKindsDevServices,
      PhoneProcessKind.terminals => l10n.termuxProcsKindsTerminals,
      PhoneProcessKind.helpers ||
      PhoneProcessKind.openCodeServer => l10n.termuxProcsKindsHelpers,
    };

/// What a process is, in the person's words (map infoMissing on
/// termux-processes-details-sheet: "what it is, why it is safe to stop").
String termuxProcessAbout(AppLocalizations l10n, TermuxProcess process) {
  if (process.isHostApp) return l10n.termuxProcsAboutHostApp;
  if (process.isOrphan) return l10n.termuxProcsAboutOrphan;
  return switch (process.kind) {
    PhoneProcessKind.openCodeServer => l10n.termuxProcsAboutOpenCode,
    PhoneProcessKind.aiTeam => l10n.termuxProcsAboutAiTeam,
    PhoneProcessKind.claudeCode => l10n.termuxProcsAboutClaudeCode,
    PhoneProcessKind.devServices => l10n.termuxProcsAboutBuild,
    PhoneProcessKind.terminals => l10n.termuxProcsAboutTerminal,
    PhoneProcessKind.helpers => l10n.termuxProcsAboutOther,
  };
}

/// "42 s", "12 min", "3 h 5 min".
String formatTermuxDuration(AppLocalizations l10n, int seconds) {
  if (seconds < 60) return l10n.termuxProcsDurationSeconds(seconds);
  final minutes = seconds ~/ 60;
  if (minutes < 60) return l10n.termuxProcsDurationMinutes(minutes);
  return l10n.termuxProcsDurationHours(minutes ~/ 60, minutes % 60);
}

String formatTermuxCpuPct(double pct) =>
    pct >= 10 ? pct.round().toString() : pct.toStringAsFixed(1);

/// The budget line: "18 of 32 background processes".
String phoneProcessBudget(AppLocalizations l10n, TermuxProcessReport report) =>
    l10n.termuxProcsBudget(
      report.backgroundCount,
      TermuxProcessReport.androidBackgroundLimit,
    );

/// "Busy · 43 MB · running 1 h 1 min": what a process is doing, without
/// its kind (the row leads with that, the details sheet titles it).
String phoneProcessFacts(
  AppLocalizations l10n,
  TermuxProcess process,
  PhoneProcessActivity activity,
) {
  final memory = process.memoryMb;
  return [
    switch (activity) {
      PhoneProcessActivity.busy => l10n.termuxProcsBusy,
      PhoneProcessActivity.idle => l10n.termuxProcsIdle,
      PhoneProcessActivity.unknown => null,
    },
    if (memory != null) l10n.termuxProcsMemoryMb(memory),
    if (process.elapsedSeconds > 0)
      l10n.termuxProcsRunningFor(
        formatTermuxDuration(l10n, process.elapsedSeconds),
      ),
  ].nonNulls.join(' · ');
}

class TermuxProcessesScreen extends StatefulWidget {
  const TermuxProcessesScreen({
    super.key,
    this.refreshInterval = const Duration(seconds: 10),
    this.sampleDelay = const Duration(seconds: 4),
    this.onOpenServerControls,
  });

  final Duration refreshInterval;

  /// When the second reading comes after the page opens: Busy and Idle
  /// need two.
  final Duration sampleDelay;

  /// Where a protected row (sshd, `opencode serve`) sends the user; the
  /// default opens This phone for Termux.
  final VoidCallback? onOpenServerControls;

  @override
  State<TermuxProcessesScreen> createState() => _TermuxProcessesScreenState();
}

/// What the last stop did: said in place, on the list (§4.8).
class _StopOutcome {
  const _StopOutcome(this.line, {required this.complete});

  final String line;

  /// False when something would not stop (map statesMissing: "a stop that
  /// did not take").
  final bool complete;
}

/// A failure in plain words, its technical text only under Details.
class _Failure {
  const _Failure(this.message, this.details);

  final String message;
  final String? details;
}

class _TermuxProcessesScreenState extends State<TermuxProcessesScreen> {
  TermuxProcessReport? _report;

  /// The reading before [_report]: Busy and Idle compare the two.
  TermuxProcessReport? _previous;
  _Failure? _failure;
  bool _loading = true;
  bool _busy = false;
  _StopOutcome? _outcome;
  Timer? _timer;
  Timer? _sample;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _sample = Timer(widget.sampleDelay, () {
      if (mounted && !_busy) unawaited(_refresh());
    });
    _timer = Timer.periodic(widget.refreshInterval, (_) {
      if (mounted && !_busy) unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sample?.cancel();
    super.dispose();
  }

  /// The technical text behind a failure, redacted, for Details only.
  static String? _technical(Object error) => productErrorDetails(error);

  Future<void> _refresh() async {
    try {
      final report = await TermuxProcesses.scan();
      if (!mounted) return;
      setState(() {
        _previous = _report;
        _report = report;
        _failure = null;
        _loading = false;
      });
    } on Object catch (error) {
      if (error is! TermuxBridgeException && error is! FormatException) {
        rethrow;
      }
      if (!mounted) return;
      final l10n = _copy(context);
      setState(() {
        _failure = _Failure(
          _report == null
              ? l10n.termuxProcsLoadFailedBody
              : l10n.termuxProcsRefreshFailed,
          _technical(error),
        );
        _loading = false;
      });
    }
  }

  /// "Stop java?" (termux-processes-stop-one-sheet). Raised from the
  /// details sheet it replaces that sheet's content in place (§4.7).
  Future<bool> _confirmStop(BuildContext context, TermuxProcess process) {
    final l10n = _copy(context);
    return showKitConfirm(
      context,
      title: l10n.termuxProcsStopOneTitle(process.name),
      body: process.isOrphan
          ? l10n.safetyStopOrphanBody
          : l10n.termuxProcsStopOneBody,
      confirmLabel: l10n.termuxProcsStopSemantics(process.name),
      icon: AppIcons.stop,
      kind: KitConfirmKind.stop,
      // No undo, and it says so (map actionsMissing).
      consequenceItems: [KitConsequence(l10n.termuxProcsNoRestart)],
      sheetKey: const Key('termux-procs-confirm'),
      confirmKey: const Key('termux-procs-confirm-stop'),
    );
  }

  Future<void> _stopProcess(TermuxProcess process) async {
    final confirmed = await _confirmStop(context, process);
    if (!confirmed || !mounted) return;
    await _runStop(() => TermuxProcesses.stopPid(process.pid));
  }

  /// The stoppable processes of [kind], as the list shows them now.
  List<TermuxProcess> _ofKind(PhoneProcessKind kind) => [
    for (final process in _report?.processes ?? const <TermuxProcess>[])
      if (process.stoppable && process.kind == kind) process,
  ];

  /// "Stop all 3 dev services?": one question for a kind, naming every
  /// process it stops; only those are sent (a process that starts after
  /// the question is not added to it).
  Future<void> _stopKind(PhoneProcessKind kind) async {
    final l10n = _copy(context);
    final targets = _ofKind(kind);
    if (targets.isEmpty) return;
    final things = phoneProcessKindPlural(l10n, kind);
    final confirmed = await showKitConfirm(
      context,
      title: l10n.termuxProcsStopKindTitle(targets.length, things),
      body: l10n.termuxProcsStopKindBody(targets.map((p) => p.name).join(', ')),
      confirmLabel: l10n.termuxProcsStopKind(targets.length, things),
      icon: AppIcons.stop,
      kind: KitConfirmKind.stop,
      consequenceItems: switch (kind) {
        PhoneProcessKind.aiTeam => [
          KitConsequence(l10n.termuxProcsStopGroupTeamLost),
          KitConsequence(l10n.termuxProcsStopGroupTeamRestart),
        ],
        PhoneProcessKind.devServices => [
          KitConsequence(l10n.termuxProcsStopDevRestart),
        ],
        _ => [KitConsequence(l10n.termuxProcsNoRestart)],
      },
      sheetKey: const Key('termux-procs-confirm'),
      confirmKey: const Key('termux-procs-confirm-stop'),
    );
    if (!confirmed || !mounted) return;
    await _runStop(
      () => TermuxProcesses.stopPids([for (final p in targets) p.pid]),
    );
  }

  /// "Stop the 2 orphaned helpers?": the one bulk stop for what was left
  /// behind, offered only while such processes exist; the button names
  /// what it stops, and only the ones it named are sent.
  Future<void> _stopOrphans() async {
    final l10n = _copy(context);
    final targets = [
      for (final process in _report?.processes ?? const <TermuxProcess>[])
        if (process.isOrphan && process.stoppable) process,
    ];
    if (targets.isEmpty) return;
    final count = targets.length;
    final confirmed = await showKitConfirm(
      context,
      title: l10n.termuxProcsStopOrphansTitle(count),
      body: l10n.termuxProcsStopKindBody(targets.map((p) => p.name).join(', ')),
      confirmLabel: l10n.termuxProcsStopOrphans(count),
      icon: AppIcons.stop,
      kind: KitConfirmKind.stop,
      consequenceItems: [KitConsequence(l10n.termuxProcsNoRestart)],
      sheetKey: const Key('termux-procs-confirm'),
      confirmKey: const Key('termux-procs-confirm-stop'),
    );
    if (!confirmed || !mounted) return;
    await _runStop(
      () => TermuxProcesses.stopPids([for (final p in targets) p.pid]),
    );
  }

  Future<void> _runStop(
    Future<TermuxProcessStopResult> Function() action,
  ) async {
    final l10n = _copy(context);
    setState(() {
      _busy = true;
      _outcome = null;
      _failure = null;
    });
    try {
      final result = await action();
      if (!mounted) return;
      final parts = <String>[
        if (result.killed.isNotEmpty)
          l10n.termuxProcsStoppedForced(result.endedCount, result.killed.length)
        else
          l10n.termuxProcsStopped(result.endedCount),
        if (result.remaining.isNotEmpty)
          l10n.termuxProcsRemaining(result.remaining.length),
        if (result.refused.isNotEmpty)
          l10n.termuxProcsRefused(result.refused.length),
      ];
      setState(
        () => _outcome = _StopOutcome(
          parts.join(' · '),
          complete: result.remaining.isEmpty,
        ),
      );
    } on Object catch (error) {
      if (error is! TermuxBridgeException && error is! FormatException) {
        rethrow;
      }
      if (mounted) {
        setState(
          () => _failure = _Failure(
            l10n.termuxProcsStopFailed,
            _technical(error),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) await _refresh();
  }

  void _openServerControls() {
    if (widget.onOpenServerControls case final open?) {
      open();
      return;
    }
    unawaited(openThisPhone(context, kind: PhoneHostKind.termux));
  }

  PhoneProcessActivity _activity(TermuxProcess process) =>
      TermuxProcessReport.activityOf(process, _previous);

  /// termux-processes-details-sheet: what the process is in words, what it
  /// is doing, and its command, folder, IDs and processor figures folded
  /// under Details, each copyable; Copy command and a full-width "Stop
  /// java" below.
  Future<void> _showDetails(TermuxProcess process) async {
    final l10n = _copy(context);
    BuildContext? inside;
    await showKitSheet<void>(
      context,
      title: process.name,
      subtitle: phoneProcessKindLabel(l10n, process),
      icon: _iconFor(process),
      secondary: process.protected
          ? KitAction(
              label: l10n.termuxProcsOpenControls,
              icon: AppIconography.settings,
              onPressed: () {
                final sheet = inside;
                if (sheet != null) KitSheet.close<void>(sheet);
                _openServerControls();
              },
            )
          : !process.stoppable
          ? null
          : KitAction(
              key: const Key('termux-procs-details-stop'),
              label: l10n.termuxProcsStopSemantics(process.name),
              icon: AppIcons.stop,
              destructive: true,
              onPressed: _busy
                  ? null
                  : () async {
                      final sheet = inside;
                      if (sheet == null) return;
                      final confirmed = await _confirmStop(sheet, process);
                      if (!confirmed || !mounted) return;
                      if (sheet.mounted) KitSheet.close<void>(sheet);
                      await _runStop(
                        () => TermuxProcesses.stopPid(process.pid),
                      );
                    },
              disabledReason: _busy ? l10n.termuxProcsStopping : null,
            ),
      tertiary: [
        KitAction.copy(
          key: const Key('termux-procs-details-copy'),
          label: l10n.termuxProcsCopyCommand,
          text: () => process.cmd,
        ),
      ],
      body: (sheetContext) {
        inside = sheetContext;
        return _ProcessDetails(process: process, activity: _activity(process));
      },
    );
  }

  /// A row's mark: left behind and protected say so first (both in words
  /// too); otherwise the kind's own mark, named first in the line.
  static IconData _iconFor(TermuxProcess process) => process.isOrphan
      ? AppIconography.warning
      : process.protected
      ? AppIconography.locked
      : phoneProcessKindIcon(process.kind);

  @override
  Widget build(BuildContext context) {
    final l10n = _copy(context);
    final report = _report;
    final failure = _failure;
    final Widget body;
    if (report == null && _loading) {
      body = ListView(
        key: const ValueKey('termux-procs-loading'),
        padding: KitScreen.padding(context),
        children: const [KitSkeletonRows()],
      );
    } else if (report == null) {
      // Termux not answering or the bridge failed (map statesMissing): the
      // plain words, the bridge's own text only under Details.
      body = KitStateView.error(
        key: const ValueKey('termux-procs-load-error'),
        title: l10n.termuxProcsLoadFailedTitle,
        body: failure?.message ?? l10n.termuxProcsLoadFailedBody,
        details: failure?.details,
        bodyKey: const Key('termux-procs-error'),
        retry: KitAction(label: l10n.commonRetry, onPressed: _refresh),
      );
    } else {
      body = KitRefresh(
        onRefresh: _refresh,
        child: ListView(
          key: const ValueKey('termux-procs-list'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsetsDirectional.only(
            top: KitTokens.of(context).space2,
            bottom: KitScreen.endPadding(context),
          ),
          children: [_list(context, l10n, report)],
        ),
      );
    }
    // The list refreshes itself every 10 seconds (and on pull), and says
    // so: no Refresh button repeats it.
    return KitScreen(
      topBar: KitTopBar(title: l10n.termuxProcsTitle),
      width: KitScreenWidth.reading,
      loading: _busy,
      loadingLabel: l10n.termuxProcsStopping,
      body: body,
    );
  }

  /// Left behind first, then by what runs in the page's order; within
  /// that, busy before idle, then the most memory.
  List<TermuxProcess> _ordered(TermuxProcessReport report) {
    final activity = {for (final p in report.processes) p.pid: _activity(p)};
    int rank(TermuxProcess p) => p.isOrphan ? 0 : 1;
    int busy(TermuxProcess p) =>
        activity[p.pid] == PhoneProcessActivity.busy ? 0 : 1;
    return [...report.processes]..sort((a, b) {
      for (final order in [
        rank(a).compareTo(rank(b)),
        a.kind.index.compareTo(b.kind.index),
        busy(a).compareTo(busy(b)),
        (b.memoryMb ?? 0).compareTo(a.memoryMb ?? 0),
      ]) {
        if (order != 0) return order;
      }
      return a.pid.compareTo(b.pid);
    });
  }

  Widget _list(
    BuildContext context,
    AppLocalizations l10n,
    TermuxProcessReport report,
  ) {
    final tokens = KitTokens.of(context);
    final rails = EdgeInsetsDirectional.only(
      start: tokens.gutter,
      end: tokens.gutter,
      bottom: tokens.sectionGap,
    );
    final failure = _failure;
    final outcome = _outcome;
    final ordered = _ordered(report);
    final orphans = ordered.where((p) => p.isOrphan && p.stoppable).length;
    const limit = TermuxProcessReport.androidBackgroundLimit;
    final over = report.backgroundCount > limit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (report.count > 0)
          Padding(
            padding: rails,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KitText(
                  phoneProcessBudget(l10n, report),
                  key: const Key('termux-procs-summary'),
                  role: KitTextRole.headline,
                  tabular: true,
                ),
                SizedBox(height: tokens.space1),
                // Past the limit is said in words (never colour alone).
                KitText(
                  over
                      ? l10n.termuxProcsBudgetOver(limit)
                      : l10n.termuxProcsBudgetNote(limit),
                  key: const Key('termux-procs-budget-note'),
                  role: KitTextRole.caption,
                ),
                SizedBox(height: tokens.space1),
                KitText(l10n.termuxProcsAutoRefresh, role: KitTextRole.caption),
              ],
            ),
          ),
        if (failure != null)
          Padding(
            padding: rails,
            child: KitNotice.error(
              message: failure.message,
              details: failure.details,
              messageKey: const Key('termux-procs-error'),
              retry: KitAction(label: l10n.commonRetry, onPressed: _refresh),
            ),
          ),
        if (outcome != null)
          Padding(
            padding: rails,
            child: KitNotice(
              key: const ValueKey('termux-procs-outcome'),
              tone: outcome.complete ? AppStatusTone.ok : AppStatusTone.failure,
              icon: outcome.complete
                  ? AppIconography.check
                  : AppIconography.error,
              title: outcome.complete ? null : l10n.termuxProcsNotStoppedTitle,
              message: outcome.line,
              messageKey: const Key('termux-procs-result'),
            ),
          ),
        if (report.count == 0)
          Padding(
            padding: rails,
            child: KitStateView(
              key: const Key('termux-procs-empty'),
              icon: AppIconography.processor,
              title: l10n.termuxProcsEmpty,
              body: l10n.termuxProcsEmptyBody,
              size: KitStateSize.inline,
              padding: EdgeInsets.zero,
            ),
          ),
        if (ordered.isNotEmpty)
          Padding(
            padding: EdgeInsetsDirectional.only(bottom: tokens.sectionGap),
            child: KitRowGroup(
              key: const Key('termux-procs-list-group'),
              children: [
                for (final process in ordered) _row(context, l10n, process),
                // The one bulk stop, only while something was left behind,
                // last behind the group's destructive hairline (§4.2).
                if (orphans > 0)
                  KitRow(
                    key: const Key('termux-procs-stop-orphans'),
                    leading: KitRow.icon(context, AppIcons.stop),
                    title: l10n.termuxProcsStopOrphans(orphans),
                    destructive: true,
                    enabled: !_busy,
                    disabledReason: _busy ? l10n.termuxProcsStopping : null,
                    onTap: _stopOrphans,
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// What a process is, then why it was flagged when it was left behind.
  static List<String> _what(AppLocalizations l10n, TermuxProcess process) => [
    phoneProcessKindLabel(l10n, process),
    ?switch (process.orphanReason) {
      TermuxOrphanReason.parentGone => l10n.termuxProcsKindParentGone,
      TermuxOrphanReason.cpuNoOwner => l10n.termuxProcsKindNoOwner,
      null => null,
    },
  ];

  Widget _row(
    BuildContext context,
    AppLocalizations l10n,
    TermuxProcess process,
  ) {
    final facts = phoneProcessFacts(l10n, process, _activity(process));
    final line = [
      ..._what(l10n, process),
      if (facts.isNotEmpty) facts,
    ].join(' · ');
    final kindCount = process.stoppable ? _ofKind(process.kind).length : 0;
    return KitRow(
      key: Key('termux-proc-${process.pid}'),
      leading: KitRow.icon(context, _iconFor(process)),
      title: process.name,
      supporting: TextSpan(text: line),
      supportingKey: Key('termux-proc-line-${process.pid}'),
      supportingMaxLines: 2,
      // The protected server says so in words, and where to control it.
      below: process.protected
          ? KitText(
              l10n.termuxProcsProtected,
              key: Key('termux-proc-protected-${process.pid}'),
              role: KitTextRole.secondary,
            )
          : null,
      trailing: const KitChevron(),
      onTap: process.protected
          ? _openServerControls
          : () => _showDetails(process),
      // One menu per process (map proposal): the same acts as the row, its
      // sheet and its stop button, and its kind's one stop when there are
      // several of that kind.
      menu: [
        if (process.protected)
          KitMenuItem(
            label: l10n.termuxProcsOpenControls,
            icon: AppIconography.settings,
            onSelected: _openServerControls,
          )
        else
          KitMenuItem(
            label: l10n.kitDetails,
            icon: AppIconography.info,
            onSelected: () => _showDetails(process),
          ),
        KitMenuItem.copy(
          label: l10n.termuxProcsCopyCommand,
          text: () => process.cmd,
        ),
        if (process.stoppable)
          KitMenuItem(
            key: Key('termux-proc-stop-${process.pid}'),
            label: l10n.termuxProcsStopSemantics(process.name),
            icon: AppIcons.stop,
            destructive: true,
            enabled: !_busy,
            disabledReason: _busy ? l10n.termuxProcsStopping : null,
            onSelected: () => _stopProcess(process),
          ),
        if (kindCount > 1)
          KitMenuItem(
            key: Key('termux-proc-stop-kind-${process.pid}'),
            label: l10n.termuxProcsStopKind(
              kindCount,
              phoneProcessKindPlural(l10n, process.kind),
            ),
            icon: AppIcons.stop,
            destructive: true,
            enabled: !_busy,
            disabledReason: _busy ? l10n.termuxProcsStopping : null,
            onSelected: () => _stopKind(process.kind),
          ),
      ],
    );
  }
}

/// The details sheet's body: the words first, what it is doing, then every
/// technical value once, copyable, left to right, under one Details fold
/// (§4.3).
class _ProcessDetails extends StatelessWidget {
  const _ProcessDetails({required this.process, required this.activity});

  final TermuxProcess process;
  final PhoneProcessActivity activity;

  @override
  Widget build(BuildContext context) {
    final l10n = _copy(context);
    final tokens = KitTokens.of(context);
    final reason = switch (process.orphanReason) {
      TermuxOrphanReason.parentGone => l10n.termuxProcsOrphanParentGone(
        formatTermuxDuration(l10n, process.elapsedSeconds),
      ),
      TermuxOrphanReason.cpuNoOwner => l10n.termuxProcsOrphanCpu(
        formatTermuxDuration(l10n, process.cpuSeconds),
      ),
      null => null,
    };
    final facts = phoneProcessFacts(l10n, process, activity);
    return Column(
      key: const Key('termux-procs-details'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        KitText(
          termuxProcessAbout(l10n, process),
          key: const Key('termux-procs-details-about'),
        ),
        if (reason != null) ...[
          SizedBox(height: tokens.space2),
          KitText(reason, role: KitTextRole.secondary),
        ],
        if (facts.isNotEmpty) ...[
          SizedBox(height: tokens.space2),
          KitText(
            facts,
            key: const Key('termux-procs-details-facts'),
            role: KitTextRole.secondary,
            tabular: true,
          ),
        ],
        SizedBox(height: tokens.space4),
        KitDetailsFold(
          values: [
            KitTechnicalValue(
              l10n.termuxProcsCommand,
              process.cmd,
              key: const Key('termux-procs-details-command'),
            ),
            if (process.cwd.isNotEmpty)
              KitTechnicalValue(l10n.termuxProcsFolder, process.cwd),
            KitTechnicalValue(l10n.termuxProcsProcessId, '${process.pid}'),
            KitTechnicalValue(l10n.termuxProcsParentId, '${process.ppid}'),
            KitTechnicalValue(
              l10n.termuxProcsAverageCpu,
              '${formatTermuxCpuPct(process.cpuPct)}%',
            ),
            KitTechnicalValue(
              l10n.termuxProcsCpuTime,
              formatTermuxDuration(l10n, process.cpuSeconds),
            ),
          ],
        ),
      ],
    );
  }
}
