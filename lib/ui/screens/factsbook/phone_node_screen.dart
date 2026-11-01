import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../state/factsbook/factsbook_phone_node.dart';
import '../../app_iconography.dart';
import '../../kit/kit.dart';
import '../phone_setup/phone_setup_routes.dart';
import 'capture_screen.dart';
import 'factsbook_routes.dart';

/// Use memory on this phone (F6): FactsBook running inside the built-in Linux
/// on this phone. It is the first-run path: one button installs it, starts it
/// and connects this app to it, and then the person lands in Add something.
/// Stop and Restart stay here; Remove and the log sit under Details, and so
/// does the way to connect to the person's own server. States are said in
/// plain words; the technical reason of a failure sits under Details.
class FactsBookPhoneNodeScreen extends ConsumerStatefulWidget {
  const FactsBookPhoneNodeScreen({super.key});

  @override
  ConsumerState<FactsBookPhoneNodeScreen> createState() =>
      _FactsBookPhoneNodeScreenState();
}

class _FactsBookPhoneNodeScreenState
    extends ConsumerState<FactsBookPhoneNodeScreen> {
  String? _notice;
  String? _log;

  /// The person pressed the setup button on this page: when it ends with the
  /// app connected, the page hands over to Add something.
  bool _ranHere = false;
  bool _handedOver = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(factsBookPhoneNodeProvider).refresh());
    });
  }

  Future<void> _remove() async {
    final l10n = AppLocalizations.of(context);
    final node = ref.read(factsBookPhoneNodeProvider);
    final ok = await showKitConfirm(
      context,
      title: l10n.fbNodeRemoveTitle,
      body: l10n.fbNodeRemoveBody,
      confirmLabel: l10n.fbNodeRemove,
      kind: KitConfirmKind.destructive,
      consequences: [l10n.fbNodeRemoveLoses1, l10n.fbNodeRemoveLoses2],
    );
    if (!ok || !mounted) return;
    await node.remove();
    if (mounted && node.state != PhoneNodeState.failed) {
      setState(() => _notice = l10n.fbNodeRemoved);
    }
  }

  Future<void> _showLog() async {
    final node = ref.read(factsBookPhoneNodeProvider);
    try {
      final text = await node.log();
      if (mounted) setState(() => _log = text);
    } on Object {
      if (mounted) setState(() => _log = '');
    }
  }

  String _failureWords(AppLocalizations l10n, PhoneNodeProblem? problem) =>
      switch (problem) {
        PhoneNodeProblem.install => l10n.fbNodeFailInstall,
        PhoneNodeProblem.start || null => l10n.fbNodeFailStart,
        PhoneNodeProblem.pair => l10n.fbNodeFailPair,
        PhoneNodeProblem.stop => l10n.fbNodeFailStop,
        PhoneNodeProblem.remove => l10n.fbNodeFailRemove,
      };

  String _stepWords(AppLocalizations l10n, PhoneNodeStep step) =>
      switch (step) {
        PhoneNodeStep.copying => l10n.fbNodeStepCopying,
        PhoneNodeStep.preparing => l10n.fbNodeStepPreparing,
        PhoneNodeStep.starting => l10n.fbNodeStepStarting,
        PhoneNodeStep.pairing => l10n.fbNodeStepPairing,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final node = ref.watch(factsBookPhoneNodeProvider);
    return ListenableBuilder(
      listenable: node,
      builder: (context, _) {
        final state = node.state;
        final working =
            node.busy ||
            state == PhoneNodeState.checking ||
            state == PhoneNodeState.installing ||
            state == PhoneNodeState.stopping ||
            state == PhoneNodeState.removing;
        final (IconData icon, String title, String body) = switch (state) {
          PhoneNodeState.checking => (
            AppIconography.database,
            l10n.fbNodeTitle,
            '',
          ),
          PhoneNodeState.unsupported => (
            AppIconography.info,
            l10n.fbNodeUnsupportedTitle,
            l10n.fbNodeUnsupportedBody,
          ),
          PhoneNodeState.linuxNotSetUp => (
            AppIconography.info,
            l10n.fbNodeLinuxTitle,
            l10n.fbNodeLinuxBody,
          ),
          PhoneNodeState.noBuild => (
            AppIconography.info,
            l10n.fbNodeNoBuildTitle,
            l10n.fbNodeNoBuildBody,
          ),
          PhoneNodeState.notInstalled => (
            AppIconography.database,
            l10n.fbNodeNotInstalledTitle,
            l10n.fbNodeNotInstalledBody,
          ),
          PhoneNodeState.installing => (
            AppIconography.database,
            _stepWords(l10n, node.step),
            l10n.fbNodeNotInstalledBody,
          ),
          PhoneNodeState.starting => (
            AppIconography.database,
            l10n.fbNodeStepStarting,
            '',
          ),
          PhoneNodeState.running => (
            AppIconography.checkCircle,
            l10n.fbNodeRunningTitle,
            l10n.fbNodeRunningBody,
          ),
          PhoneNodeState.stopping => (
            AppIconography.database,
            l10n.fbNodeStopping,
            '',
          ),
          PhoneNodeState.stopped => (
            AppIconography.pause,
            l10n.fbNodeStoppedTitle,
            l10n.fbNodeStoppedBody,
          ),
          PhoneNodeState.removing => (
            AppIconography.database,
            l10n.fbNodeRemoving,
            '',
          ),
          PhoneNodeState.failed => (
            AppIconography.info,
            l10n.fbErrorTitle,
            _failureWords(l10n, node.problem),
          ),
        };
        final canRun =
            state == PhoneNodeState.notInstalled ||
            (state == PhoneNodeState.failed &&
                (node.problem == PhoneNodeProblem.install));
        final canStart =
            state == PhoneNodeState.stopped ||
            (state == PhoneNodeState.failed &&
                (node.problem == PhoneNodeProblem.start ||
                    node.problem == PhoneNodeProblem.pair));
        final installed =
            node.facts.dataExists ||
            state == PhoneNodeState.running ||
            state == PhoneNodeState.stopped;
        final rails = EdgeInsetsDirectional.symmetric(
          horizontal: tokens.gutter,
        );
        KitAction? primary;
        if (state == PhoneNodeState.running &&
            _ranHere &&
            !_handedOver &&
            node.pairedHere) {
          _handedOver = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            unawaited(
              Navigator.of(context).pushReplacement<void, void>(
                KitPageRoute<void>(
                  builder: (_) => const FactsBookCaptureScreen(),
                ),
              ),
            );
          });
        }
        if (canRun) {
          primary = KitAction(
            key: const ValueKey('factsbook-node-run'),
            label: l10n.fbNodeRun,
            icon: AppIconography.database,
            working: working,
            onPressed: working
                ? null
                : () {
                    setState(() => _ranHere = true);
                    unawaited(node.runHere());
                  },
          );
        } else if (canStart) {
          primary = KitAction(
            key: const ValueKey('factsbook-node-start'),
            label: l10n.fbNodeStart,
            icon: AppIconography.play,
            working: working,
            onPressed: working
                ? null
                : () {
                    setState(() => _ranHere = true);
                    unawaited(node.start());
                  },
          );
        } else if (state == PhoneNodeState.running) {
          primary = KitAction(
            key: const ValueKey('factsbook-node-open'),
            label: l10n.fbNodeOpen,
            onPressed: () => unawaited(openFactsBookCapture(context)),
          );
        } else if (state == PhoneNodeState.linuxNotSetUp) {
          primary = KitAction(
            key: const ValueKey('factsbook-node-setup'),
            label: l10n.fbNodeLinuxAction,
            onPressed: () => unawaited(openPhoneSetupStart(context)),
          );
        }
        return KitScreen(
          topBar: KitTopBar(title: l10n.fbNodeTitle),
          width: KitScreenWidth.reading,
          loading: working,
          loadingLabel: title,
          body: ListView(
            padding: EdgeInsetsDirectional.only(
              top: tokens.space2,
              bottom: KitScreen.endPadding(context),
            ),
            children: [
              if (_notice != null)
                Padding(
                  padding: rails.add(
                    EdgeInsetsDirectional.only(bottom: tokens.space3),
                  ),
                  child: KitNotice(
                    key: const ValueKey('factsbook-node-notice'),
                    icon: AppIconography.check,
                    message: _notice!,
                    onDismiss: () => setState(() => _notice = null),
                    dismissLabel: l10n.fbDismiss,
                  ),
                ),
              Padding(
                padding: rails.add(
                  EdgeInsetsDirectional.only(bottom: tokens.space2),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: tokens.space1,
                  children: [
                    KitText(
                      l10n.fbNodeWhatTitle,
                      role: KitTextRole.label,
                      tone: KitTextTone.secondary,
                    ),
                    KitText(
                      l10n.fbNodeWhatBody,
                      key: const ValueKey('factsbook-node-what'),
                      role: KitTextRole.secondary,
                      tone: KitTextTone.secondary,
                    ),
                  ],
                ),
              ),
              KitStateView(
                key: ValueKey('factsbook-node-${state.name}'),
                icon: icon,
                title: title,
                body: body,
                size: KitStateSize.inline,
              ),
              if (installed &&
                  state != PhoneNodeState.removing &&
                  state != PhoneNodeState.installing)
                KitRowGroup(
                  leadingIcons: false,
                  children: [
                    KitRow(
                      key: const ValueKey('factsbook-node-address'),
                      title: l10n.fbNodeAddress,
                      supporting: TextSpan(text: l10n.fbNodeAddressValue),
                    ),
                  ],
                ),
              if (installed &&
                  !working &&
                  (state == PhoneNodeState.running ||
                      state == PhoneNodeState.stopped ||
                      state == PhoneNodeState.failed))
                Padding(
                  padding: rails.add(
                    EdgeInsetsDirectional.only(top: tokens.space3),
                  ),
                  child: Wrap(
                    spacing: tokens.space2,
                    runSpacing: tokens.space2,
                    children: [
                      if (state == PhoneNodeState.running) ...[
                        KitButton.fromAction(
                          KitAction(
                            key: const ValueKey('factsbook-node-stop'),
                            label: l10n.fbNodeStop,
                            icon: AppIconography.pause,
                            onPressed: () => unawaited(node.stop()),
                          ),
                          role: KitButtonRole.secondary,
                          expand: false,
                        ),
                        KitButton.fromAction(
                          KitAction(
                            key: const ValueKey('factsbook-node-restart'),
                            label: l10n.fbNodeRestart,
                            icon: AppIconography.sync,
                            onPressed: () => unawaited(node.restart()),
                          ),
                          role: KitButtonRole.secondary,
                          expand: false,
                        ),
                      ],
                    ],
                  ),
                ),
              if (!working)
                Padding(
                  padding: rails.add(
                    EdgeInsetsDirectional.only(top: tokens.space3),
                  ),
                  child: KitDetailsFold(
                    foldKey: const ValueKey('factsbook-node-details'),
                    text: state == PhoneNodeState.failed ? node.failure : null,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: tokens.space2,
                      children: [
                        if (installed) ...[
                          KitButton.fromAction(
                            KitAction(
                              key: const ValueKey('factsbook-node-remove'),
                              label: l10n.fbNodeRemove,
                              icon: AppIconography.delete,
                              destructive: true,
                              onPressed: () => unawaited(_remove()),
                            ),
                            role: KitButtonRole.secondary,
                            expand: false,
                          ),
                          if (_log == null)
                            KitButton.fromAction(
                              KitAction(
                                key: const ValueKey('factsbook-node-log'),
                                label: l10n.fbNodeLog,
                                onPressed: () => unawaited(_showLog()),
                              ),
                              role: KitButtonRole.tertiary,
                              expand: false,
                            )
                          else
                            KitText(
                              _log!.isEmpty ? '-' : _log!,
                              key: const ValueKey('factsbook-node-log-text'),
                              role: KitTextRole.mono,
                            ),
                        ],
                        KitText(
                          l10n.fbNodeOwnServerBody,
                          role: KitTextRole.secondary,
                          tone: KitTextTone.secondary,
                        ),
                        KitButton.fromAction(
                          KitAction(
                            key: const ValueKey('factsbook-node-own-server'),
                            label: l10n.fbNodeOwnServer,
                            icon: AppIconography.link,
                            onPressed: () =>
                                unawaited(openFactsBookConnect(context)),
                          ),
                          role: KitButtonRole.tertiary,
                          expand: false,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          bottom: primary == null ? null : KitActionBlock(primary: primary),
        );
      },
    );
  }
}
