import 'package:flutter/material.dart';

import '../../../domain/usage_subscriptions.dart';
import '../../../l10n/app_localizations.dart';
import '../../app_theme.dart';
import '../../kit/kit.dart';
import 'usage_actions.dart';
import 'usage_text.dart';

/// One plan that has numbers, as a block of the Plans page's one group: the
/// plan name with its tier in small text on the left, one small summary on
/// the right ("12% left", or "Back at 1:25 PM" for a used-up plan, never a
/// pill), and one line per window ("5 hours [bar] 12% · 1:25 PM"). Every bar
/// is the accent colour; the numbers say how low a plan is. The whole block
/// opens the plan page. Plans that have no numbers are not blocks: they are
/// rows under "Needs setup" ([usageSetupRow]). Built only from kit parts.
class UsagePlanBlock extends StatelessWidget {
  const UsagePlanBlock({
    super.key,
    required this.subscription,
    required this.snapshot,
    required this.now,
    required this.onOpen,
    required this.onFix,
    this.fixWorking = false,
  });

  final UsageSubscription subscription;
  final UsageSnapshot snapshot;
  final DateTime now;
  final VoidCallback onOpen;

  /// Only a reader that broke over old numbers offers one ("Try again").
  final VoidCallback? onFix;
  final bool fixWorking;

  @override
  Widget build(BuildContext context) {
    final l10n = usageStrings(context);
    final tokens = KitTokens.of(context);
    final key = subscription.key;
    final name = UsageText.subscriptionName(l10n, subscription);
    final plan = UsageText.plan(subscription.planLabel);
    // The connection is named here and only here, and only when the numbers
    // come from a known one. Offline blocks say it in their own line.
    final from = switch (subscription.state) {
      SubscriptionState.offlineStale => null,
      _ => subscription.readFrom,
    };
    final tier = [
      ?plan,
      if (snapshot.hasSeveralConnections && from != null)
        UsageText.connection(l10n, from),
    ].join(' · ');
    final summary = UsageText.planSummary(context, l10n, subscription, now);
    final message = UsageText.stateMessage(l10n, snapshot, subscription, now);
    final windows = UsageText.cardWindows(subscription);
    final checked = UsageText.checkedLine(l10n, subscription, now);
    final since = subscription.resetSinceLastReading
        ? _sinceLine(context, l10n)
        : null;
    final fixLabel = onFix == null
        ? null
        : usageFixLabel(
            l10n,
            subscription,
            (c) => UsageText.connection(l10n, c),
          );
    Widget note(String value, Key key) => Padding(
      padding: EdgeInsetsDirectional.only(top: tokens.space1),
      child: KitText(
        value,
        key: key,
        role: KitTextRole.caption,
        tone: KitTextTone.secondary,
      ),
    );
    return KitPlanBlock(
      key: ValueKey('usage-card-$key'),
      title: name,
      titleNote: tier.isEmpty ? null : tier,
      summary: summary,
      summaryKey: ValueKey('usage-summary-$key'),
      onTap: onOpen,
      children: [
        if (message != null) note(message, ValueKey('usage-message-$key')),
        for (final window in windows)
          KitWindowRow(
            key: ValueKey('usage-bar-$key-${window.id}'),
            inline: true,
            title: UsageText.windowTitle(l10n, window),
            left: window.leftPercent / 100,
            valueLabel: UsageText.windowShort(context, window, now),
            valueSemantics: UsageText.windowValue(context, window, now),
          ),
        if (since != null) note(since, ValueKey('usage-reset-$key')),
        if (checked != null) note(checked, ValueKey('usage-checked-$key')),
        if (fixLabel != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: KitButton.tertiary(
              key: ValueKey('usage-fix-$key'),
              label: fixLabel,
              icon: subscription.fix == UsageFix.tryAgain
                  ? AppIconography.retry
                  : null,
              onPressed: onFix,
            ),
          ),
      ],
    );
  }

  String? _sinceLine(BuildContext context, AppLocalizations l10n) {
    final passed = [
      for (final w in subscription.windows)
        if (w.resetPassed(now)) w.resetsAt!,
    ]..sort();
    if (passed.isEmpty) return null;
    return l10n.usageResetSince(UsageText.when(context, passed.first, now));
  }
}

/// One plan that needs setup, as a row of the "Needs setup" group: logo,
/// name, one muted status line and the fix as a compact button at the end.
/// The row body opens the plan page.
KitRow usageSetupRow(
  BuildContext context, {
  required UsageSubscription subscription,
  required UsageSnapshot snapshot,
  required VoidCallback onOpen,
  required VoidCallback? onFix,
  bool fixWorking = false,
}) {
  final l10n = usageStrings(context);
  final label = onFix == null || subscription.fix == UsageFix.none
      ? null
      : usageFixLabel(l10n, subscription, (c) => UsageText.connection(l10n, c));
  return KitRow(
    key: ValueKey('usage-card-${subscription.key}'),
    leading: UsageText.logo(subscription.providerId),
    title: UsageText.subscriptionName(l10n, subscription),
    titleMaxLines: 2,
    supporting: TextSpan(
      text: UsageText.setupLine(l10n, snapshot, subscription),
    ),
    supportingMaxLines: 2,
    onTap: onOpen,
    action: label == null
        ? null
        : KitAction(
            key: ValueKey('usage-fix-${subscription.key}'),
            label: label,
            icon: subscription.fix == UsageFix.tryAgain
                ? AppIconography.retry
                : null,
            working: fixWorking,
            onPressed: onFix,
          ),
    trailing: label == null ? const KitChevron() : null,
  );
}
