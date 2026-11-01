import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/factsbook/factsbook_capabilities.dart';
import '../../../domain/factsbook/factsbook_types.dart';
import '../../../domain/relative_age.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/factsbook/factsbook_controller.dart';
import '../../app_theme.dart';
import '../../kit/kit.dart';
import 'factsbook_text.dart';

/// Not saved yet (spec 60 screen 19, G29, D25, D32): captures that could not
/// be saved stay on this phone until the person discards them. Each says why
/// and offers Try now, Copy text and Discard; from day 30 the page asks Retry,
/// Export or Discard. Nothing here is ever dropped on its own.
class FactsBookNotSavedScreen extends ConsumerStatefulWidget {
  const FactsBookNotSavedScreen({super.key});

  @override
  ConsumerState<FactsBookNotSavedScreen> createState() =>
      _FactsBookNotSavedScreenState();
}

class _FactsBookNotSavedScreenState
    extends ConsumerState<FactsBookNotSavedScreen> {
  final _working = <String>{};
  String? _notice;
  bool _noticeIsGood = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(factsBookControllerProvider).refresh());
    });
  }

  Future<void> _retry(CouldNotSaveEntry entry) async {
    final l10n = AppLocalizations.of(context);
    final controller = ref.read(factsBookControllerProvider);
    setState(() => _working.add(entry.id));
    try {
      final saved = await controller.retry(entry);
      if (!mounted) return;
      setState(() {
        _noticeIsGood = saved;
        _notice = _noticeIsGood ? l10n.fbNotSavedSaved : l10n.fbNotSavedStill;
      });
    } on FactsBookException catch (failure) {
      if (!mounted) return;
      setState(() {
        _noticeIsGood = false;
        // Not reaching the node is "still not saved"; anything else is said
        // in its own words.
        _notice = failure.unreachable
            ? l10n.fbNotSavedStill
            : failureWords(l10n, failure);
      });
    } finally {
      if (mounted) setState(() => _working.remove(entry.id));
    }
  }

  /// Exports a note the node holds as the encrypted object it hands back: it
  /// does not unlock the locked folder, and opening it needs the original
  /// local recovery credentials, which the sheet says.
  Future<void> _export(CouldNotSaveEntry entry) async {
    final l10n = AppLocalizations.of(context);
    final controller = ref.read(factsBookControllerProvider);
    setState(() => _working.add(entry.id));
    try {
      final export = await controller.exportCapture(entry.id);
      if (!mounted) return;
      await showKitSheet<void>(
        context,
        sheetKey: const ValueKey('factsbook-export-sheet'),
        title: l10n.fbExportTitle,
        icon: AppIconography.upload,
        body: (context) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: KitTokens.of(context).space3,
          children: [
            KitText(l10n.fbExportBody, role: KitTextRole.secondary),
            KitDetailsFold(
              foldKey: const ValueKey('factsbook-export-object'),
              label: l10n.fbExportObject,
              values: [KitTechnicalValue(l10n.fbExportObject, export.text)],
            ),
          ],
        ),
        primary: KitAction.copy(
          key: const ValueKey('factsbook-export-copy'),
          label: l10n.fbExportCopy,
          text: () => export.text,
          redact: false,
        ),
      );
    } on FactsBookException catch (failure) {
      if (mounted) {
        setState(() {
          _noticeIsGood = false;
          _notice = failureWords(l10n, failure);
        });
      }
    } finally {
      if (mounted) setState(() => _working.remove(entry.id));
    }
  }

  Future<void> _discard(CouldNotSaveEntry entry) async {
    final l10n = AppLocalizations.of(context);
    final controller = ref.read(factsBookControllerProvider);
    final yes = await showKitConfirm(
      context,
      title: l10n.fbNotSavedDiscardTitle,
      body: entry.onPhone
          ? l10n.fbNotSavedDiscardBody
          : l10n.fbNotSavedDiscardBodyNode,
      confirmLabel: l10n.fbNotSavedDiscard,
      kind: KitConfirmKind.destructive,
      confirmKey: ValueKey('factsbook-discard-confirm-${entry.id}'),
    );
    if (!yes || !mounted) return;
    setState(() => _working.add(entry.id));
    try {
      await controller.discard(entry);
    } on FactsBookException catch (failure) {
      if (mounted) {
        setState(() {
          _noticeIsGood = false;
          _notice = failureWords(l10n, failure);
        });
      }
    } finally {
      if (mounted) setState(() => _working.remove(entry.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(factsBookControllerProvider);
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final entries = controller.pending;
        return KitScreen(
          topBar: KitTopBar(
            title: l10n.fbNotSavedTitle,
            subtitle: entries.isEmpty
                ? null
                : l10n.fbNotSavedCount(entries.length),
          ),
          width: KitScreenWidth.reading,
          loading: controller.load == FactsBookLoad.loading,
          loadingLabel: l10n.fbNotSavedTitle,
          body: _body(context, l10n, controller),
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    FactsBookController controller,
  ) {
    final tokens = KitTokens.of(context);
    // Notes kept on this phone show even when the node cannot be reached:
    // they are exactly what the person needs to see then.
    if (controller.load == FactsBookLoad.failed && controller.pending.isEmpty) {
      return KitStateView.error(
        key: const ValueKey('factsbook-notsaved-error'),
        title: l10n.fbErrorTitle,
        body: failureWords(l10n, controller.error),
        details: failureDetails(l10n, controller.error),
        retry: KitAction(
          label: l10n.commonRetry,
          onPressed: () => unawaited(controller.refresh()),
        ),
      );
    }
    final entries = controller.pending;
    if (entries.isEmpty) {
      return ListView(
        children: [
          KitStateView(
            key: const ValueKey('factsbook-notsaved-empty'),
            icon: AppIconography.checkCircle,
            title: l10n.fbNotSavedEmptyTitle,
            body: l10n.fbNotSavedEmptyBody,
          ),
        ],
      );
    }
    final now = clock.now();
    final rails = EdgeInsetsDirectional.symmetric(horizontal: tokens.gutter);
    return KitRefresh(
      onRefresh: controller.refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsetsDirectional.only(
          top: tokens.space2,
          bottom: KitScreen.endPadding(context),
        ),
        children: [
          Padding(
            padding: rails,
            child: KitText(
              l10n.fbNotSavedIntro,
              role: KitTextRole.secondary,
              tone: KitTextTone.secondary,
            ),
          ),
          if (controller.load == FactsBookLoad.failed)
            Padding(
              padding: rails.add(
                EdgeInsetsDirectional.only(top: tokens.space3),
              ),
              child: KitNotice(
                key: const ValueKey('factsbook-notsaved-unreachable'),
                icon: AppIconography.info,
                message: failureWords(l10n, controller.error),
              ),
            ),
          if (_notice != null)
            Padding(
              padding: rails.add(
                EdgeInsetsDirectional.only(top: tokens.space3),
              ),
              child: KitNotice(
                key: const ValueKey('factsbook-notsaved-notice'),
                tone: _noticeIsGood ? AppStatusTone.ok : AppStatusTone.neutral,
                icon: _noticeIsGood
                    ? AppIconography.check
                    : AppIconography.info,
                message: _notice!,
                onDismiss: () => setState(() => _notice = null),
                dismissLabel: l10n.fbDismiss,
              ),
            ),
          KitRowGroup(
            leadingIcons: false,
            gapBefore: tokens.space3,
            children: [
              for (final entry in entries) _entry(context, l10n, entry, now),
            ],
          ),
          KitGroupNote(message: l10n.fbNotSavedFooter),
        ],
      ),
    );
  }

  Widget _entry(
    BuildContext context,
    AppLocalizations l10n,
    CouldNotSaveEntry entry,
    DateTime now,
  ) {
    final tokens = KitTokens.of(context);
    final text = entry.text;
    final due = entry.needsThirtyDayPrompt(now);
    final working = _working.contains(entry.id);
    final age = relativeAgeLabel(
      now.difference(entry.createdAt),
      at: entry.createdAt,
      l10n: l10n,
    );
    return KitRow(
      key: ValueKey('factsbook-notsaved-${entry.id}'),
      title: text == null ? l10n.fbNotSavedNodeItem : bidiName(context, text),
      titleMaxLines: 3,
      supporting: TextSpan(
        text:
            '${reasonWords(l10n, entry, canUnlock: !ref.read(factsBookControllerProvider).session.capabilities.isDisabled(FactsBookCapabilities.sensitiveUnlock))} · '
            '${entry.onPhone ? l10n.fbNotSavedOnPhone : l10n.fbNotSavedAtNode} · '
            '${l10n.fbNotSavedSince(age)}',
      ),
      supportingMaxLines: 4,
      below: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.space2,
        children: [
          if (due)
            KitNotice(
              key: ValueKey('factsbook-notsaved-30-${entry.id}'),
              icon: AppIconography.clock,
              message: l10n.fbNotSavedThirtyDays,
            ),
          Wrap(
            spacing: tokens.space2,
            runSpacing: tokens.space2,
            children: [
              KitButton.secondary(
                key: ValueKey('factsbook-retry-${entry.id}'),
                label: due ? l10n.fbNotSavedRetry : l10n.fbNotSavedTryNow,
                expand: false,
                working: working,
                onPressed: working ? null : () => unawaited(_retry(entry)),
              ),
              if (text != null)
                KitButton.fromAction(
                  KitAction.copy(
                    key: ValueKey('factsbook-copy-${entry.id}'),
                    label: due ? l10n.fbNotSavedExport : l10n.fbNotSavedCopy,
                    text: () => text,
                    redact: false,
                  ),
                  role: KitButtonRole.secondary,
                  expand: false,
                ),
              if (!entry.onPhone &&
                  ref
                      .read(factsBookControllerProvider)
                      .session
                      .capabilities
                      .supports(FactsBookCapabilities.encryptedExport))
                KitButton.secondary(
                  key: ValueKey('factsbook-export-${entry.id}'),
                  label: l10n.fbNotSavedExport,
                  expand: false,
                  working: working,
                  onPressed: working ? null : () => unawaited(_export(entry)),
                ),
              KitButton.tertiary(
                key: ValueKey('factsbook-discard-${entry.id}'),
                label: l10n.fbNotSavedDiscard,
                destructive: true,
                onPressed: working ? null : () => unawaited(_discard(entry)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
