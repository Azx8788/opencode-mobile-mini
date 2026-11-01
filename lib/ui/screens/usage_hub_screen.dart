import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import '../../state/usage_overview.dart';
import '../../state/usage_subscriptions_controller.dart';
import '../app_iconography.dart';
import '../kit/kit.dart';
import 'usage/usage_actions.dart' show UsageSignInLauncher;
import 'usage/usage_plans_page.dart';
import 'usage_refresh_slot.dart';
import 'usage_screen.dart';

/// The two halves of Usage.
enum UsageSection { spending, plans }

/// The one Usage screen: "Plans" (every subscription the app can see, with
/// how much is left and when it resets) and "Spending" (what the connected
/// OpenCode 2 server reports it used).
///
/// The sections are tabs, not one scroll. Spending is a long report (ranges,
/// charts, budgets) that would bury Plans below several screens of content,
/// and each section loads and refreshes on its own; a tab keeps Plans one
/// tap away.
///
/// Plans is always there. Spending is absent on a connection that cannot
/// serve it, and with only one section left there is no tab strip at all.
///
/// The top bar holds one Refresh, for the active section.
class UsageHubScreen extends StatefulWidget {
  final ConnectionController controller;

  /// The section an entry point means (a quota alert opens Plans).
  final UsageSection? initialSection;

  /// Test seams, handed to the sections unchanged.
  final UsageOverview? usageOverview;
  final UsageSubscriptionsController? usage;
  final UsageSignInLauncher? launcher;
  final DateTime Function()? clock;
  final bool prepare;

  const UsageHubScreen({
    super.key,
    required this.controller,
    this.initialSection,
    this.usageOverview,
    this.usage,
    this.launcher,
    this.clock,
    this.prepare = true,
  });

  /// The sections this connection can show: Plans once there is a saved
  /// server to read, Spending where the connected
  /// server reports usage statistics.
  static List<UsageSection> sectionsFor(ConnectionController controller) => [
    if (controller.store.profiles.isNotEmpty) UsageSection.plans,
    if (controller.supportsUsageStatistics) UsageSection.spending,
  ];

  @override
  State<UsageHubScreen> createState() => _UsageHubScreenState();
}

class _UsageHubScreenState extends State<UsageHubScreen> {
  /// The chosen section, by name, so a section that comes or goes keeps the
  /// person on the one they chose.
  UsageSection? _chosen;

  final _spendingSlot = UsageRefreshSlot();

  UsageSubscriptionsController get _usage =>
      widget.usage ?? widget.controller.usageSubscriptions;

  @override
  void initState() {
    super.initState();
    _chosen = widget.initialSection;
  }

  @override
  void dispose() {
    _spendingSlot.dispose();
    super.dispose();
  }

  /// Refresh for the active section, when it has one now.
  List<KitAction> _refresh(AppLocalizations l10n, UsageSection section) {
    switch (section) {
      case UsageSection.plans:
        return [
          KitAction(
            key: const ValueKey('plans-refresh'),
            label: l10n.usagePlansRefresh,
            icon: AppIconography.retry,
            working: _usage.refreshing,
            onPressed: () => _usage.refresh(force: true),
          ),
        ];
      case UsageSection.spending:
        if (!_spendingSlot.visible) return const [];
        return [
          KitAction(
            key: const ValueKey('refresh-usage'),
            label: l10n.usageRefreshSpending,
            icon: AppIconography.retry,
            onPressed: _spendingSlot.onRefresh,
            disabledReason: _spendingSlot.disabledReason,
          ),
        ];
    }
  }

  Widget _body(UsageSection section) => KeyedSubtree(
    key: ValueKey('usage-section-${section.name}'),
    child: switch (section) {
      UsageSection.spending => UsageScreen(
        controller: widget.controller,
        overview: widget.usageOverview,
        embedded: true,
        refreshSlot: _spendingSlot,
      ),
      UsageSection.plans => UsagePlansPage(
        controller: widget.controller,
        usage: _usage,
        launcher: widget.launcher,
        clock: widget.clock,
        prepare: widget.prepare,
      ),
    },
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_spendingSlot, _usage]),
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final sections = UsageHubScreen.sectionsFor(widget.controller);
    if (sections.isEmpty) {
      // The Settings row is absent in this case; a deep link or search
      // result that still lands here says why instead of a blank page.
      return KitScreen(
        topBar: KitTopBar(title: l10n.settingsHubGroupUsage),
        body: KitStateView(
          key: const ValueKey('usage-hub-unavailable'),
          icon: AppIconography.usage,
          title: l10n.usageHubUnavailableTitle,
          body: l10n.usageHubUnavailableBody,
        ),
      );
    }
    if (sections.length == 1) {
      return KitScreen(
        topBar: KitTopBar(
          title: l10n.settingsHubGroupUsage,
          actions: _refresh(l10n, sections.single),
        ),
        body: _body(sections.single),
      );
    }
    final found = sections.indexOf(_chosen ?? sections.first);
    final index = found < 0 ? 0 : found;
    return KitScreen(
      topBar: KitTopBar(
        title: l10n.settingsHubGroupUsage,
        actions: _refresh(l10n, sections[index]),
      ),
      // The strip lines up with the sections' reading column on wide
      // windows instead of sitting at the window's edge.
      width: KitScreenWidth.reading,
      body: KitTabSwitcher.tabs(
        semanticsLabel: l10n.settingsHubGroupUsage,
        index: index,
        onSelected: (next) => setState(() => _chosen = sections[next]),
        tabs: [
          for (final section in sections)
            KitTab(
              key: ValueKey('usage-tab-${section.name}'),
              label: switch (section) {
                UsageSection.spending => l10n.usageTabSpending,
                UsageSection.plans => l10n.usageTabPlans,
              },
            ),
        ],
        children: [for (final section in sections) _body(section)],
      ),
    );
  }
}
