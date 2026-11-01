/// Linux › Storage: where the space of the app's own Linux goes, and the
/// safe ways to give some back.
///
/// The breakdown (Linux itself, package downloads, Node and caches, agents
/// and OpenCode, projects, temporary files and logs) is measured on open;
/// projects are shown and never offered for cleanup. Each cleanup names
/// what it clears and what it frees before it runs, asks once, and reports
/// the space it actually freed (two readings). Only paths in the allow list
/// of `linux_storage.dart` are ever touched: never projects, sign-ins,
/// settings or saved server data.
///
/// Kit parts only.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../builtin/linux_manager/linux_manager.dart';
import '../../../builtin/linux_manager/linux_storage.dart';
import '../../../l10n/app_localizations.dart';
import '../../app_theme.dart';
import '../../kit/kit.dart';
import 'linux_manager_common.dart';

class LinuxStoragePage extends ConsumerStatefulWidget {
  const LinuxStoragePage({super.key});

  @override
  ConsumerState<LinuxStoragePage> createState() => _State();
}

class _State extends ConsumerState<LinuxStoragePage> {
  LinuxStorageReport? _report;
  Map<LinuxCleanupId, int> _cleanable = const {};
  Object? _failure;
  bool _loading = true;
  bool _busy = false;
  String? _outcome;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final manager = ref.read(linuxManagerProvider);
    try {
      final report = await manager.measureStorage();
      if (!mounted) return;
      setState(() {
        _report = report;
        _failure = null;
        _loading = false;
      });
      final cleanable = <LinuxCleanupId, int>{};
      for (final action in LinuxCleanupAction.all) {
        cleanable[action.id] = await manager.cleanableBytes(action);
        if (!mounted) return;
      }
      setState(() => _cleanable = cleanable);
    } on LinuxManagerException catch (error) {
      if (!mounted) return;
      setState(() {
        _failure = error;
        _loading = false;
      });
    }
  }

  ({String title, String detail}) _words(
    AppLocalizations l10n,
    LinuxCleanupId id,
  ) => switch (id) {
    LinuxCleanupId.aptCache => (
      title: l10n.linuxMgrCleanApt,
      detail: l10n.linuxMgrCleanAptDetail,
    ),
    LinuxCleanupId.toolCaches => (
      title: l10n.linuxMgrCleanTools,
      detail: l10n.linuxMgrCleanToolsDetail,
    ),
    LinuxCleanupId.tempFiles => (
      title: l10n.linuxMgrCleanTemp,
      detail: l10n.linuxMgrCleanTempDetail,
    ),
    LinuxCleanupId.oldAgentVersions => (
      title: l10n.linuxMgrCleanAgents,
      detail: l10n.linuxMgrCleanAgentsDetail,
    ),
  };

  Future<void> _clean(LinuxCleanupAction action) async {
    final l10n = AppLocalizations.of(context);
    final size = linuxSize(_cleanable[action.id] ?? 0);
    var freed = 0;
    Object? error;
    final yes = await showKitConfirm(
      context,
      title: action.id == LinuxCleanupId.aptCache
          ? l10n.linuxMgrCleanAptAsk
          : action.id == LinuxCleanupId.toolCaches
          ? l10n.linuxMgrCleanToolsAsk
          : action.id == LinuxCleanupId.tempFiles
          ? l10n.linuxMgrCleanTempAsk
          : l10n.linuxMgrCleanAgentsAsk,
      body: l10n.linuxMgrCleanBody(size),
      confirmLabel: action.id == LinuxCleanupId.aptCache
          ? l10n.linuxMgrCleanApt
          : action.id == LinuxCleanupId.toolCaches
          ? l10n.linuxMgrCleanTools
          : action.id == LinuxCleanupId.tempFiles
          ? l10n.linuxMgrCleanTemp
          : l10n.linuxMgrCleanAgents,
      icon: AppIconography.delete,
      kind: KitConfirmKind.destructive,
      consequenceItems: [
        KitConsequence(l10n.linuxMgrCleanKept, mark: KitConsequenceMark.kept),
      ],
      action: () async {
        try {
          freed = await ref.read(linuxManagerProvider).cleanup(action);
        } on LinuxManagerException catch (e) {
          error = e;
          rethrow;
        }
      },
      sheetKey: const Key('linux-clean-sheet'),
      confirmKey: const Key('linux-clean-confirm'),
    );
    if (!mounted) return;
    if (!yes) {
      if (error != null) setState(() => _failure = error);
      return;
    }
    setState(() {
      _failure = null;
      _outcome = freed > 0
          ? l10n.linuxMgrCleanDone(linuxSize(freed))
          : l10n.linuxMgrCleanNothing;
      _busy = false;
    });
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final report = _report;
    final Widget body;
    if (report == null && _loading) {
      body = ListView(
        key: const ValueKey('linux-storage-loading'),
        padding: KitScreen.padding(context),
        children: const [KitSkeletonRows()],
      );
    } else if (report == null) {
      body = KitStateView.error(
        key: const ValueKey('linux-storage-load-error'),
        title: l10n.linuxMgrLoadFailedTitle,
        body: linuxProblemText(l10n, _failure ?? Object()),
        details: linuxProblemDetails(_failure ?? Object()),
        retry: KitAction(label: l10n.commonRetry, onPressed: _refresh),
      );
    } else {
      body = KitRefresh(
        onRefresh: _refresh,
        child: ListView(
          key: const ValueKey('linux-storage-list'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsetsDirectional.only(
            top: KitTokens.of(context).space2,
            bottom: KitScreen.endPadding(context),
          ),
          children: [_list(context, l10n, report)],
        ),
      );
    }
    return KitScreen(
      topBar: KitTopBar(title: l10n.linuxMgrStorageTitle),
      width: KitScreenWidth.reading,
      loading: _loading || _busy,
      loadingLabel: l10n.linuxMgrMeasuring,
      body: body,
    );
  }

  Widget _list(
    BuildContext context,
    AppLocalizations l10n,
    LinuxStorageReport report,
  ) {
    final tokens = KitTokens.of(context);
    final rails = linuxRails(context);
    final categories = <LinuxStorageCategory, (String, String, IconData)>{
      LinuxStorageCategory.base: (
        l10n.linuxMgrCatBase,
        l10n.linuxMgrCatBaseDetail,
        AppIconography.computer,
      ),
      LinuxStorageCategory.packages: (
        l10n.linuxMgrCatPackages,
        l10n.linuxMgrCatPackagesDetail,
        AppIconography.package,
      ),
      LinuxStorageCategory.tools: (
        l10n.linuxMgrCatTools,
        l10n.linuxMgrCatToolsDetail,
        AppIconography.tools,
      ),
      LinuxStorageCategory.agents: (
        l10n.linuxMgrCatAgents,
        l10n.linuxMgrCatAgentsDetail,
        AppIconography.agent,
      ),
      LinuxStorageCategory.projects: (
        l10n.linuxMgrCatProjects,
        l10n.linuxMgrCatProjectsDetail,
        AppIconography.folders,
      ),
      LinuxStorageCategory.temp: (
        l10n.linuxMgrCatTemp,
        l10n.linuxMgrCatTempDetail,
        AppIconography.clock,
      ),
    };
    final offered = [
      for (final action in LinuxCleanupAction.all)
        if ((_cleanable[action.id] ?? 0) >= 1024) action,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: rails,
          child: KitText(
            l10n.linuxMgrStorageTotal(linuxSize(report.total)),
            key: const Key('linux-storage-total'),
            role: KitTextRole.headline,
            tabular: true,
          ),
        ),
        if (_failure != null)
          Padding(
            padding: rails,
            child: KitNotice.error(
              message: linuxProblemText(l10n, _failure!),
              details: linuxProblemDetails(_failure!),
              messageKey: const Key('linux-storage-error'),
            ),
          ),
        if (_outcome != null)
          Padding(
            padding: rails,
            child: KitNotice(
              key: const ValueKey('linux-storage-outcome'),
              tone: AppStatusTone.ok,
              icon: AppIconography.check,
              message: _outcome!,
              messageKey: const Key('linux-storage-result'),
              onDismiss: () => setState(() => _outcome = null),
            ),
          ),
        Padding(
          padding: EdgeInsetsDirectional.only(bottom: tokens.sectionGap),
          child: KitRowGroup(
            key: const Key('linux-storage-group'),
            children: [
              for (final entry in categories.entries)
                KitRow(
                  key: Key('linux-storage-${entry.key.name}'),
                  leading: KitRow.icon(context, entry.value.$3),
                  title: entry.value.$1,
                  supporting: TextSpan(text: entry.value.$2),
                  supportingMaxLines: 2,
                  trailing: KitRowValue(
                    linuxSize(report.of(entry.key)),
                    chevron: false,
                  ),
                ),
            ],
          ),
        ),
        KitSectionLabel(l10n.linuxMgrFreeUp),
        Padding(
          padding: EdgeInsetsDirectional.only(bottom: tokens.sectionGap),
          child: offered.isEmpty
              ? Padding(
                  padding: rails,
                  child: KitText(
                    _cleanable.length < LinuxCleanupAction.all.length
                        ? l10n.linuxMgrMeasuring
                        : l10n.linuxMgrCleanNone,
                    key: const Key('linux-storage-nothing'),
                    role: KitTextRole.secondary,
                  ),
                )
              : KitRowGroup(
                  key: const Key('linux-clean-group'),
                  children: [
                    for (final action in offered)
                      KitRow(
                        key: Key('linux-clean-${action.id.name}'),
                        leading: KitRow.icon(context, AppIconography.delete),
                        title: _words(l10n, action.id).title,
                        titleMaxLines: 2,
                        supporting: TextSpan(
                          text: _words(l10n, action.id).detail,
                        ),
                        supportingMaxLines: 2,
                        trailing: KitRowValue(
                          linuxSize(_cleanable[action.id] ?? 0),
                        ),
                        enabled: !_busy,
                        onTap: () => unawaited(_clean(action)),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
