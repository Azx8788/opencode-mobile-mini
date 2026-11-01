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
import 'factsbook_routes.dart';
import 'factsbook_text.dart';
import 'trigger_text.dart';

/// Triggers (spec 44, screen "Triggers list"): the rules that watch for one
/// kind of message and only suggest, grouped by where the message comes
/// from, each with what it did this week and a pause. Also the messages a
/// rule has looked at, the offers waiting, and the way to a new rule. A node
/// without triggers is told so plainly; nothing here is faked.
class FactsBookTriggersScreen extends ConsumerStatefulWidget {
  const FactsBookTriggersScreen({super.key});

  @override
  ConsumerState<FactsBookTriggersScreen> createState() =>
      _FactsBookTriggersScreenState();
}

class _FactsBookTriggersScreenState
    extends ConsumerState<FactsBookTriggersScreen> {
  final _working = <String>{};
  String? _notice;
  bool _noticeIsGood = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(ref.read(factsBookControllerProvider).triggers.refresh());
      }
    });
  }

  Future<void> _pause(Rule rule) async {
    final l10n = AppLocalizations.of(context);
    final triggers = ref.read(factsBookControllerProvider).triggers;
    final pausing = rule.definition.enabled;
    setState(() => _working.add(rule.id));
    try {
      await triggers.setPaused(rule, paused: pausing);
      if (!mounted) return;
      setState(() {
        _noticeIsGood = true;
        _notice = pausing ? l10n.fbRulePausedDone : l10n.fbRuleResumedDone;
      });
    } on FactsBookException catch (failure) {
      if (!mounted) return;
      setState(() {
        _noticeIsGood = false;
        _notice = failure.stale
            ? l10n.fbRuleStale
            : failureWords(l10n, failure);
      });
    } finally {
      if (mounted) setState(() => _working.remove(rule.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(factsBookControllerProvider);
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    controller.session.approvalReason = l10n.fbAuthReason;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final triggers = controller.triggers;
        final ready = triggers.load == TriggersLoad.ready;
        final Widget body;
        if (!triggers.supported || triggers.load == TriggersLoad.unavailable) {
          body = ListView(
            children: [
              KitStateView(
                key: const ValueKey('factsbook-triggers-unavailable'),
                icon: AppIconography.sparkle,
                title: l10n.fbTriggersUnavailableTitle,
                body: l10n.fbTriggersUnavailableBody,
              ),
            ],
          );
        } else if (triggers.load == TriggersLoad.failed) {
          body = KitStateView.error(
            key: const ValueKey('factsbook-triggers-error'),
            title: l10n.fbErrorTitle,
            body: failureWords(l10n, triggers.error),
            details: failureDetails(l10n, triggers.error),
            retry: KitAction(
              label: l10n.commonRetry,
              onPressed: () => unawaited(triggers.refresh()),
            ),
          );
        } else if (!ready) {
          body = ListView(
            padding: KitScreen.padding(context),
            children: const [KitSkeletonRows()],
          );
        } else {
          body = _list(context, controller, triggers, l10n, tokens);
        }
        return KitScreen(
          topBar: KitTopBar(title: l10n.fbTriggersTitle),
          width: KitScreenWidth.reading,
          loading: triggers.load == TriggersLoad.loading,
          loadingLabel: l10n.fbTriggersTitle,
          body: body,
          bottom: ready
              ? KitActionBlock(
                  primary: KitAction(
                    key: const ValueKey('factsbook-triggers-new'),
                    label: l10n.fbTriggersNew,
                    icon: AppIconography.add,
                    onPressed: () => unawaited(openFactsBookRule(context)),
                  ),
                )
              : null,
        );
      },
    );
  }

  Widget _list(
    BuildContext context,
    FactsBookController controller,
    FactsBookTriggers triggers,
    AppLocalizations l10n,
    KitTokens tokens,
  ) {
    final rails = EdgeInsetsDirectional.symmetric(horizontal: tokens.gutter);
    final canChange = controller.session.canApprove;
    final groups = triggers.rulesBySource;
    final events = triggers.events.take(8).toList();
    return KitRefresh(
      onRefresh: triggers.refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsetsDirectional.only(
          top: tokens.space2,
          bottom: KitScreen.endPadding(context),
        ),
        children: [
          if (!canChange)
            Padding(
              padding: rails.add(
                EdgeInsetsDirectional.only(bottom: tokens.space3),
              ),
              child: KitNotice(
                key: const ValueKey('factsbook-triggers-needs-owner'),
                icon: AppIconography.info,
                message: l10n.fbRuleNeedsOwner,
                actions: [
                  KitAction(
                    label: l10n.fbCareSetupApproval,
                    onPressed: () => unawaited(openFactsBookConnect(context)),
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
                key: const ValueKey('factsbook-triggers-notice'),
                icon: _noticeIsGood
                    ? AppIconography.check
                    : AppIconography.info,
                message: _notice!,
                onDismiss: () => setState(() => _notice = null),
                dismissLabel: l10n.fbDismiss,
              ),
            ),
          if (groups.isEmpty)
            KitStateView(
              key: const ValueKey('factsbook-triggers-empty'),
              icon: AppIconography.sparkle,
              title: l10n.fbTriggersEmptyTitle,
              body: l10n.fbTriggersEmptyBody,
              size: KitStateSize.inline,
            ),
          for (final entry in groups.entries)
            KitRowGroup(
              key: ValueKey('factsbook-triggers-${entry.key.wire}'),
              label: sourceGroupWords(l10n, entry.key, entry.value.length),
              children: [
                for (final rule in entry.value)
                  _ruleRow(context, l10n, triggers, rule, canChange),
              ],
            ),
          if (events.isNotEmpty)
            KitRowGroup(
              key: const ValueKey('factsbook-triggers-recent'),
              label: l10n.fbTriggersRecent,
              children: [
                for (final event in events) _eventRow(context, l10n, event),
              ],
            ),
          KitGroupNote(message: l10n.fbTriggersFootnote),
        ],
      ),
    );
  }

  Widget _ruleRow(
    BuildContext context,
    AppLocalizations l10n,
    FactsBookTriggers triggers,
    Rule rule,
    bool canChange,
  ) {
    final definition = rule.definition;
    final activity = triggers.activity(rule.id);
    final week = activity.offers > 0
        ? l10n.fbRuleWeekOffers(
            activity.proposed,
            activity.ignored,
            activity.offers,
          )
        : l10n.fbRuleWeek(activity.proposed, activity.ignored);
    final busy = _working.contains(rule.id);
    final name = bidiName(context, definition.name);
    return KitRow(
      key: ValueKey('factsbook-rule-${rule.id}'),
      leading: KitRow.icon(context, AppIconography.sparkle),
      title: name,
      supporting: TextSpan(text: '${ruleLine(l10n, definition)}\n$week'),
      supportingMaxLines: 4,
      below: definition.enabled
          ? null
          : KitStatusTag(label: l10n.fbRulePaused, tone: KitStatusTagTone.done),
      trailing: KitIconButton(
        key: ValueKey('factsbook-rule-pause-${rule.id}'),
        icon: definition.enabled ? AppIconography.pause : AppIconography.play,
        tooltip: definition.enabled
            ? l10n.fbRulePause(definition.name)
            : l10n.fbRuleResume(definition.name),
        working: busy,
        onPressed: canChange && !busy ? () => unawaited(_pause(rule)) : null,
        disabledReason: canChange ? null : l10n.fbCareNeedsOwnerShort,
      ),
      onTap: () => unawaited(openFactsBookRule(context, rule: rule)),
    );
  }

  Widget _eventRow(
    BuildContext context,
    AppLocalizations l10n,
    TriggerEvent event,
  ) {
    final when = whenWords(context, event.capturedAt);
    return KitRow(
      key: ValueKey('factsbook-event-${event.id}'),
      leading: KitRow.icon(context, AppIconography.article),
      title: l10n.fbEventWhen(sourceKindWords(l10n, event.source.kind), when),
      supporting: TextSpan(text: triggerReasonWords(l10n, event.reason)),
      supportingMaxLines: 3,
      trailing: const KitChevron(),
      onTap: () => unawaited(openFactsBookEvent(context, event.id)),
    );
  }
}
