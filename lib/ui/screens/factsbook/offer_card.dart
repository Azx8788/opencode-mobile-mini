import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/factsbook/factsbook_trigger_types.dart';
import '../../../domain/factsbook/factsbook_types.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/factsbook/factsbook_controller.dart';
import '../../../state/factsbook/factsbook_triggers.dart';
import '../../app_iconography.dart';
import '../../kit/kit.dart';
import '../chats/new_chat_screen.dart';
import 'factsbook_text.dart';
import 'trigger_text.dart';

/// "Talk about this with your agent?" (spec 44, Conversation offer): a card
/// with the offer's short summary, where it came from, and two answers. Yes
/// opens a new chat whose first words are that summary and nothing else; the
/// original message never leaves the node. Not now dismisses the offer. An
/// offer that changed or ran out is refreshed and said so; a start the node
/// could not confirm is never tried again by itself.
class FactsBookOfferCard extends ConsumerStatefulWidget {
  const FactsBookOfferCard({super.key, required this.offer});

  final ConversationOffer offer;

  @override
  ConsumerState<FactsBookOfferCard> createState() => _FactsBookOfferCardState();
}

class _FactsBookOfferCardState extends ConsumerState<FactsBookOfferCard> {
  bool _working = false;
  String? _notice;

  Future<void> _talk() async {
    final l10n = AppLocalizations.of(context);
    final triggers = ref.read(factsBookControllerProvider).triggers;
    final offer = widget.offer;
    setState(() {
      _working = true;
      _notice = null;
    });
    StartReceipt receipt;
    try {
      receipt = await triggers.acceptOffer(offer);
    } on FactsBookException catch (failure) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _notice = failure.stale
            ? l10n.fbOfferStale
            : failureWords(l10n, failure);
      });
      return;
    }
    if (!mounted) return;
    setState(() => _working = false);
    // Accepting is not a start: the node waits (at most 15 minutes) for this
    // phone to say the first message was sent. Anything else is reported as
    // it is, and never tried again.
    if (receipt.status != StartStatus.pending) {
      setState(() => _notice = l10n.fbOfferUnknown);
      return;
    }
    var sent = false;
    await showNewChat(
      context,
      initialText: offerChatSeed(offer, leadIn: l10n.fbOfferChatLead),
      onSent: () {
        sent = true;
        unawaited(
          triggers.reportOffer(offer, receipt, OfferReport.firstMessageSent),
        );
      },
    );
    if (!sent) {
      unawaited(triggers.reportOffer(offer, receipt, OfferReport.cancelled));
    }
  }

  Future<void> _notNow() async {
    final l10n = AppLocalizations.of(context);
    final triggers = ref.read(factsBookControllerProvider).triggers;
    setState(() {
      _working = true;
      _notice = null;
    });
    try {
      await triggers.cancelOffer(widget.offer);
    } on FactsBookException catch (failure) {
      if (!mounted) return;
      setState(
        () => _notice = failure.stale
            ? l10n.fbOfferStale
            : failureWords(l10n, failure),
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final triggers = ref.watch(factsBookControllerProvider).triggers;
    final offer = widget.offer;
    final event = triggers.eventById(offer.eventId);
    final rule = triggers.ruleById(triggers.firingRuleId(offer.firingId) ?? '');
    final source = event == null
        ? null
        : l10n.fbOfferSource(
            sourceKindWords(l10n, event.source.kind).toLowerCase(),
            KitFactRow.dateOf(context, event.capturedAt),
          );
    return Padding(
      padding: EdgeInsetsDirectional.symmetric(
        horizontal: tokens.gutter,
        vertical: tokens.space2,
      ),
      child: KitPanel(
        key: ValueKey('factsbook-offer-card-${offer.id}'),
        title: l10n.fbOfferTitle,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: tokens.space2,
          children: [
            if (rule != null)
              KitText(
                l10n.fbOfferFromRule(bidiName(context, rule.definition.name)),
                role: KitTextRole.caption,
                tone: KitTextTone.secondary,
              ),
            KitText(bidiName(context, offer.summary), role: KitTextRole.body),
            if (source != null)
              KitText(
                source,
                role: KitTextRole.caption,
                tone: KitTextTone.secondary,
              ),
            KitText(
              l10n.fbOfferExplain,
              role: KitTextRole.caption,
              tone: KitTextTone.secondary,
            ),
            if (_notice != null)
              KitNotice(
                key: ValueKey('factsbook-offer-notice-${offer.id}'),
                icon: AppIconography.info,
                message: _notice!,
                onDismiss: () => setState(() => _notice = null),
                dismissLabel: l10n.fbDismiss,
              ),
            Wrap(
              spacing: tokens.space2,
              runSpacing: tokens.space2,
              children: [
                KitButton.fromAction(
                  KitAction(
                    key: ValueKey('factsbook-offer-talk-${offer.id}'),
                    label: l10n.fbOfferTalk,
                    icon: AppIconography.chat,
                    working: _working,
                    onPressed: _working ? null : () => unawaited(_talk()),
                  ),
                  // The page has its own one primary (New rule, or Add);
                  // the two answers are equals.
                  role: KitButtonRole.secondary,
                  expand: false,
                ),
                KitButton.fromAction(
                  KitAction(
                    key: ValueKey('factsbook-offer-later-${offer.id}'),
                    label: l10n.fbOfferNotNow,
                    onPressed: _working ? null : () => unawaited(_notNow()),
                  ),
                  role: KitButtonRole.tertiary,
                  expand: false,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
