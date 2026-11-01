import 'package:flutter/widgets.dart';

import '../../../domain/factsbook/factsbook_trigger_types.dart';
import '../../../l10n/app_localizations.dart';
import '../../kit/kit.dart';

/// The app's words for trigger values (spec 44). Plain words only: no ids,
/// no codes; technical detail goes under Details.

String sourceKindWords(AppLocalizations l10n, TriggerSourceKind kind) =>
    switch (kind) {
      TriggerSourceKind.share => l10n.fbSourceGroupShare,
      TriggerSourceKind.chatSelection => l10n.fbSourceGroupChat,
      TriggerSourceKind.note => l10n.fbSourceGroupNote,
    };

String sourceGroupWords(
  AppLocalizations l10n,
  TriggerSourceKind kind,
  int count,
) => switch (kind) {
  TriggerSourceKind.share => l10n.fbTriggersGroupShare(count),
  TriggerSourceKind.chatSelection => l10n.fbTriggersGroupChat(count),
  TriggerSourceKind.note => l10n.fbTriggersGroupNote(count),
};

String templateWords(AppLocalizations l10n, TriggerTemplateId id) =>
    switch (id) {
      TriggerTemplateId.appointment => l10n.fbTemplateAppointment,
      TriggerTemplateId.delivery => l10n.fbTemplateDelivery,
      TriggerTemplateId.booking => l10n.fbTemplateBooking,
      TriggerTemplateId.subscription => l10n.fbTemplateSubscription,
      TriggerTemplateId.billDue => l10n.fbTemplateBill,
    };

String outcomeWords(AppLocalizations l10n, TriggerOutcomeKind kind) =>
    switch (kind) {
      TriggerOutcomeKind.reminder => l10n.fbOutcomeReminder,
      TriggerOutcomeKind.fact => l10n.fbOutcomeFact,
      TriggerOutcomeKind.conversation => l10n.fbOutcomeConversation,
    };

String outcomesLine(AppLocalizations l10n, Iterable<TriggerOutcome> outcomes) =>
    outcomes.map((o) => outcomeWords(l10n, o.kind)).join(', ');

/// "Looks for an appointment → propose a reminder, offer to talk about it".
String ruleLine(AppLocalizations l10n, RuleDefinition rule) => l10n.fbRuleFinds(
  templateWords(l10n, rule.template.id),
  outcomesLine(l10n, rule.outcomes),
);

String triggerReasonWords(AppLocalizations l10n, TriggerReason reason) =>
    switch (reason) {
      TriggerReason.matched => l10n.fbReasonMatched,
      TriggerReason.noMatch => l10n.fbReasonNoMatch,
      TriggerReason.uncertain => l10n.fbReasonUncertain,
      TriggerReason.sensitiveUnavailable => l10n.fbReasonSensitive,
      TriggerReason.sourceCap => l10n.fbReasonSourceCap,
      TriggerReason.vaultCap => l10n.fbReasonVaultCap,
      TriggerReason.ruleCap => l10n.fbReasonRuleCap,
      TriggerReason.stormCollapsed => l10n.fbReasonStorm,
      TriggerReason.noEnabledRule => l10n.fbReasonNoRule,
      TriggerReason.targetStale => l10n.fbReasonTargetStale,
      TriggerReason.targetMissing ||
      TriggerReason.targetDenied => l10n.fbReasonTargetGone,
      TriggerReason.rejected => l10n.fbReasonRejectedEvent,
    };

String trustWords(AppLocalizations l10n, EventTrust trust) => switch (trust) {
  EventTrust.userAuthored => l10n.fbTrustAuthored,
  EventTrust.userSelected => l10n.fbTrustSelected,
  EventTrust.thirdPartyUntrusted => l10n.fbTrustUntrusted,
};

String problemWords(AppLocalizations l10n, RuleProblem problem) =>
    switch (problem) {
      RuleProblem.nameEmpty ||
      RuleProblem.nameTooLong => l10n.fbRuleProblemName,
      RuleProblem.tooManyWords ||
      RuleProblem.wordEmpty ||
      RuleProblem.wordTooLong => l10n.fbRuleProblemWords,
      RuleProblem.noOutcome => l10n.fbRuleProblemOutcome,
      RuleProblem.templateUnavailable => l10n.fbRuleProblemTemplate,
      RuleProblem.limitOutOfRange => l10n.fbRuleProblemLimit,
      RuleProblem.senderClaimInvalid => l10n.fbRuleProblemSender,
    };

/// A date and time the way the rest of FactsBook words them.
String whenWords(BuildContext context, DateTime at) =>
    '${KitFactRow.dateOf(context, at)}, ${KitTime.clock(context, at)}';

/// The local ISO text a test or a proposal gives (`2026-10-15T09:00`) as a
/// date and time in words; the text itself when it cannot be read.
String isoWhenWords(BuildContext context, String iso) {
  final at = DateTime.tryParse(iso);
  return at == null ? iso : whenWords(context, at);
}

/// A language-appropriate example line the node's version-1 grammar reads.
String sampleExample(TriggerTemplate template, DateTime from) {
  String two(int n) => n.toString().padLeft(2, '0');
  final at = from.add(const Duration(days: 4));
  final when = '${at.year}-${two(at.month)}-${two(at.day)}T09:00';
  final ar = template.locale == 'ar';
  final label = switch (template.id) {
    TriggerTemplateId.appointment => ar ? 'موعد' : 'Appointment',
    TriggerTemplateId.delivery => ar ? 'توصيل' : 'Delivery',
    TriggerTemplateId.booking => ar ? 'حجز' : 'Booking',
    TriggerTemplateId.subscription =>
      ar ? 'تجديد اشتراك' : 'Subscription renewal',
    TriggerTemplateId.billDue => ar ? 'استحقاق فاتورة' : 'Bill due',
  };
  final title = ar ? 'زيارة المكتبة' : 'Library visit';
  return '$label: $title | $when';
}
