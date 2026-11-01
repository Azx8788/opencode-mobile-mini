import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/factsbook/factsbook_capabilities.dart';
import '../../../domain/factsbook/factsbook_trigger_types.dart';
import '../../../domain/factsbook/factsbook_types.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/factsbook/factsbook_controller.dart';
import '../../app_iconography.dart';
import '../../kit/kit.dart';
import 'factsbook_routes.dart';
import 'factsbook_text.dart';
import 'offer_card.dart';
import 'reminder_check_sheet.dart';
import 'trigger_text.dart';

/// Needs you (spec 60 screens 24 and 25, D23): the one place for everything
/// that waits for the person. Changes FactsBook proposes wait here with
/// Approve and Reject on the card, and Edit and Skip a tap away; chat offers
/// from triggers and notes not saved yet are sections of the same page. A
/// decision
/// is signed by this phone's owner key and bound to the exact proposal; one
/// that changed since fails visibly as stale and the page shows the new
/// version. Nothing is applied by looking.
class FactsBookMemoryCareScreen extends ConsumerStatefulWidget {
  const FactsBookMemoryCareScreen({super.key});

  @override
  ConsumerState<FactsBookMemoryCareScreen> createState() =>
      _FactsBookMemoryCareScreenState();
}

class _FactsBookMemoryCareScreenState
    extends ConsumerState<FactsBookMemoryCareScreen> {
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

  Future<void> _decide(
    ReviewItem item,
    ReviewDecision decision, {
    Map<String, Object?>? edited,
  }) async {
    final l10n = AppLocalizations.of(context);
    final controller = ref.read(factsBookControllerProvider);
    setState(() => _working.add(item.id));
    try {
      await controller.decide(item, decision, edited: edited);
      if (!mounted) return;
      setState(() {
        _noticeIsGood = true;
        _notice = switch (decision) {
          ReviewDecision.approve || ReviewDecision.edit => l10n.fbCareApproved,
          ReviewDecision.reject => l10n.fbCareRejected,
          ReviewDecision.skip => l10n.fbCareSkipped,
        };
      });
    } on FactsBookException catch (failure) {
      if (!mounted) return;
      setState(() {
        _noticeIsGood = false;
        _notice = failure.stale
            ? l10n.fbCareStale
            : failureWords(l10n, failure);
      });
    } finally {
      if (mounted) setState(() => _working.remove(item.id));
    }
  }

  Future<void> _decideProposal(
    ReminderProposal proposal,
    ProposalDecision decision,
  ) async {
    final l10n = AppLocalizations.of(context);
    final controller = ref.read(factsBookControllerProvider);
    setState(() => _working.add(proposal.id));
    try {
      await controller.triggers.decideProposal(proposal, decision);
      if (!mounted) return;
      setState(() {
        _noticeIsGood = true;
        _notice = switch (decision) {
          ProposalDecision.confirm => l10n.fbCareApproved,
          ProposalDecision.reject => l10n.fbCareRejected,
          ProposalDecision.skip => l10n.fbCareSkipped,
        };
      });
    } on FactsBookException catch (failure) {
      if (!mounted) return;
      setState(() {
        _noticeIsGood = false;
        _notice = failure.stale
            ? l10n.fbCareStale
            : failureWords(l10n, failure);
      });
    } finally {
      if (mounted) setState(() => _working.remove(proposal.id));
    }
  }

  /// Changes a proposed reminder through the same check as any reminder, then
  /// asks the node to replace the proposal's preview. It stays proposed
  /// (new revision and digest); confirming is a separate answer.
  Future<void> _editProposal(ReminderProposal proposal) async {
    final l10n = AppLocalizations.of(context);
    final controller = ref.read(factsBookControllerProvider);
    final schedule = proposal.preview.schedule;
    final timing = schedule == null
        ? null
        : ReminderTiming.fromWhen(schedule.when);
    if (schedule == null || timing == null) return;
    final preview = await showFactsBookReminderCheck(
      context,
      controller: controller,
      what: proposal.preview.what,
      timing: timing,
      zone: schedule.zone,
      locale: proposal.preview.locale == 'ar' ? 'ar' : 'en',
      scheduleId: schedule.id,
      area: proposal.area,
    );
    if (preview == null || !mounted) return;
    setState(() => _working.add(proposal.id));
    try {
      await controller.triggers.editProposal(proposal, preview);
      if (!mounted) return;
      setState(() {
        _noticeIsGood = true;
        _notice = l10n.fbCareProposalEdited;
      });
    } on FactsBookException catch (failure) {
      if (!mounted) return;
      setState(() {
        _noticeIsGood = false;
        _notice = failure.stale
            ? l10n.fbCareStale
            : failureWords(l10n, failure);
      });
    } finally {
      if (mounted) setState(() => _working.remove(proposal.id));
    }
  }

  Future<void> _edit(ReviewItem item) async {
    final l10n = AppLocalizations.of(context);
    final field = TextEditingController(text: item.text ?? '');
    final navigator = Navigator.of(context);
    final edited = await showKitSheet<String>(
      context,
      sheetKey: const ValueKey('factsbook-care-edit-sheet'),
      title: l10n.fbCareEditTitle,
      icon: AppIconography.edit,
      body: (context) => KitField(
        fieldKey: const ValueKey('factsbook-care-edit-field'),
        controller: field,
        label: l10n.fbCareEditLabel,
        autofocus: true,
      ),
      primary: KitAction(
        key: const ValueKey('factsbook-care-edit-save'),
        label: l10n.fbCareEditSave,
        onPressed: () => navigator.pop(field.text.trim()),
      ),
    );
    // Not disposed here: the sheet is still closing and reads it.
    if (edited == null || edited.isEmpty || !mounted) return;
    await _decide(
      item,
      ReviewDecision.edit,
      edited: {...item.proposal, 'text': edited},
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(factsBookControllerProvider);
    final l10n = AppLocalizations.of(context);
    controller.session.approvalReason = l10n.fbAuthReason;
    final tokens = KitTokens.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final items = controller.reviewCards;
        final proposals = controller.triggers.proposals;
        final offers = controller.triggers.openOffers();
        final notSaved = controller.needsYou
            .where((i) => i.kind == NeedsYouKind.notSaved)
            .firstOrNull;
        final waiting = controller.needsYouCount;
        final Widget body;
        if (controller.load == FactsBookLoad.failed) {
          body = KitStateView.error(
            key: const ValueKey('factsbook-care-error'),
            title: l10n.fbErrorTitle,
            body: failureWords(l10n, controller.error),
            details: failureDetails(l10n, controller.error),
            retry: KitAction(
              label: l10n.commonRetry,
              onPressed: () => unawaited(controller.refresh()),
            ),
          );
        } else if (controller.load == FactsBookLoad.loading && waiting == 0) {
          body = ListView(
            padding: KitScreen.padding(context),
            children: const [KitSkeletonRows()],
          );
        } else {
          final rails = EdgeInsetsDirectional.symmetric(
            horizontal: tokens.gutter,
          );
          body = KitRefresh(
            onRefresh: controller.refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsetsDirectional.only(
                top: tokens.space2,
                bottom: KitScreen.endPadding(context),
              ),
              children: [
                if (!controller.session.canApprove)
                  Padding(
                    padding: rails.add(
                      EdgeInsetsDirectional.only(bottom: tokens.space3),
                    ),
                    child: KitNotice(
                      key: const ValueKey('factsbook-care-needs-owner'),
                      icon: AppIconography.info,
                      message: l10n.fbCareNeedsOwner,
                      actions: [
                        KitAction(
                          label: l10n.fbCareSetupApproval,
                          onPressed: () =>
                              unawaited(openFactsBookConnect(context)),
                        ),
                      ],
                    ),
                  ),
                if (_notice != null)
                  Padding(
                    padding: rails.add(
                      EdgeInsetsDirectional.only(bottom: tokens.space3),
                    ),
                    child: KitNotice(
                      key: const ValueKey('factsbook-care-notice'),
                      icon: _noticeIsGood
                          ? AppIconography.check
                          : AppIconography.info,
                      message: _notice!,
                      onDismiss: () => setState(() => _notice = null),
                      dismissLabel: l10n.fbDismiss,
                    ),
                  ),
                if (waiting == 0)
                  KitStateView(
                    key: const ValueKey('factsbook-care-empty'),
                    icon: AppIconography.checkCircle,
                    title: l10n.fbNeedsYouNone,
                    body: l10n.fbNeedsYouNoneBody,
                    size: KitStateSize.inline,
                  ),
                if (proposals.isNotEmpty || items.isNotEmpty) ...[
                  KitSectionLabel(
                    l10n.fbCareWaiting(proposals.length + items.length),
                  ),
                  Padding(
                    padding: rails,
                    child: KitText(
                      l10n.fbCareTapHint,
                      role: KitTextRole.caption,
                      tone: KitTextTone.secondary,
                    ),
                  ),
                  for (final proposal in proposals)
                    _proposalCard(context, l10n, tokens, proposal),
                  for (final item in items) _card(context, l10n, tokens, item),
                ],
                if (offers.isNotEmpty) ...[
                  KitSectionLabel(l10n.fbNeedsYouOffers(offers.length)),
                  for (final offer in offers)
                    FactsBookOfferCard(
                      key: ValueKey('factsbook-offer-${offer.id}'),
                      offer: offer,
                    ),
                ],
                if (notSaved != null)
                  KitRowGroup(
                    label: l10n.fbNotSavedTitle,
                    children: [
                      KitRow(
                        key: const ValueKey('factsbook-needs-notSaved'),
                        leading: KitNeedsYou.mark(),
                        title: l10n.fbMemoryNotSaved(notSaved.count),
                        supporting: TextSpan(
                          children: [
                            KitNeedsYou.span(context),
                            TextSpan(text: l10n.fbMemoryNotSavedDetail),
                          ],
                        ),
                        trailing: const KitChevron(),
                        onTap: () => unawaited(openFactsBookNotSaved(context)),
                      ),
                    ],
                  ),
              ],
            ),
          );
        }
        return KitScreen(
          topBar: KitTopBar(
            title: l10n.fbNeedsYouTitle,
            subtitle: waiting == 0 ? null : l10n.fbNeedsYouWaiting(waiting),
          ),
          width: KitScreenWidth.reading,
          loading: controller.load == FactsBookLoad.loading,
          loadingLabel: l10n.fbNeedsYouTitle,
          body: body,
        );
      },
    );
  }

  /// Who suggested it, in the person's words: a rule, the person themself, or
  /// an agent (a suggestion with nothing the person wrote behind it).
  String _sourceLine(
    BuildContext context,
    AppLocalizations l10n,
    ReviewItem item,
    bool fromRule,
  ) {
    if (fromRule) return l10n.fbCareSourceRule;
    if (item.evidence.isEmpty) return l10n.fbCareSourceAgent;
    final evidence = item.evidence.first;
    return KitFactRow.lineOf(
      context,
      provenance: evidence.source == 'note'
          ? KitProvenance.told
          : KitProvenance.seen,
      observedAt: evidence.observedAt,
      source: sourceWords(l10n, evidence.source),
    );
  }

  /// What a tap on a card offers beyond Approve and Reject: Edit, Skip and,
  /// for what a rule suggested, what happened to the message. [edit] is null
  /// when there is nothing to edit.
  Future<void> _more(
    BuildContext context, {
    required String claim,
    required String classLabel,
    VoidCallback? edit,
    required VoidCallback skip,
    String? eventId,
    required bool enabled,
  }) async {
    final l10n = AppLocalizations.of(context);
    final navigator = Navigator.of(context);
    await showKitSheet<void>(
      context,
      sheetKey: const ValueKey('factsbook-care-more-sheet'),
      title: claim,
      subtitle: classLabel,
      body: (sheetContext) => KitRowGroup(
        children: [
          if (edit != null)
            KitRow(
              key: const ValueKey('factsbook-care-more-edit'),
              leading: KitRow.icon(sheetContext, AppIconography.edit),
              title: l10n.fbCareEditNamed(claim),
              titleMaxLines: 2,
              enabled: enabled,
              disabledReason: enabled ? null : l10n.fbCareNeedsOwnerShort,
              onTap: () {
                navigator.pop();
                edit();
              },
            ),
          KitRow(
            key: const ValueKey('factsbook-care-more-skip'),
            leading: KitRow.icon(sheetContext, AppIconography.forward),
            title: l10n.fbCareSkipNamed(claim),
            titleMaxLines: 2,
            supporting: TextSpan(text: l10n.fbCareSkipDetail),
            enabled: enabled,
            disabledReason: enabled ? null : l10n.fbCareNeedsOwnerShort,
            onTap: () {
              navigator.pop();
              skip();
            },
          ),
          if (eventId != null)
            KitRow(
              key: const ValueKey('factsbook-care-more-why'),
              leading: KitRow.icon(sheetContext, AppIconography.info),
              title: l10n.fbWhyFired,
              onTap: () {
                navigator.pop();
                unawaited(openFactsBookEvent(context, eventId));
              },
            ),
        ],
      ),
    );
  }

  KitButton _answer({
    required Key key,
    required String label,
    required String named,
    required VoidCallback? onPressed,
    String? reason,
    bool working = false,
    bool destructive = false,
  }) => KitButton.fromAction(
    KitAction(
      key: key,
      label: label,
      semanticsLabel: named,
      working: working,
      onPressed: onPressed,
      disabledReason: reason,
      destructive: destructive,
    ),
    // Every card has both; the page has no one primary.
    role: KitButtonRole.secondary,
    expand: false,
  );

  Widget _card(
    BuildContext context,
    AppLocalizations l10n,
    KitTokens tokens,
    ReviewItem item,
  ) {
    final controller = ref.read(factsBookControllerProvider);
    final busy = _working.contains(item.id);
    final reason = controller.session.canApprove
        ? null
        : l10n.fbCareNeedsOwnerShort;
    final fromRule = controller.triggers.firingOfOutcome(item.id);
    final claim = item.text == null
        ? classWords(l10n, item.reviewClass)
        : bidiName(context, item.text!);
    final classLabel = classWords(l10n, item.reviewClass);
    final enabled = !busy && reason == null;
    return Padding(
      padding: EdgeInsetsDirectional.symmetric(
        horizontal: tokens.gutter,
        vertical: tokens.space2,
      ),
      child: KitPanel(
        key: ValueKey('factsbook-care-${item.id}'),
        title: claim,
        onTap: !enabled
            ? null
            : () => unawaited(
                _more(
                  context,
                  claim: claim,
                  classLabel: classLabel,
                  edit: item.text == null ? null : () => unawaited(_edit(item)),
                  skip: () => unawaited(_decide(item, ReviewDecision.skip)),
                  eventId: fromRule?.eventId,
                  enabled: enabled,
                ),
              ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: tokens.space2,
          children: [
            if (item.text != null)
              KitText(
                classLabel,
                key: ValueKey('factsbook-care-class-${item.id}'),
                role: KitTextRole.caption,
                tone: KitTextTone.secondary,
              ),
            if (item.area.isNotEmpty ||
                item.risk.isNotEmpty ||
                fromRule != null)
              KitChipWrap(
                children: [
                  if (fromRule != null) KitChip(label: l10n.fbTriggerChip),
                  if (item.area.isNotEmpty)
                    KitChip(label: areaWords(l10n, item.area)),
                  for (final risk in item.risk)
                    KitChip(label: riskWords(l10n, risk)),
                ],
              ),
            KitText(
              _sourceLine(context, l10n, item, fromRule != null),
              key: ValueKey('factsbook-care-source-${item.id}'),
              role: KitTextRole.caption,
              tone: KitTextTone.secondary,
            ),
            Wrap(
              spacing: tokens.space2,
              runSpacing: tokens.space2,
              children: [
                _answer(
                  key: ValueKey('factsbook-care-approve-${item.id}'),
                  label: l10n.fbCareApprove,
                  named: l10n.fbCareApproveNamed(claim),
                  working: busy,
                  reason: reason,
                  onPressed: enabled
                      ? () => unawaited(_decide(item, ReviewDecision.approve))
                      : null,
                ),
                _answer(
                  key: ValueKey('factsbook-care-reject-${item.id}'),
                  label: l10n.fbCareReject,
                  named: l10n.fbCareRejectNamed(claim),
                  reason: reason,
                  destructive: true,
                  onPressed: enabled
                      ? () => unawaited(_decide(item, ReviewDecision.reject))
                      : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// A reminder a rule proposes: confirm exactly what is shown or reject it;
  /// a tap on the card changes it (the proposal stays proposed under a new
  /// revision) or skips it.
  Widget _proposalCard(
    BuildContext context,
    AppLocalizations l10n,
    KitTokens tokens,
    ReminderProposal proposal,
  ) {
    final controller = ref.read(factsBookControllerProvider);
    final busy = _working.contains(proposal.id);
    final reason = controller.session.canApprove
        ? null
        : l10n.fbCareNeedsOwnerShort;
    final enabled = !busy && reason == null;
    final at = proposal.preview.at;
    final what = bidiName(context, proposal.preview.what);
    final claim = at == null
        ? what
        : l10n.fbCareProposalWhen(what, whenWords(context, at));
    final canEdit =
        proposal.preview.schedule != null &&
        controller.session.capabilities.supports(
          FactsBookCapabilities.proposalEdit,
        );
    return Padding(
      padding: EdgeInsetsDirectional.symmetric(
        horizontal: tokens.gutter,
        vertical: tokens.space2,
      ),
      child: KitPanel(
        key: ValueKey('factsbook-care-${proposal.id}'),
        title: claim,
        onTap: !enabled
            ? null
            : () => unawaited(
                _more(
                  context,
                  claim: claim,
                  classLabel: classWords(l10n, ReviewClass.reminder),
                  edit: canEdit
                      ? () => unawaited(_editProposal(proposal))
                      : null,
                  skip: () => unawaited(
                    _decideProposal(proposal, ProposalDecision.skip),
                  ),
                  eventId: proposal.eventId,
                  enabled: enabled,
                ),
              ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: tokens.space2,
          children: [
            KitText(
              classWords(l10n, ReviewClass.reminder),
              role: KitTextRole.caption,
              tone: KitTextTone.secondary,
            ),
            KitChipWrap(
              children: [
                KitChip(label: l10n.fbTriggerChip),
                KitChip(label: areaWords(l10n, proposal.area)),
              ],
            ),
            KitText(
              l10n.fbCareSourceRule,
              role: KitTextRole.caption,
              tone: KitTextTone.secondary,
            ),
            Wrap(
              spacing: tokens.space2,
              runSpacing: tokens.space2,
              children: [
                _answer(
                  key: ValueKey('factsbook-care-approve-${proposal.id}'),
                  label: l10n.fbCareApprove,
                  named: l10n.fbCareApproveNamed(claim),
                  working: busy,
                  reason: reason,
                  onPressed: enabled
                      ? () => unawaited(
                          _decideProposal(proposal, ProposalDecision.confirm),
                        )
                      : null,
                ),
                _answer(
                  key: ValueKey('factsbook-care-reject-${proposal.id}'),
                  label: l10n.fbCareReject,
                  named: l10n.fbCareRejectNamed(claim),
                  reason: reason,
                  destructive: true,
                  onPressed: enabled
                      ? () => unawaited(
                          _decideProposal(proposal, ProposalDecision.reject),
                        )
                      : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
