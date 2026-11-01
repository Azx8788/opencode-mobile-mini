import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/factsbook/control_verifier.dart';
import '../../../domain/factsbook/factsbook_capabilities.dart';
import '../../../domain/factsbook/factsbook_types.dart';
import '../../../domain/relative_age.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/factsbook/factsbook_controller.dart';
import '../../../state/factsbook/factsbook_phone_node.dart';
import '../../kit/kit.dart';
import '../../app_iconography.dart';
import 'factsbook_routes.dart';
import 'factsbook_text.dart';

/// Status (spec 60 screen 29, G34): one row per module with its canonical
/// state as a word (Ready, Waiting, Stale, Failed, Off, Not set up), never one
/// green "connected". "Ready" means recently proven healthy, not "working
/// now". With no cloud configured the page says so and makes no claim of a
/// backup.
class FactsBookStatusScreen extends ConsumerStatefulWidget {
  const FactsBookStatusScreen({super.key});

  @override
  ConsumerState<FactsBookStatusScreen> createState() =>
      _FactsBookStatusScreenState();
}

class _FactsBookStatusScreenState extends ConsumerState<FactsBookStatusScreen> {
  NodeStatus? _status;
  ControlVerification? _control;
  Object? _failure;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final controller = ref.read(factsBookControllerProvider);
      final status = await controller.readStatus();
      if (mounted) setState(() => _status = status);
      // The signed history is checked against the fingerprint pinned at
      // pairing; a node that will not show it (no admin scope) is "not
      // checked", never "verified".
      try {
        final control = await controller.verifyControl();
        if (mounted) {
          setState(() {
            _control = control;
          });
        }
      } on FactsBookException {
        if (mounted) {
          setState(() {
            _control = null;
          });
        }
      }
    } on FactsBookException catch (failure) {
      if (mounted) setState(() => _failure = failure);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _disconnect() async {
    final l10n = AppLocalizations.of(context);
    final session = ref.read(factsBookSessionProvider);
    final navigator = Navigator.of(context);
    final name = nodeName(l10n, session.link);
    final yes = await showKitConfirm(
      context,
      title: l10n.fbDisconnectTitle(name),
      body: l10n.fbDisconnectBody,
      confirmLabel: l10n.fbDisconnect(name),
      kind: KitConfirmKind.destructive,
      confirmKey: const ValueKey('factsbook-disconnect-confirm'),
    );
    if (!yes) return;
    await session.disconnect();
    if (mounted) navigator.popUntil((route) => route.isFirst);
  }

  String _module(AppLocalizations l10n, String name) => switch (name) {
    'storage' => l10n.fbModuleStorage,
    'cloud' => l10n.fbModuleCloud,
    'care' => l10n.fbModuleCare,
    'replication' => l10n.fbModuleReplication,
    'index' => l10n.fbModuleIndex,
    'membership' => l10n.fbModuleMembership,
    _ => name,
  };

  String _historyWords(AppLocalizations l10n) {
    final control = _control;
    if (control == null) return l10n.fbStatusHistoryNotChecked;
    if (control.forked) return l10n.fbStatusHistoryForked;
    return control.trusted
        ? l10n.fbStatusHistoryVerified
        : l10n.fbStatusHistoryFailed;
  }

  KitStatusTag? _tag(AppLocalizations l10n, ModuleState state) =>
      switch (state) {
        ModuleState.ok => KitStatusTag(
          label: l10n.fbStateReady,
          tone: KitStatusTagTone.done,
        ),
        ModuleState.waiting => KitStatusTag(
          label: l10n.fbStateWaiting,
          tone: KitStatusTagTone.running,
        ),
        ModuleState.failed => KitStatusTag(
          label: l10n.fbStateFailed,
          tone: KitStatusTagTone.failed,
        ),
        ModuleState.stale || ModuleState.disabled || ModuleState.absent => null,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final status = _status;
    final Widget body;
    if (status == null && _failure == null) {
      body = ListView(
        padding: KitScreen.padding(context),
        children: const [KitSkeletonRows()],
      );
    } else if (status == null) {
      body = KitStateView.error(
        key: const ValueKey('factsbook-status-error'),
        title: l10n.fbErrorTitle,
        body: failureWords(l10n, _failure),
        details: failureDetails(l10n, _failure),
        retry: KitAction(
          label: l10n.commonRetry,
          onPressed: () => unawaited(_load()),
        ),
      );
    } else {
      final now = clock.now();
      final session = ref.read(factsBookSessionProvider);
      body = KitRefresh(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsetsDirectional.only(
            top: tokens.space2,
            bottom: KitScreen.endPadding(context),
          ),
          children: [
            _summary(l10n, status),
            if (!status.modules.containsKey('replication') ||
                status.module('replication').state != ModuleState.ok)
              KitGroupNote(message: l10n.fbStatusNoReplication),
            KitRowGroup(
              label: l10n.fbStatusNotYet,
              leadingIcons: false,
              children: [
                for (final (capability, title) in [
                  (FactsBookCapabilities.cloudTransport, l10n.fbNotYetCloud),
                  (FactsBookCapabilities.sensitiveUnlock, l10n.fbNotYetUnlock),
                  (FactsBookCapabilities.phoneAlarms, l10n.fbNotYetAlarms),
                ])
                  if (session.capabilities.isDisabled(capability))
                    KitRow(
                      key: ValueKey('factsbook-status-not-yet-$capability'),
                      title: title,
                      supporting: TextSpan(text: l10n.fbNotAvailableYet),
                    ),
              ],
            ),
            KitRowGroup(
              label: l10n.fbStatusThisPhone,
              leadingIcons: false,
              children: [
                _simpleRow(
                  'approve',
                  l10n.fbStatusApprove,
                  session.canApprove ? l10n.fbStateReady : l10n.fbStateNotSetUp,
                  onTap: session.canApprove
                      ? null
                      : () => unawaited(openFactsBookConnect(context)),
                ),
                if (ref.read(factsBookPhoneNodeHostProvider).supported)
                  KitRow(
                    key: const ValueKey('factsbook-status-phone-node'),
                    title: l10n.fbNodeTitle,
                    trailing: const KitChevron(),
                    onTap: () => unawaited(openFactsBookPhoneNode(context)),
                  ),
                KitRow(
                  key: const ValueKey('factsbook-status-disconnect'),
                  title: l10n.fbDisconnect(nodeName(l10n, session.link)),
                  titleMaxLines: 2,
                  destructive: true,
                  supporting: TextSpan(text: l10n.fbDisconnectDetail),
                  supportingMaxLines: 3,
                  onTap: () => unawaited(_disconnect()),
                ),
              ],
            ),
            Padding(
              padding: EdgeInsetsDirectional.symmetric(
                horizontal: tokens.gutter,
              ),
              child: KitDetailsFold(
                foldKey: const ValueKey('factsbook-status-details'),
                child: _details(l10n, status, now),
              ),
            ),
          ],
        ),
      );
    }
    return KitScreen(
      topBar: KitTopBar(title: l10n.fbStatusTitle),
      width: KitScreenWidth.reading,
      loading: _loading && status != null,
      loadingLabel: l10n.fbStatusTitle,
      body: body,
    );
  }

  /// What is not right, in the person's words; empty when all is well.
  List<String> _problems(AppLocalizations l10n, NodeStatus status) {
    final found = <String>[];
    for (final entry in status.modules.entries) {
      if (entry.key == 'cloud') continue;
      final state = entry.value.state;
      if (state == ModuleState.failed ||
          state == ModuleState.stale ||
          state == ModuleState.waiting) {
        found.add(_module(l10n, entry.key));
      }
    }
    if (!status.modules.containsKey('index') &&
        (status.indexNormal == ModuleState.failed ||
            status.indexNormal == ModuleState.waiting)) {
      found.add(l10n.fbStatusSearch);
    }
    final control = _control;
    if (control != null && (control.forked || !control.trusted)) {
      found.add(l10n.fbStatusHistory);
    }
    return found;
  }

  /// One line: everything works, or what does not.
  Widget _summary(AppLocalizations l10n, NodeStatus status) {
    final problems = _problems(l10n, status);
    return KitRowGroup(
      leadingIcons: true,
      children: [
        KitRow(
          key: const ValueKey('factsbook-status-summary'),
          leading: KitRow.icon(
            context,
            problems.isEmpty
                ? AppIconography.checkCircle
                : AppIconography.warning,
          ),
          title: problems.isEmpty
              ? l10n.fbStatusAllWorking
              : l10n.fbStatusNeedsLook(problems.length),
          titleMaxLines: 2,
          supporting: problems.isEmpty
              ? null
              : TextSpan(text: problems.join(', ')),
          supportingMaxLines: 3,
        ),
        _backupRow(l10n, status),
      ],
    );
  }

  /// One Backup row for what used to be three: the cloud module, the age of
  /// the cloud copy and the backed-up flag.
  Widget _backupRow(AppLocalizations l10n, NodeStatus status) {
    final String value;
    if (status.safeInCloud) {
      value = status.staleSeconds == null
          ? l10n.fbStatusBackedUp
          : l10n.fbStatusBackedUpAge(
              relativeAgeLabel(
                Duration(seconds: status.staleSeconds!),
                l10n: l10n,
              ),
            );
    } else {
      value = l10n.fbStatusNoBackup;
    }
    return _simpleRow('backup', l10n.fbStatusBackup, value);
  }

  /// The module by module list, for when something is not right.
  Widget _details(AppLocalizations l10n, NodeStatus status, DateTime now) =>
      KitRowGroup(
        leadingIcons: false,
        children: [
          for (final entry in status.modules.entries)
            if (entry.key != 'cloud')
              _moduleRow(l10n, now, entry.key, entry.value),
          _simpleRow(
            'checked',
            l10n.fbStatusChecked,
            status.generatedAt == null
                ? l10n.fbStatusUnknown
                : relativeAgeLabel(
                    now.difference(status.generatedAt!),
                    at: status.generatedAt,
                    l10n: l10n,
                  ),
          ),
          _simpleRow('history', l10n.fbStatusHistory, _historyWords(l10n)),
          if (!status.modules.containsKey('index'))
            _simpleRow(
              'search',
              l10n.fbStatusSearch,
              moduleStateWords(l10n, status.indexNormal),
              tag: _tag(l10n, status.indexNormal),
            ),
          _simpleRow('locked', l10n.fbAreasLockedFolder, switch (status.key) {
            'unlocked' => l10n.fbKeyUnlocked,
            'locked' => l10n.fbKeyLocked,
            _ => l10n.fbStateNotSetUp,
          }),
        ],
      );

  Widget _simpleRow(
    String id,
    String title,
    String value, {
    KitStatusTag? tag,
    VoidCallback? onTap,
  }) => KitRow(
    key: ValueKey('factsbook-status-$id'),
    title: title,
    supporting: TextSpan(text: value),
    trailing: tag ?? (onTap == null ? null : const KitChevron()),
    onTap: onTap,
  );

  Widget _moduleRow(
    AppLocalizations l10n,
    DateTime now,
    String name,
    ModuleStatus module,
  ) {
    final reason = moduleReasonWords(l10n, module.code);
    final since = module.since;
    final line = [
      moduleStateWords(l10n, module.state),
      ?reason,
      if (since != null)
        l10n.fbStatusSince(
          relativeAgeLabel(now.difference(since), at: since, l10n: l10n),
        ),
    ].join(' · ');
    return KitRow(
      key: ValueKey('factsbook-status-module-$name'),
      title: _module(l10n, name),
      supporting: TextSpan(text: line),
      supportingMaxLines: 3,
      trailing: _tag(l10n, module.state),
    );
  }
}
