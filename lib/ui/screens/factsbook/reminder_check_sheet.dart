import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../../domain/factsbook/factsbook_capabilities.dart';
import '../../../domain/factsbook/factsbook_types.dart';
import '../../../domain/factsbook/jcs.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/factsbook/factsbook_controller.dart';
import '../../app_iconography.dart';
import '../../kit/kit.dart';
import 'factsbook_text.dart';

/// "Check this reminder" (spec 60 screen 21, G25, D27): the title, date,
/// time, repeat, time zone and language of dates, all editable, shown before
/// anything is saved. "Save reminder" asks the node to read exactly these
/// values; it is saved only when the node's own preview agrees (same
/// schedule, zone, language and title, nothing left unclear) and the person
/// has seen the values. Returns the
/// node's confirmed preview, or null when the person goes back.
///
/// [askTitle] adds a title field (a reminder made from the Reminders page has
/// no note to take its words from). [scheduleId] keeps the schedule's
/// identity on an edit.
Future<ReminderPreview?> showFactsBookReminderCheck(
  BuildContext context, {
  required FactsBookController controller,
  required String what,
  required ReminderTiming timing,
  String zone = 'vault',
  String locale = 'en',
  List<String> ambiguities = const [],
  String original = '',
  bool askTitle = false,
  String? scheduleId,
  String area = 'general',
}) {
  final l10n = AppLocalizations.of(context);
  final navigator = Navigator.of(context);
  final state = _CheckState(
    controller: controller,
    what: what,
    timing: timing,
    zone: zone,
    locale: locale,
    scheduleId: scheduleId,
    area: area,
  );
  final primary = ValueNotifier<KitAction?>(null);
  void sync() => primary.value = KitAction(
    key: const ValueKey('factsbook-reminder-save'),
    label: l10n.fbReminderSave,
    working: state.working,
    onPressed: state.working || state.what.trim().isEmpty
        ? null
        : () => unawaited(
            state.confirm().then((preview) {
              if (preview != null) navigator.pop(preview);
            }),
          ),
    disabledReason: state.what.trim().isEmpty
        ? l10n.fbReminderNeedsTitle
        : null,
  );
  state.addListener(sync);
  sync();
  return showKitSheet<ReminderPreview>(
    context,
    sheetKey: const ValueKey('factsbook-reminder-sheet'),
    title: l10n.fbReminderTitle,
    icon: AppIconography.calendar,
    // With a title field the keyboard opens: the tall sheet keeps the detail
    // rows above it.
    height: askTitle ? KitSheetHeight.full : KitSheetHeight.content,
    body: (context) => _ReminderBody(
      state: state,
      ambiguities: ambiguities,
      original: original,
      askTitle: askTitle,
      cannotRing: controller.session.capabilities.isDisabled(
        FactsBookCapabilities.phoneAlarms,
      ),
    ),
    primaryListenable: primary,
    secondary: KitAction(
      key: const ValueKey('factsbook-reminder-change'),
      label: l10n.fbReminderChange,
      onPressed: () => navigator.pop(),
    ),
  ).whenComplete(() {
    // The notifiers are not disposed: the sheet is still closing and reads
    // them; with no listeners left they hold nothing.
    state.removeListener(sync);
  });
}

class _CheckState extends ChangeNotifier {
  _CheckState({
    required this.controller,
    required this.what,
    required this.timing,
    required this.zone,
    required this.locale,
    required this.scheduleId,
    required this.area,
  });

  final FactsBookController controller;
  String what;
  ReminderTiming timing;
  String zone;
  String locale;
  final String? scheduleId;
  final String area;

  bool working = false;
  FactsBookException? failure;
  bool mismatch = false;

  void edit({
    String? what,
    ReminderTiming? timing,
    String? zone,
    String? locale,
  }) {
    this.what = what ?? this.what;
    this.timing = timing ?? this.timing;
    this.zone = zone ?? this.zone;
    this.locale = locale ?? this.locale;
    failure = null;
    mismatch = false;
    notifyListeners();
  }

  /// Asks the node to read the fields. Returns the preview to save, or null
  /// when the sheet must stay open (a failure or a disagreement).
  Future<ReminderPreview?> confirm() async {
    working = true;
    failure = null;
    mismatch = false;
    notifyListeners();
    try {
      final preview = await controller.previewReminder(
        what: what,
        timing: timing,
        zone: zone,
        locale: locale,
        scheduleId: scheduleId,
        area: area,
      );
      final when = preview.schedule?.when.raw;
      final agrees =
          preview.confirmable &&
          when != null &&
          Jcs.string(when) == Jcs.string(timing.toWhen()) &&
          preview.zone == zone &&
          preview.locale == locale &&
          preview.what == what.trim();
      if (!agrees) {
        mismatch = true;
        return null;
      }
      // The node's `adjustments` are standing notes (how a clock change or a
      // month end is read), not a change to what the person chose, so they
      // do not hold the save back; the sheet says the same in its own words.
      return preview;
    } on FactsBookException catch (error) {
      failure = error;
      return null;
    } finally {
      working = false;
      notifyListeners();
    }
  }
}

class _ReminderBody extends StatefulWidget {
  const _ReminderBody({
    required this.state,
    required this.ambiguities,
    required this.original,
    required this.askTitle,
    this.cannotRing = false,
  });

  final _CheckState state;

  /// The node cannot sound reminders on this phone yet: say so before the
  /// person saves, not only on the Reminders list afterwards.
  final bool cannotRing;
  final List<String> ambiguities;
  final String original;
  final bool askTitle;

  @override
  State<_ReminderBody> createState() => _ReminderBodyState();
}

class _ReminderBodyState extends State<_ReminderBody> {
  late final _title = TextEditingController(text: widget.state.what);

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  static const _locales = {'en': 'English', 'ar': 'العربية'};

  /// The date in the language chosen; a language whose date data is not
  /// loaded falls back to the app's own.
  static String _dateOf(BuildContext context, DateTime at, String code) {
    try {
      return DateFormat.yMMMMEEEEd(code).add_jm().format(at);
    } on Exception {
      final app = Localizations.localeOf(context).toString();
      return DateFormat.yMMMMEEEEd(app).add_jm().format(at);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final state = widget.state;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final timing = state.timing;
        final repeat = timing.repeat;
        final zoneChoice = state.zone == 'floating' ? 'floating' : 'vault';
        final summary = repeat == ReminderRepeat.never
            ? _dateOf(context, timing.at, state.locale)
            : timingWords(context, l10n, timing);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: tokens.space3,
          children: [
            if (widget.original.isNotEmpty)
              KitText(
                l10n.fbReminderWrote(bidiName(context, widget.original)),
                key: const ValueKey('factsbook-reminder-wrote'),
                role: KitTextRole.secondary,
                tone: KitTextTone.secondary,
              ),
            if (widget.askTitle)
              KitField(
                fieldKey: const ValueKey('factsbook-reminder-title'),
                controller: _title,
                label: l10n.fbReminderWhat,
                hint: l10n.fbReminderWhatHint,
                onChanged: (text) => state.edit(what: text),
                // Done puts the keyboard away, so the rows below are seen.
                onSubmitted: (_) => FocusScope.of(context).unfocus(),
                textInputAction: TextInputAction.done,
              ),
            // What it will say, above the detail rows: with the keyboard up the
            // person still sees when it will fire.
            KitText(
              bidiName(context, summary),
              key: const ValueKey('factsbook-reminder-summary'),
              role: KitTextRole.body,
            ),
            if (widget.ambiguities.contains('date'))
              KitNotice(
                key: const ValueKey('factsbook-reminder-ambiguous-date'),
                message: l10n.fbReminderAmbiguousDate,
              ),
            if (widget.ambiguities.contains('time'))
              KitNotice(
                key: const ValueKey('factsbook-reminder-ambiguous-time'),
                message: l10n.fbReminderAmbiguousTime,
              ),
            KitRowGroup(
              margin: EdgeInsets.zero,
              leadingIcons: false,
              children: [
                KitPickerRow<ReminderRepeat>(
                  rowKey: const ValueKey('factsbook-reminder-repeat'),
                  title: l10n.fbReminderRepeat,
                  selected: repeat,
                  valueLabel: repeatWords(l10n, repeat),
                  choices: [
                    for (final r in ReminderRepeat.values)
                      KitChoice(value: r, title: repeatWords(l10n, r)),
                  ],
                  onSelected: (next) => state.edit(
                    timing: timing.copyWith(
                      repeat: next,
                      weekdays:
                          next == ReminderRepeat.weekly &&
                              timing.weekdays.isEmpty
                          ? {timing.at.weekday}
                          : null,
                    ),
                  ),
                ),
                // A one-time and a yearly reminder name a day; the others
                // repeat on their own rule.
                if (repeat == ReminderRepeat.never ||
                    repeat == ReminderRepeat.yearly)
                  KitDateTimeRow.date(
                    rowKey: const ValueKey('factsbook-reminder-date'),
                    title: l10n.fbReminderDate,
                    value: timing.at,
                    first: DateTime(timing.at.year - 1),
                    last: DateTime(timing.at.year + 5),
                    onChanged: (date) {
                      if (date != null) {
                        state.edit(
                          timing: timing.copyWith(
                            at: DateTime(
                              date.year,
                              date.month,
                              date.day,
                              timing.at.hour,
                              timing.at.minute,
                            ),
                          ),
                        );
                      }
                    },
                  ),
                if (repeat == ReminderRepeat.monthly)
                  KitPickerRow<int>(
                    rowKey: const ValueKey('factsbook-reminder-day'),
                    title: l10n.fbReminderDayOfMonth,
                    selected: timing.lastDay ? 0 : timing.dayOfMonth,
                    valueLabel: timing.lastDay
                        ? l10n.fbReminderLastDay
                        : '${timing.dayOfMonth}',
                    choices: [
                      for (var d = 1; d <= 31; d++)
                        KitChoice(value: d, title: '$d'),
                      KitChoice(value: 0, title: l10n.fbReminderLastDay),
                    ],
                    onSelected: (d) => state.edit(
                      timing: timing.copyWith(
                        lastDay: d == 0,
                        dayOfMonth: d == 0 ? timing.dayOfMonth : d,
                      ),
                    ),
                  ),
                KitDateTimeRow.time(
                  rowKey: const ValueKey('factsbook-reminder-time'),
                  title: l10n.fbReminderTime,
                  value: TimeOfDay(
                    hour: timing.at.hour,
                    minute: timing.at.minute,
                  ),
                  onChanged: (time) {
                    if (time != null) {
                      state.edit(
                        timing: timing.copyWith(
                          at: DateTime(
                            timing.at.year,
                            timing.at.month,
                            timing.at.day,
                            time.hour,
                            time.minute,
                          ),
                        ),
                      );
                    }
                  },
                ),
                KitPickerRow<String>(
                  rowKey: const ValueKey('factsbook-reminder-zone'),
                  title: l10n.fbReminderZone,
                  selected: zoneChoice,
                  valueLabel: zoneChoice == 'vault'
                      ? l10n.fbReminderZoneHome
                      : l10n.fbReminderZoneFloating,
                  supporting: zoneChoice == 'vault'
                      ? l10n.fbReminderZoneHomeDetail
                      : l10n.fbReminderZoneFloatingDetail,
                  choices: [
                    KitChoice(
                      value: 'vault',
                      title: l10n.fbReminderZoneHome,
                      supporting: l10n.fbReminderZoneHomeDetail,
                    ),
                    KitChoice(
                      value: 'floating',
                      title: l10n.fbReminderZoneFloating,
                      supporting: l10n.fbReminderZoneFloatingDetail,
                    ),
                  ],
                  onSelected: (zone) => state.edit(zone: zone),
                ),
                KitPickerRow<String>(
                  rowKey: const ValueKey('factsbook-reminder-locale'),
                  title: l10n.fbReminderLocale,
                  selected: state.locale,
                  valueLabel: _locales[state.locale],
                  choices: [
                    for (final entry in _locales.entries)
                      KitChoice(value: entry.key, title: entry.value),
                  ],
                  onSelected: (code) => state.edit(locale: code),
                ),
              ],
            ),
            if (repeat == ReminderRepeat.weekly)
              KitFilterChips(
                chips: [
                  for (var d = 1; d <= 7; d++)
                    KitFilterChip(
                      key: ValueKey('factsbook-reminder-weekday-$d'),
                      label: DateFormat.E(
                        Localizations.localeOf(context).toString(),
                      ).format(DateTime(2024, 1, d)),
                      selected: timing.weekdays.contains(d),
                      onPressed: () {
                        final next = {...timing.weekdays};
                        if (!next.add(d)) {
                          // At least one day stays: a weekly reminder with
                          // none is not a reminder.
                          if (next.length > 1) next.remove(d);
                        }
                        state.edit(timing: timing.copyWith(weekdays: next));
                      },
                    ),
                ],
              ),
            if (state.mismatch)
              KitNotice(
                key: const ValueKey('factsbook-reminder-mismatch'),
                message: l10n.fbReminderMismatch,
              ),
            if (state.failure != null)
              KitNotice(
                key: const ValueKey('factsbook-reminder-failure'),
                message: failureWords(l10n, state.failure),
              ),
            if (widget.cannotRing)
              KitNotice(
                key: const ValueKey('factsbook-reminder-cannot-ring'),
                message: l10n.fbReminderNotSoundedYet,
              ),
            KitText(
              l10n.fbReminderHelp,
              role: KitTextRole.secondary,
              tone: KitTextTone.secondary,
            ),
            KitText(
              l10n.fbReminderClockNote,
              role: KitTextRole.caption,
              tone: KitTextTone.secondary,
            ),
          ],
        );
      },
    );
  }
}
