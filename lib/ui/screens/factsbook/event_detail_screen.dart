import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/factsbook/factsbook_trigger_types.dart';
import '../../../domain/factsbook/factsbook_types.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/factsbook/factsbook_controller.dart';
import '../../app_iconography.dart';
import '../../kit/kit.dart';
import 'factsbook_text.dart';
import 'trigger_text.dart';

/// Event detail, "What happened to this message" (spec 44): the outcome
/// first (what was suggested, or the one reason nothing was), then the rule
/// that matched and where the message came from.
/// The node returns metadata only, so the original text is never shown, and
/// the sender and app are labelled as claims. What was found comes from the
/// proposals and offers the rule made, never from the message itself.
class FactsBookEventScreen extends ConsumerStatefulWidget {
  const FactsBookEventScreen({super.key, required this.eventId});

  final String eventId;

  @override
  ConsumerState<FactsBookEventScreen> createState() =>
      _FactsBookEventScreenState();
}

class _FactsBookEventScreenState extends ConsumerState<FactsBookEventScreen> {
  TriggerEvent? _event;
  Object? _failure;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final triggers = ref.read(factsBookControllerProvider).triggers;
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      // The lists carry the event; read them again so a fresh one shows.
      await triggers.refresh(quiet: true);
      final event = triggers.eventById(widget.eventId);
      if (!mounted) return;
      setState(() {
        _event = event;
        if (event == null) {
          _failure = const FactsBookException('not_found', status: 404);
        }
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final controller = ref.watch(factsBookControllerProvider);
    final event = _event;
    final Widget body;
    if (event == null && _failure == null) {
      body = ListView(
        padding: KitScreen.padding(context),
        children: const [KitSkeletonRows()],
      );
    } else if (event == null) {
      body = KitStateView.error(
        key: const ValueKey('factsbook-event-error'),
        title: l10n.fbErrorTitle,
        body: failureWords(l10n, _failure),
        details: failureDetails(l10n, _failure),
        retry: KitAction(
          label: l10n.commonRetry,
          onPressed: () => unawaited(_load()),
        ),
      );
    } else {
      body = ListenableBuilder(
        listenable: controller,
        builder: (context, _) =>
            _detail(context, l10n, tokens, controller, event),
      );
    }
    return KitScreen(
      topBar: KitTopBar(
        title: l10n.fbEventTitle,
        subtitle: event == null
            ? null
            : l10n.fbEventWhen(
                sourceKindWords(l10n, event.source.kind),
                whenWords(context, event.capturedAt),
              ),
      ),
      width: KitScreenWidth.reading,
      loading: _loading && event != null,
      loadingLabel: l10n.fbEventTitle,
      body: body,
    );
  }

  Widget _detail(
    BuildContext context,
    AppLocalizations l10n,
    KitTokens tokens,
    FactsBookController controller,
    TriggerEvent event,
  ) {
    final triggers = controller.triggers;
    final rails = EdgeInsetsDirectional.symmetric(horizontal: tokens.gutter);
    final firings = triggers.firingsOfEvent(event.id);
    final proposals = [
      for (final p in triggers.proposals)
        if (p.eventId == event.id) p,
    ];
    final offers = [
      for (final o in triggers.offers)
        if (o.eventId == event.id) o,
    ];
    final facts = [
      for (final item in controller.review)
        if (firings.any((f) => f.outcomes.contains(item.id)) &&
            item.text != null)
          item,
    ];
    final collapsed = firings.fold<int>(0, (n, f) => n + f.collapsedCount);
    final claims = event.claims;
    // The outcome comes first and says why once: what was suggested, or the
    // one reason nothing was.
    final proposedLines = <String>[
      for (final p in proposals) _proposalWords(context, l10n, p),
      for (final o in offers)
        if (o.state == OfferState.offered) bidiName(context, o.summary),
      for (final f in facts) bidiName(context, f.text!),
    ];
    final outcome = proposedLines.isEmpty
        ? triggerReasonWords(l10n, event.reason)
        : l10n.fbEventOutcomeProposed(proposedLines.length);
    // Never the outcome's own sentence a second time.
    final aside = <String>[
      if (event.sensitive && event.reason != TriggerReason.sensitiveUnavailable)
        l10n.fbReasonUncertain,
      if (collapsed > 0) l10n.fbEventCollapsed(collapsed),
    ].where((line) => line != outcome).toList();
    return KitRefresh(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsetsDirectional.only(
          top: tokens.space2,
          bottom: KitScreen.endPadding(context),
        ),
        children: [
          KitRowGroup(
            leadingIcons: false,
            children: [
              KitRow(
                key: const ValueKey('factsbook-event-outcome'),
                title: outcome,
                titleMaxLines: 4,
              ),
            ],
          ),
          if (proposedLines.isNotEmpty)
            KitRowGroup(
              key: const ValueKey('factsbook-event-proposed'),
              label: l10n.fbEventProposed,
              leadingIcons: false,
              children: [
                for (final (i, line) in proposedLines.indexed)
                  KitRow(
                    key: ValueKey('factsbook-event-proposed-$i'),
                    title: line,
                    titleMaxLines: 4,
                    supporting: TextSpan(text: l10n.fbEventWaitingForOk),
                  ),
              ],
            ),
          if (firings.isNotEmpty)
            KitRowGroup(
              label: l10n.fbEventRule,
              leadingIcons: false,
              children: [
                for (final f in firings)
                  KitRow(
                    key: ValueKey('factsbook-event-rule-${f.id}'),
                    title: bidiName(
                      context,
                      triggers.ruleById(f.ruleId)?.definition.name ??
                          templateWords(l10n, f.template.id),
                    ),
                  ),
              ],
            ),
          KitRowGroup(
            label: l10n.fbEventFrom,
            leadingIcons: false,
            children: [
              KitRow(
                key: const ValueKey('factsbook-event-source'),
                title: sourceKindWords(l10n, event.source.kind),
                supporting: TextSpan(
                  text: whenWords(context, event.capturedAt),
                ),
              ),
              if (claims.sender != null)
                KitRow(
                  key: const ValueKey('factsbook-event-sender'),
                  title: l10n.fbEventSender,
                  supporting: TextSpan(text: bidiName(context, claims.sender!)),
                ),
              if (claims.app != null)
                KitRow(
                  key: const ValueKey('factsbook-event-app'),
                  title: l10n.fbEventApp,
                  supporting: TextSpan(text: bidiName(context, claims.app!)),
                ),
              KitRow(
                key: const ValueKey('factsbook-event-trust'),
                title: l10n.fbEventTrust,
                supporting: TextSpan(text: trustWords(l10n, event.trust)),
              ),
            ],
          ),
          if (aside.isNotEmpty)
            KitRowGroup(
              label: l10n.fbEventIgnored,
              leadingIcons: false,
              children: [
                for (final (i, line) in aside.indexed)
                  KitRow(
                    key: ValueKey('factsbook-event-ignored-$i'),
                    title: line,
                    titleMaxLines: 4,
                  ),
              ],
            ),
          if (event.trust != EventTrust.userAuthored)
            Padding(
              padding: rails.add(
                EdgeInsetsDirectional.only(top: tokens.space3),
              ),
              child: KitNotice(
                key: const ValueKey('factsbook-event-unverified'),
                icon: AppIconography.shield,
                message: l10n.fbEventUnverified,
              ),
            ),
          KitGroupNote(message: l10n.fbEventFootnote),
        ],
      ),
    );
  }

  String _proposalWords(
    BuildContext context,
    AppLocalizations l10n,
    ReminderProposal proposal,
  ) {
    final at = proposal.preview.at;
    final what = bidiName(context, proposal.preview.what);
    return at == null
        ? what
        : l10n.fbCareProposalWhen(what, whenWords(context, at));
  }
}
