import 'dart:async';

import 'package:flutter/material.dart';

import '../../../builtin/quota_collector_host.dart';
import '../../../domain/usage_subscriptions.dart';
import '../../../state/connection.dart';
import '../../../state/usage_subscriptions_controller.dart';
import '../../app_iconography.dart';
import '../../kit/kit.dart';
import '../usage_widget_screen.dart';
import 'usage_actions.dart';
import 'usage_add_picker_screen.dart';
import 'usage_alerts_screen.dart';
import 'usage_plan_card.dart';
import 'usage_subscription_screen.dart';
import 'usage_text.dart';

/// Usage › Plans: every subscription the app can see, on every connection,
/// as one list with the most urgent first. Opening the page and pulling
/// down read again; the top bar's Refresh is offered by the hub.
class UsagePlansPage extends StatefulWidget {
  const UsagePlansPage({
    super.key,
    required this.controller,
    required this.usage,
    this.launcher,
    this.clock,
    this.prepare = true,
  });

  final ConnectionController controller;
  final UsageSubscriptionsController usage;
  final UsageSignInLauncher? launcher;

  /// Test seam for "now".
  final DateTime Function()? clock;

  /// Brings In-app Ubuntu's reader back first when it was set up and has
  /// stopped. Tests turn it off.
  final bool prepare;

  @override
  State<UsagePlansPage> createState() => _UsagePlansPageState();
}

class _UsagePlansPageState extends State<UsagePlansPage> {
  String? _notice;
  String? _fixing;

  UsageSignInLauncher get _launcher =>
      widget.launcher ?? ConnectionSignInLauncher(widget.controller);

  DateTime get _now => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_open());
    });
  }

  Future<void> _open() async {
    if (widget.prepare) {
      try {
        final host = InAppQuotaCollector(prefs: widget.controller.store.prefs);
        for (final profile in widget.controller.store.profiles) {
          await host.ensureRunning(profile);
        }
      } on Object {
        // The cards say what could not be read.
      }
    }
    if (mounted) await widget.usage.refresh();
  }

  Future<void> _fix(UsageSubscription subscription) async {
    setState(() {
      _fixing = subscription.key;
      _notice = null;
    });
    final outcome = await runUsageFix(
      context,
      controller: widget.controller,
      usage: widget.usage,
      launcher: _launcher,
      subscription: subscription,
    );
    if (!mounted) return;
    setState(() {
      _fixing = null;
      _notice = outcome == null || outcome == UsageSignInOutcome.opened
          ? null
          : usageOutcomeWords(usageStrings(context), outcome);
    });
  }

  Future<void> _add(String providerId) async {
    setState(() => _notice = null);
    final outcome = await startUsageAdd(
      context,
      controller: widget.controller,
      usage: widget.usage,
      launcher: _launcher,
      providerId: providerId,
    );
    if (!mounted) return;
    if (outcome != null && outcome != UsageSignInOutcome.opened) {
      setState(
        () => _notice = usageOutcomeWords(usageStrings(context), outcome),
      );
    }
  }

  void _openPlan(UsageSubscriptionsController usage, UsageSubscription s) =>
      unawaited(
        pushKitPage<void>(
          context,
          (_) => UsageSubscriptionScreen(
            controller: widget.controller,
            usage: usage,
            subscriptionKey: s.key,
            launcher: _launcher,
            clock: widget.clock,
          ),
        ),
      );

  void _openPicker() => unawaited(
    pushKitPage<void>(
      context,
      (_) => UsageAddPickerScreen(
        providerIds: widget.usage.snapshot.addable,
        onPick: (id) => unawaited(_add(id)),
      ),
    ),
  );

  Widget _padded(Widget child) => Padding(
    padding: EdgeInsetsDirectional.symmetric(
      horizontal: KitTokens.of(context).gutter,
    ),
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = usageStrings(context);
    final tokens = KitTokens.of(context);
    return ListenableBuilder(
      listenable: widget.usage,
      builder: (context, _) {
        final usage = widget.usage;
        final snapshot = usage.snapshot;
        final now = _now;
        final loading = !snapshot.loaded && snapshot.subscriptions.isEmpty;
        final settings = usage.widgetSettings;
        final widgetCount = [
          for (final s in snapshot.subscriptions)
            if (!settings.hiddenKeys.contains(s.key)) s,
        ].length;
        // The plan with the least left comes first; equal plans keep the
        // order the controller gave them.
        final cards = [
          for (final s in snapshot.subscriptions)
            if (UsageText.hasNumbers(s)) s,
        ];
        final order = {for (var i = 0; i < cards.length; i++) cards[i].key: i};
        cards.sort((a, b) {
          final byLeft = UsageText.leastLeftToOrderBy(
            a,
          ).compareTo(UsageText.leastLeftToOrderBy(b));
          return byLeft != 0 ? byLeft : order[a.key]!.compareTo(order[b.key]!);
        });
        final setup = [
          for (final s in snapshot.subscriptions)
            if (!UsageText.hasNumbers(s)) s,
        ];
        final children = <Widget>[
          if (_notice case final notice?)
            Padding(
              padding: EdgeInsetsDirectional.only(
                start: tokens.gutter,
                end: tokens.gutter,
                bottom: tokens.space3,
              ),
              child: KitNotice(
                key: const ValueKey('usage-plans-notice'),
                icon: AppIconography.info,
                message: notice,
              ),
            ),
          if (loading)
            const KitSkeletonRows(
              key: ValueKey('usage-plans-loading'),
              count: 3,
            )
          else if (snapshot.subscriptions.isEmpty)
            KitStateView(
              key: const ValueKey('usage-plans-empty'),
              icon: AppIconography.usageRing,
              title: l10n.usageEmptyTitle,
              body: l10n.usageEmptyBody,
              size: KitStateSize.inline,
              // No button: "Add a subscription" is the first row below, once.
            )
          else ...[
            if (cards.isNotEmpty)
              KitRowGroup(
                key: const ValueKey('usage-plans-group'),
                leadingIcons: false,
                children: [
                  for (final s in cards)
                    UsagePlanBlock(
                      subscription: s,
                      snapshot: snapshot,
                      now: now,
                      fixWorking:
                          s.fix == UsageFix.tryAgain && usage.refreshing,
                      onOpen: () => _openPlan(usage, s),
                      onFix: s.fix == UsageFix.tryAgain
                          ? () => unawaited(_fix(s))
                          : null,
                    ),
                ],
              ),
            if (setup.isNotEmpty) ...[
              if (cards.isEmpty)
                _padded(
                  KitText(
                    l10n.usageNoNumbersYet,
                    key: const ValueKey('usage-no-numbers'),
                    role: KitTextRole.secondary,
                    tone: KitTextTone.secondary,
                  ),
                ),
              if (cards.isEmpty) SizedBox(height: tokens.space3),
              KitRowGroup(
                key: const ValueKey('usage-needs-setup'),
                label: l10n.usageNeedsSetupHeader,
                children: [
                  for (final s in setup)
                    usageSetupRow(
                      context,
                      subscription: s,
                      snapshot: snapshot,
                      onOpen: () => _openPlan(usage, s),
                      onFix: s.fix == UsageFix.none
                          ? null
                          : () => unawaited(_fix(s)),
                      fixWorking: _fixing == s.key,
                    ),
                ],
              ),
            ],
          ],
          if (!loading) ...[
            SizedBox(height: tokens.sectionGap),
            KitRowGroup(
              leadingIcons: false,
              children: [
                if (snapshot.addable.isNotEmpty)
                  KitRow(
                    key: const ValueKey('usage-add-row'),
                    title: l10n.usageAddSection,
                    trailing: const KitChevron(),
                    onTap: _openPicker,
                  ),
                KitRow(
                  key: const ValueKey('usage-alerts-row'),
                  title: l10n.usageAlertsTitle,
                  trailing: KitRowValue(
                    usage.alertsOn
                        ? l10n.usageAlertsOnWord
                        : l10n.usageAlertsSummaryOff,
                  ),
                  onTap: () => pushKitPage<void>(
                    context,
                    (_) => UsageAlertsScreen(
                      controller: widget.controller,
                      usage: usage,
                    ),
                  ),
                ),
                KitRow(
                  key: const ValueKey('usage-widget-row'),
                  title: l10n.usageWidgetRow,
                  trailing: KitRowValue(l10n.usageWidgetPlans(widgetCount)),
                  onTap: () => pushKitPage<void>(
                    context,
                    (_) => UsageWidgetScreen(
                      controller: widget.controller,
                      usage: usage,
                    ),
                  ),
                ),
              ],
            ),
            if (snapshot.apiKeyAccounts.isNotEmpty) ...[
              SizedBox(height: tokens.sectionGap),
              _padded(
                KitDetailsFold(
                  key: const ValueKey('usage-api-keys'),
                  notes: [
                    for (final a in snapshot.apiKeyAccounts)
                      if (a.viaOpenCode)
                        l10n.usageViaOpenCodeNoPlan(
                          UsageText.connection(l10n, a.connection),
                        )
                      else
                        l10n.usageApiKeyOnly(
                          UsageText.provider(l10n, a.providerId, a.displayName),
                          UsageText.connection(l10n, a.connection),
                        ),
                  ],
                ),
              ),
            ],
          ],
        ];
        return KitRefresh(
          onRefresh: () => usage.refresh(force: true),
          child: ListView(
            key: const ValueKey('usage-plans'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsetsDirectional.only(
              top: tokens.space2,
              bottom: KitScreen.endPadding(context),
            ),
            children: children,
          ),
        );
      },
    );
  }
}
