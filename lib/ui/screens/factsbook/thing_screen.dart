import 'dart:async';

import 'package:flutter/material.dart';
import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/factsbook/factsbook_capabilities.dart';
import '../../../domain/factsbook/factsbook_types.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/factsbook/factsbook_controller.dart';
import '../../app_iconography.dart';
import '../../kit/kit.dart';
import 'factsbook_routes.dart';
import 'factsbook_text.dart';
import 'reminder_check_sheet.dart';

/// A thing and its facts (spec 60 screen 14, G7, D25): every fact says who
/// told it, where it was read, or that it was guessed, and when. "Read from
/// a source" never means true: a tap on a fact explains where it came from
/// and that a source can be wrong. The page offers "Add a fact to Sam"
/// and "Remind me about Sam"; a tap on a fact also offers to change it.
/// A fact the person adds or changes waits for their OK in Needs you where
/// the area asks first. There is no way to remove a fact: the node's v1
/// contract has none, so none is offered.
class FactsBookThingScreen extends ConsumerStatefulWidget {
  const FactsBookThingScreen({super.key, required this.thingId});

  final String thingId;

  @override
  ConsumerState<FactsBookThingScreen> createState() =>
      _FactsBookThingScreenState();
}

class _FactsBookThingScreenState extends ConsumerState<FactsBookThingScreen> {
  Thing? _thing;
  Object? _failure;
  bool _loading = true;
  String? _notice;
  bool _seeNeedsYou = false;

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
      final thing = await ref
          .read(factsBookControllerProvider)
          .thing(widget.thingId);
      if (mounted) setState(() => _thing = thing);
    } on FactsBookException catch (failure) {
      if (mounted) setState(() => _failure = failure);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _canWrite => ref
      .read(factsBookControllerProvider)
      .session
      .capabilities
      .supports(FactsBookCapabilities.ownerReview);

  /// One line of text in a sheet, for a new fact or a changed one. Null when
  /// the person leaves it.
  Future<String?> _askLine({
    required String title,
    required String initial,
    required String save,
  }) async {
    final l10n = AppLocalizations.of(context);
    final field = TextEditingController(text: initial);
    final navigator = Navigator.of(context);
    final text = await showKitSheet<String>(
      context,
      sheetKey: const ValueKey('factsbook-thing-line-sheet'),
      title: title,
      icon: AppIconography.edit,
      body: (context) => KitField(
        fieldKey: const ValueKey('factsbook-thing-line-field'),
        controller: field,
        label: l10n.fbCareEditLabel,
        autofocus: true,
        helper: l10n.fbThingOneLine,
      ),
      primary: KitAction(
        key: const ValueKey('factsbook-thing-line-save'),
        label: save,
        onPressed: () => navigator.pop(field.text.trim()),
      ),
    );
    // Not disposed here: the sheet is still closing and reads it.
    if (text == null || text.isEmpty) return null;
    return text.replaceAll(RegExp(r'\s+'), ' ');
  }

  void _said(String message, {bool needsYou = false}) => setState(() {
    _notice = message;
    _seeNeedsYou = needsYou;
  });

  Future<void> _addFact(Thing thing) async {
    final l10n = AppLocalizations.of(context);
    final controller = ref.read(factsBookControllerProvider);
    final text = await _askLine(
      title: l10n.fbThingAddFact(bidiName(context, thing.title)),
      initial: '',
      save: l10n.fbThingAddFactSave,
    );
    if (text == null || !mounted) return;
    try {
      final result = await controller.addFact(thing, text);
      if (!mounted) return;
      _said(
        result.status == 'ok'
            ? l10n.fbCaptureFactAdded(bidiName(context, thing.title))
            : l10n.fbCaptureFactProposed,
        needsYou: result.status != 'ok',
      );
      await _load();
    } on FactsBookException catch (failure) {
      if (mounted) _said(failureWords(l10n, failure));
      if (failure.stale) await _load();
    }
  }

  Future<void> _editFact(Fact fact) async {
    final l10n = AppLocalizations.of(context);
    final controller = ref.read(factsBookControllerProvider);
    final text = await _askLine(
      title: l10n.fbThingEditFact,
      initial: fact.text,
      save: l10n.fbThingEditFactSave,
    );
    if (text == null || text == fact.text || !mounted) return;
    try {
      final result = await controller.editFact(fact, text);
      if (!mounted) return;
      _said(
        result.status == 'ok'
            ? l10n.fbThingFactChanged
            : l10n.fbThingChangeProposed,
        needsYou: result.status != 'ok',
      );
      await _load();
    } on FactsBookException catch (failure) {
      if (mounted) _said(failureWords(l10n, failure));
      if (failure.stale) await _load();
    }
  }

  /// "Remind me about Sam": the same check as any reminder, a one-off
  /// tomorrow morning until the person changes it.
  Future<void> _remind(Thing thing) async {
    final l10n = AppLocalizations.of(context);
    final controller = ref.read(factsBookControllerProvider);
    final app = Localizations.localeOf(context).languageCode;
    final tomorrow = clock.now().add(const Duration(days: 1));
    final preview = await showFactsBookReminderCheck(
      context,
      controller: controller,
      what: thing.title,
      timing: ReminderTiming(
        repeat: ReminderRepeat.never,
        at: DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9),
      ),
      locale: app == 'ar' ? 'ar' : 'en',
      askTitle: true,
      area: thing.area.isEmpty ? 'general' : thing.area,
    );
    if (preview == null || !mounted) return;
    try {
      await controller.createReminder(
        preview,
        floatingConfirmed: preview.zone == 'floating',
      );
      if (mounted) {
        _said(l10n.fbThingReminderMade(bidiName(context, thing.title)));
      }
    } on FactsBookException catch (failure) {
      if (mounted) _said(failureWords(l10n, failure));
    }
  }

  /// A tap on a fact: where it came from, in words, and a way to change it.
  Future<void> _explain(Fact fact) async {
    final l10n = AppLocalizations.of(context);
    final navigator = Navigator.of(context);
    final date = KitFactRow.dateOf(context, fact.observedAt);
    final source = sourceWords(l10n, fact.source);
    final provenance = kitProvenanceOf(fact.provenance);
    final words = switch (provenance) {
      KitProvenance.told => l10n.fbThingExplainTold(date),
      KitProvenance.seen =>
        source == null
            ? l10n.fbThingExplainSeenNoSource(date)
            : l10n.fbThingExplainSeen(source, date),
      KitProvenance.guessed =>
        source == null
            ? l10n.fbThingExplainGuessedNoSource(date)
            : l10n.fbThingExplainGuessed(source, date),
      KitProvenance.calculated => l10n.fbThingExplainCalculated(date),
    };
    final edit = await showKitSheet<bool>(
      context,
      sheetKey: const ValueKey('factsbook-fact-sheet'),
      title: bidiName(context, fact.text),
      icon: AppIconography.info,
      body: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: KitTokens.of(context).space2,
        children: [
          KitText(words, key: const ValueKey('factsbook-fact-explain')),
          if (fact.waitingForOk) KitText(l10n.fbThingExplainWaiting),
        ],
      ),
      primary: _canWrite
          ? KitAction(
              key: const ValueKey('factsbook-fact-edit'),
              label: l10n.fbThingEditFact,
              icon: AppIconography.edit,
              onPressed: () => navigator.pop(true),
            )
          : null,
    );
    if (edit == true && mounted) await _editFact(fact);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final thing = _thing;
    final Widget body;
    if (thing == null && _failure == null) {
      body = ListView(
        padding: KitScreen.padding(context),
        children: const [KitSkeletonRows()],
      );
    } else if (thing == null) {
      body = KitStateView.error(
        key: const ValueKey('factsbook-thing-error'),
        title: l10n.fbErrorTitle,
        body: failureWords(l10n, _failure),
        details: failureDetails(l10n, _failure),
        retry: KitAction(
          label: l10n.commonRetry,
          onPressed: () => unawaited(_load()),
        ),
      );
    } else {
      body = _facts(context, l10n, tokens, thing);
    }
    return KitScreen(
      topBar: KitTopBar(
        title: thing == null ? '' : bidiName(context, thing.title),
        subtitle: thing == null
            ? null
            : [
                kindWords(l10n, thing.kind),
                if (thing.area.isNotEmpty) areaWords(l10n, thing.area),
              ].join(' · '),
      ),
      width: KitScreenWidth.reading,
      loading: _loading && thing != null,
      loadingLabel: thing?.title ?? '',
      body: body,
    );
  }

  Widget _facts(
    BuildContext context,
    AppLocalizations l10n,
    KitTokens tokens,
    Thing thing,
  ) {
    final rails = EdgeInsetsDirectional.symmetric(horizontal: tokens.gutter);
    return KitRefresh(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsetsDirectional.only(
          top: tokens.space2,
          bottom: KitScreen.endPadding(context),
        ),
        children: [
          if (thing.sensitive)
            Padding(
              padding: rails,
              child: KitNotice(
                icon: AppIconography.locked,
                message: l10n.fbThingLocked,
              ),
            ),
          if (_notice != null)
            Padding(
              padding: rails.add(
                EdgeInsetsDirectional.only(bottom: tokens.space3),
              ),
              child: KitNotice(
                key: const ValueKey('factsbook-thing-notice'),
                icon: AppIconography.check,
                message: _notice!,
                actions: [
                  if (_seeNeedsYou)
                    KitAction(
                      key: const ValueKey('factsbook-thing-see-needs-you'),
                      label: l10n.fbCaptureSeeNeedsYou,
                      onPressed: () =>
                          unawaited(openFactsBookNeedsYou(context)),
                    ),
                ],
                onDismiss: () => setState(() => _notice = null),
                dismissLabel: l10n.fbDismiss,
              ),
            ),
          KitRowGroup(
            key: const ValueKey('factsbook-thing-actions'),
            children: [
              if (_canWrite)
                KitRow(
                  key: const ValueKey('factsbook-thing-add-fact'),
                  leading: KitRow.badge(
                    context,
                    AppIconography.add,
                    accent: true,
                  ),
                  title: l10n.fbThingAddFact(bidiName(context, thing.title)),
                  titleAccent: true,
                  titleMaxLines: 2,
                  trailing: const KitChevron(),
                  onTap: () => unawaited(_addFact(thing)),
                ),
              if (ref
                  .read(factsBookControllerProvider)
                  .session
                  .capabilities
                  .supports(FactsBookCapabilities.reminders))
                KitRow(
                  key: const ValueKey('factsbook-thing-remind'),
                  leading: KitRow.icon(context, AppIconography.clock),
                  title: l10n.fbThingRemind(bidiName(context, thing.title)),
                  titleMaxLines: 2,
                  trailing: const KitChevron(),
                  onTap: () => unawaited(_remind(thing)),
                ),
            ],
          ),
          Padding(
            padding: EdgeInsetsDirectional.only(top: tokens.space2),
            child: KitSectionLabel(l10n.fbThingFacts),
          ),
          if (thing.facts.isEmpty)
            Padding(
              padding: rails,
              child: KitText(l10n.fbThingNoFacts, tone: KitTextTone.secondary),
            ),
          for (final fact in thing.facts) ...[
            KitFactRow(
              key: ValueKey('factsbook-fact-${fact.id}'),
              text: fact.text,
              provenance: kitProvenanceOf(fact.provenance),
              source: sourceWords(l10n, fact.source),
              observedAt: fact.observedAt,
              waitingForOk: fact.waitingForOk,
              open: () => unawaited(_explain(fact)),
            ),
            // An edited fact keeps where the original was read: the node
            // retains that evidence through edits, and so does the page.
            for (final evidence in fact.support)
              Padding(
                padding: EdgeInsetsDirectional.only(
                  start: tokens.gutter + tokens.space4,
                  end: tokens.gutter,
                  bottom: tokens.space1,
                ),
                child: KitText(
                  l10n.fbThingOriginally(
                    sourceWords(l10n, evidence.source) ?? l10n.fbSourceOther,
                    KitFactRow.dateOf(context, evidence.observedAt),
                  ),
                  key: ValueKey('factsbook-support-${fact.id}'),
                  role: KitTextRole.caption,
                  tone: KitTextTone.secondary,
                ),
              ),
          ],
          if (thing.facts.any((f) => f.waitingForOk))
            KitGroupNote(message: l10n.fbThingWaitingNote),
          if (thing.facts.isNotEmpty)
            KitGroupNote(message: l10n.fbThingTapHint),
        ],
      ),
    );
  }
}
