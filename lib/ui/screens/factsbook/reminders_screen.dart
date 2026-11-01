import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/factsbook/factsbook_capabilities.dart';
import '../../../domain/factsbook/factsbook_types.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/factsbook/factsbook_controller.dart';
import '../../app_iconography.dart';
import '../../kit/kit.dart';
import 'factsbook_text.dart';
import 'reminder_check_sheet.dart';

/// Reminders (spec 60 screen 20, G26, D27): the list lives independently of
/// chats, with Active, Paused and Done, a pause or resume on each, and edit
/// through the same check as a new reminder (date, time, zone and language
/// shown before saving). A reminder can be added from this page with its own
/// title, and repeat daily, weekly, monthly or yearly; schedule forms the app
/// does not build (intervals, events) are listed and can be paused but not
/// edited here.
class FactsBookRemindersScreen extends ConsumerStatefulWidget {
  const FactsBookRemindersScreen({super.key});

  @override
  ConsumerState<FactsBookRemindersScreen> createState() =>
      _FactsBookRemindersScreenState();
}

class _FactsBookRemindersScreenState
    extends ConsumerState<FactsBookRemindersScreen> {
  List<Reminder>? _reminders;
  Object? _failure;
  bool _loading = true;
  final _working = <String>{};
  String? _notice;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  FactsBookController get _controller => ref.read(factsBookControllerProvider);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final list = await _controller.reminders();
      if (mounted) setState(() => _reminders = list);
    } on FactsBookException catch (failure) {
      if (mounted) setState(() => _failure = failure);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pause(Reminder reminder) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _working.add(reminder.id));
    try {
      await _controller.setReminderPaused(reminder, paused: !reminder.paused);
      await _load();
      if (mounted) setState(() => _notice = null);
    } on FactsBookException catch (failure) {
      if (!mounted) return;
      setState(() => _notice = failureWords(l10n, failure));
      // A changed reminder shows its new state.
      if (failure.stale) await _load();
    } finally {
      if (mounted) setState(() => _working.remove(reminder.id));
    }
  }

  Future<void> _edit(Reminder reminder) async {
    final l10n = AppLocalizations.of(context);
    final timing = ReminderTiming.fromWhen(reminder.schedule.when);
    if (timing == null) return;
    final preview = await showFactsBookReminderCheck(
      context,
      controller: _controller,
      what: reminder.what,
      timing: timing,
      zone: reminder.schedule.zone,
      locale: reminder.locale == 'ar' ? 'ar' : 'en',
      scheduleId: reminder.schedule.id,
      area: reminder.area,
    );
    if (preview == null || !mounted) return;
    try {
      await _controller.updateReminder(
        reminder,
        preview,
        floatingConfirmed: preview.zone == 'floating',
      );
      await _load();
      if (mounted) setState(() => _notice = null);
    } on FactsBookException catch (failure) {
      if (!mounted) return;
      setState(() => _notice = failureWords(l10n, failure));
      if (failure.stale) await _load();
    }
  }

  /// A reminder made from this page: the sheet asks for its title too.
  Future<void> _add() async {
    final l10n = AppLocalizations.of(context);
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final app = Localizations.localeOf(context).languageCode;
    final preview = await showFactsBookReminderCheck(
      context,
      controller: _controller,
      what: '',
      timing: ReminderTiming(
        repeat: ReminderRepeat.never,
        at: DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9),
      ),
      locale: app == 'ar' ? 'ar' : 'en',
      askTitle: true,
    );
    if (preview == null || !mounted) return;
    try {
      await _controller.createReminder(
        preview,
        floatingConfirmed: preview.zone == 'floating',
      );
      await _load();
      if (mounted) setState(() => _notice = null);
    } on FactsBookException catch (failure) {
      if (mounted) setState(() => _notice = failureWords(l10n, failure));
    }
  }

  String _when(BuildContext context, AppLocalizations l10n, Reminder r) {
    final zone = switch (r.schedule.zone) {
      'vault' => l10n.fbReminderZoneHome,
      'floating' => l10n.fbReminderZoneFloating,
      final other => other,
    };
    final timing = ReminderTiming.fromWhen(r.schedule.when);
    final words = timing == null
        ? l10n.fbWhenCustom
        : timingWords(context, l10n, timing);
    return '$words · $zone';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final reminders = _reminders;
    final Widget body;
    if (reminders == null && _failure == null) {
      body = ListView(
        padding: KitScreen.padding(context),
        children: const [KitSkeletonRows()],
      );
    } else if (reminders == null) {
      body = KitStateView.error(
        key: const ValueKey('factsbook-reminders-error'),
        title: l10n.fbErrorTitle,
        body: failureWords(l10n, _failure),
        details: failureDetails(l10n, _failure),
        retry: KitAction(
          label: l10n.commonRetry,
          onPressed: () => unawaited(_load()),
        ),
      );
    } else {
      final active = [
        for (final r in reminders)
          if (!r.paused && !r.done) r,
      ];
      final paused = [
        for (final r in reminders)
          if (r.paused && !r.done) r,
      ];
      final done = [
        for (final r in reminders)
          if (r.done) r,
      ];
      body = KitRefresh(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsetsDirectional.only(
            top: tokens.space2,
            bottom: KitScreen.endPadding(context),
          ),
          children: [
            if (_notice != null)
              Padding(
                padding: EdgeInsetsDirectional.only(
                  start: tokens.gutter,
                  end: tokens.gutter,
                  bottom: tokens.space3,
                ),
                child: KitNotice(
                  key: const ValueKey('factsbook-reminders-notice'),
                  message: _notice!,
                  onDismiss: () => setState(() => _notice = null),
                  dismissLabel: l10n.fbDismiss,
                ),
              ),
            if (_controller.session.capabilities.supports(
              FactsBookCapabilities.reminders,
            ))
              KitRowGroup(
                children: [
                  KitRow(
                    key: const ValueKey('factsbook-reminders-add'),
                    leading: KitRow.badge(
                      context,
                      AppIconography.add,
                      accent: true,
                    ),
                    title: l10n.fbRemindersAdd,
                    titleAccent: true,
                    trailing: const KitChevron(),
                    onTap: () => unawaited(_add()),
                  ),
                ],
              ),
            if (reminders.isEmpty)
              KitStateView(
                key: const ValueKey('factsbook-reminders-empty'),
                icon: AppIconography.clock,
                title: l10n.fbRemindersEmptyTitle,
                body: l10n.fbRemindersEmptyBody,
                size: KitStateSize.inline,
              ),
            if (active.isNotEmpty)
              KitRowGroup(
                label: l10n.fbRemindersActive,
                children: [for (final r in active) _row(context, l10n, r)],
              ),
            if (paused.isNotEmpty)
              KitRowGroup(
                label: l10n.fbRemindersPaused,
                children: [for (final r in paused) _row(context, l10n, r)],
              ),
            if (done.isNotEmpty)
              KitRowGroup(
                label: l10n.fbRemindersDone,
                children: [for (final r in done) _row(context, l10n, r)],
              ),
          ],
        ),
      );
    }
    return KitScreen(
      topBar: KitTopBar(title: l10n.fbRemindersTitle),
      width: KitScreenWidth.reading,
      loading: _loading && reminders != null,
      loadingLabel: l10n.fbRemindersTitle,
      body: body,
    );
  }

  Widget _row(BuildContext context, AppLocalizations l10n, Reminder r) {
    final working = _working.contains(r.id);
    final editable =
        ReminderTiming.fromWhen(r.schedule.when) != null && !r.done;
    return KitRow(
      key: ValueKey('factsbook-reminder-${r.id}'),
      leading: KitRow.icon(
        context,
        r.paused ? AppIconography.pause : AppIconography.clock,
      ),
      title: bidiName(context, r.what),
      titleMaxLines: 2,
      supporting: TextSpan(
        text: [
          _when(context, l10n, r),
          if (!r.done &&
              !r.paused &&
              _controller.session.capabilities.isDisabled(
                FactsBookCapabilities.phoneAlarms,
              ))
            l10n.fbReminderNotSounded,
        ].join('\n'),
      ),
      supportingMaxLines: 3,
      onTap: editable && !working ? () => unawaited(_edit(r)) : null,
      trailing: r.done
          ? null
          : KitIconButton(
              key: ValueKey('factsbook-reminder-pause-${r.id}'),
              icon: r.paused ? AppIconography.play : AppIconography.pause,
              tooltip: r.paused
                  ? l10n.fbReminderResume(bidiName(context, r.what))
                  : l10n.fbReminderPause(bidiName(context, r.what)),
              working: working,
              onPressed: working ? null : () => unawaited(_pause(r)),
            ),
    );
  }
}
