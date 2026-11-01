import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/factsbook/factsbook_types.dart';
import '../../../domain/factsbook/reminder_guess.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/factsbook/factsbook_controller.dart';
import '../../app_theme.dart';
import '../../kit/kit.dart';
import 'factsbook_routes.dart';
import 'factsbook_text.dart';
import 'reminder_check_sheet.dart';

/// Add something (spec 60 screen 9, G24): one place to add a note or pasted
/// text. A note can be added to a thing the person picks (it becomes a fact
/// that waits for their OK) or to an area; "Also remind me about it" runs the
/// text through the reminder check first (D27). After Save the page says what
/// happens next. A save that cannot finish lands in Not saved yet; the text
/// is never lost (D25).
class FactsBookCaptureScreen extends ConsumerStatefulWidget {
  const FactsBookCaptureScreen({super.key});

  @override
  ConsumerState<FactsBookCaptureScreen> createState() =>
      _FactsBookCaptureScreenState();
}

class _FactsBookCaptureScreenState
    extends ConsumerState<FactsBookCaptureScreen> {
  /// The picker's value for "let memory sort it".
  static const _auto = '';

  final _text = TextEditingController();
  CaptureKind _kind = CaptureKind.note;
  bool _working = false;
  String? _notice;
  bool _kept = false;

  /// "See Needs you" under a notice, for a fact that waits for the OK.
  bool _seeNeedsYou = false;

  /// Add to: a thing the person picked (the note becomes a fact of it), or
  /// [_auto] to let memory sort it. Area: only for a note with no thing.
  String _thingId = _auto;
  String _area = _auto;
  List<Thing> _things = const [];
  List<Area> _areas = const [];

  /// "Also remind me about it": the reminder check runs on Save.
  bool _remind = false;

  /// The person's choice about rules reading this text; null until they
  /// choose, when it follows whether any rule is on.
  bool? _rules;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(
          ref.read(factsBookControllerProvider).triggers.refresh(quiet: true),
        );
        unawaited(_loadChoices());
      }
    });
  }

  /// The things and areas the pickers offer. A node that does not answer
  /// leaves them out: the note can still be saved.
  Future<void> _loadChoices() async {
    final controller = ref.read(factsBookControllerProvider);
    try {
      final things = await controller.things();
      if (mounted) setState(() => _things = things);
    } on FactsBookException {
      // No picker.
    }
    try {
      final areas = await controller.areas();
      if (mounted) setState(() => _areas = areas);
    } on FactsBookException {
      // No picker.
    }
  }

  Thing? get _thing {
    for (final thing in _things) {
      if (thing.id == _thingId) return thing;
    }
    return null;
  }

  bool _rulesLook(FactsBookController controller) {
    final triggers = controller.triggers;
    if (!triggers.supported) return false;
    return _rules ?? triggers.rules.any((r) => r.definition.enabled);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _canSave => _text.text.trim().isNotEmpty && !_working;

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final controller = ref.read(factsBookControllerProvider);
    final text = _text.text.trim();
    if (text.isEmpty) return;
    // The keyboard would cover the answer ("Saved", or why not).
    FocusScope.of(context).unfocus();
    final thing = _kind == CaptureKind.note ? _thing : null;
    final withReminder = _remind && _kind == CaptureKind.note;
    setState(() {
      _working = true;
      _notice = null;
      _seeNeedsYou = false;
    });
    try {
      ReminderPreview? reminder;
      if (withReminder) {
        final guess = ReminderGuess.from(text, clock.now());
        final app = Localizations.localeOf(context).languageCode;
        reminder = await showFactsBookReminderCheck(
          context,
          controller: controller,
          what: guess.what,
          // A one-off unless the words say it repeats.
          timing: ReminderTiming(
            repeat: guess.repeat,
            at: guess.at,
            weekdays: guess.repeat == ReminderRepeat.weekly
                ? {guess.at.weekday}
                : const {},
            dayOfMonth: guess.at.day,
          ),
          locale: app == 'ar' ? 'ar' : 'en',
          ambiguities: guess.ambiguities,
          original: text,
        );
        // "Change what I wrote": nothing is saved, the text stays.
        if (reminder == null || !mounted) {
          setState(() => _working = false);
          return;
        }
      }
      var message = '';
      var kept = false;
      var clear = true;
      var saved = false;
      var needsYou = false;
      if (thing != null) {
        // A fact of the picked thing: one line, proposed for the person's OK
        // where the area asks first.
        final result = await controller.addFact(
          thing,
          text.replaceAll(RegExp(r'\s+'), ' '),
        );
        if (!mounted) return;
        saved = true;
        needsYou = result.status != 'ok';
        message = needsYou
            ? l10n.fbCaptureFactProposed
            : l10n.fbCaptureFactAdded(bidiName(context, thing.title));
      } else {
        final looks = _rulesLook(controller);
        if (looks) controller.session.approvalReason = l10n.fbAuthReasonRules;
        final outcome = await controller.capture(
          CaptureRequest(
            kind: _kind,
            text: text,
            area: _area == _auto ? null : _area,
          ),
          rulesLook: looks,
        );
        if (!mounted) return;
        switch (outcome) {
          case CaptureSavedAtNode():
            saved = true;
            message = l10n.fbCaptureSaved;
          case CaptureQueuedAtNode():
            kept = true;
            message = l10n.fbCaptureQueuedNode;
          case CaptureKeptOnPhone():
            // The text stays in the field too: nothing typed is lost.
            kept = true;
            clear = false;
            message = l10n.fbCaptureKept;
          case CaptureRefusedFull():
            kept = true;
            clear = false;
            message = l10n.fbCaptureFull;
        }
      }
      if (!mounted) return;
      if (reminder != null && saved) {
        try {
          await controller.createReminder(
            reminder,
            floatingConfirmed: reminder.zone == 'floating',
          );
          if (!mounted) return;
          final at = reminder.at ?? clock.now();
          message =
              '$message '
              '${l10n.fbCaptureSavedReminder(KitBidi.ltr('${KitFactRow.dateOf(context, at)}, ${KitTime.clock(context, at)}'))}';
        } on FactsBookException {
          if (!mounted) return;
          message = '$message ${l10n.fbCaptureReminderFailed}';
        }
      } else if (reminder != null) {
        // The note is kept; the reminder was not made. Said plainly.
        message = '$message ${l10n.fbCaptureReminderNotMade}';
      }
      setState(() {
        _working = false;
        _kept = kept;
        _seeNeedsYou = needsYou;
        _notice = message;
        if (clear) {
          _text.clear();
          _remind = false;
        }
      });
    } on FactsBookException catch (failure) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _kept = false;
        _notice = failureWords(l10n, failure);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final rails = EdgeInsetsDirectional.symmetric(horizontal: tokens.gutter);
    final note = _kind == CaptureKind.note;
    final controller = ref.watch(factsBookControllerProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) =>
          _screen(context, l10n, tokens, rails, note, controller),
    );
  }

  Widget _screen(
    BuildContext context,
    AppLocalizations l10n,
    KitTokens tokens,
    EdgeInsetsDirectional rails,
    bool note,
    FactsBookController controller,
  ) {
    final thing = note ? _thing : null;
    final rulesOn = controller.triggers.rules
        .where((r) => r.definition.enabled)
        .length;
    return KitScreen(
      topBar: KitTopBar(title: l10n.fbCaptureTitle),
      width: KitScreenWidth.reading,
      loading: _working,
      loadingLabel: l10n.fbCaptureTitle,
      body: ListView(
        padding: EdgeInsetsDirectional.only(
          top: tokens.space2,
          bottom: KitScreen.endPadding(context),
        ),
        children: [
          Padding(
            padding: rails,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: tokens.space4,
              children: [
                KitSegmented<CaptureKind>(
                  semanticsLabel: l10n.fbCaptureKindLabel,
                  selected: _kind,
                  onChanged: (kind) => setState(() => _kind = kind),
                  segments: [
                    KitSegment(
                      key: const ValueKey('factsbook-capture-note'),
                      value: CaptureKind.note,
                      label: l10n.fbCaptureNote,
                    ),
                    KitSegment(
                      key: const ValueKey('factsbook-capture-paste'),
                      value: CaptureKind.share,
                      label: l10n.fbCapturePaste,
                    ),
                  ],
                ),
                KitField(
                  fieldKey: const ValueKey('factsbook-capture-field'),
                  controller: _text,
                  kind: KitFieldKind.multiline,
                  minLines: 4,
                  maxLines: 10,
                  label: note
                      ? l10n.fbCaptureNoteLabel
                      : l10n.fbCapturePasteLabel,
                  hint: note ? l10n.fbCaptureNoteHint : null,
                ),
              ],
            ),
          ),
          if (note && _things.isNotEmpty ||
              (thing == null && _areas.isNotEmpty))
            KitRowGroup(
              key: const ValueKey('factsbook-capture-where'),
              gapBefore: tokens.space3,
              leadingIcons: false,
              children: [
                if (note && _things.isNotEmpty)
                  KitPickerRow<String>(
                    rowKey: const ValueKey('factsbook-capture-thing'),
                    title: l10n.fbCaptureAddTo,
                    selected: _thingId,
                    valueLabel: thing == null
                        ? l10n.fbCaptureAddToNone
                        : bidiName(context, thing.title),
                    supporting: thing == null
                        ? null
                        : l10n.fbCaptureAddToFactNote,
                    choices: [
                      KitChoice(value: _auto, title: l10n.fbCaptureAddToNone),
                      for (final t in _things)
                        KitChoice(
                          value: t.id,
                          title: bidiName(context, t.title),
                          supporting: kindWords(l10n, t.kind),
                        ),
                    ],
                    onSelected: (id) => setState(() => _thingId = id),
                  ),
                if (thing == null && _areas.isNotEmpty)
                  KitPickerRow<String>(
                    rowKey: const ValueKey('factsbook-capture-area'),
                    title: l10n.fbCaptureArea,
                    selected: _area,
                    valueLabel: _area == _auto
                        ? l10n.fbCaptureAreaAuto
                        : areaName(l10n, _area),
                    choices: [
                      KitChoice(value: _auto, title: l10n.fbCaptureAreaAuto),
                      for (final a in _areas)
                        KitChoice(value: a.slug, title: areaName(l10n, a.slug)),
                    ],
                    onSelected: (slug) => setState(() => _area = slug),
                  ),
              ],
            ),
          if (note)
            KitRowGroup(
              gapBefore: tokens.space3,
              leadingIcons: false,
              children: [
                KitSwitchRow(
                  switchKey: const ValueKey('factsbook-capture-remind'),
                  title: l10n.fbCaptureRemindToo,
                  supporting: l10n.fbCaptureRemindTooDetail,
                  value: _remind,
                  onChanged: (v) => setState(() => _remind = v),
                ),
              ],
            ),
          if (controller.triggers.supported && thing == null)
            KitRowGroup(
              gapBefore: tokens.space3,
              leadingIcons: false,
              children: [
                KitSwitchRow(
                  switchKey: const ValueKey('factsbook-capture-rules'),
                  title: l10n.fbCaptureRulesLook,
                  supporting: l10n.fbCaptureRulesOn(rulesOn),
                  value: _rulesLook(controller),
                  onChanged: (v) => setState(() => _rules = v),
                ),
                KitRow(
                  key: const ValueKey('factsbook-capture-see-rules'),
                  title: l10n.fbCaptureSeeRules,
                  trailing: const KitChevron(),
                  onTap: () => unawaited(openFactsBookTriggers(context)),
                ),
              ],
            ),
          Padding(
            padding: rails,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: tokens.space4,
              children: [
                if (_notice != null)
                  KitNotice(
                    key: const ValueKey('factsbook-capture-notice'),
                    tone: _kept ? AppStatusTone.neutral : AppStatusTone.ok,
                    icon: _kept ? AppIconography.info : AppIconography.check,
                    message: _notice!,
                    actions: [
                      if (_kept)
                        KitAction(
                          key: const ValueKey('factsbook-capture-see-kept'),
                          label: l10n.fbCaptureSeeNotSaved,
                          onPressed: () =>
                              unawaited(openFactsBookNotSaved(context)),
                        ),
                      if (_seeNeedsYou)
                        KitAction(
                          key: const ValueKey(
                            'factsbook-capture-see-needs-you',
                          ),
                          label: l10n.fbCaptureSeeNeedsYou,
                          onPressed: () =>
                              unawaited(openFactsBookNeedsYou(context)),
                        ),
                    ],
                    onDismiss: () => setState(() => _notice = null),
                    dismissLabel: l10n.fbDismiss,
                  ),
                KitText(
                  l10n.fbCaptureFootnote,
                  role: KitTextRole.secondary,
                  tone: KitTextTone.secondary,
                ),
              ],
            ),
          ),
        ],
      ),
      bottom: KitActionBlock(
        primary: KitAction(
          key: const ValueKey('factsbook-capture-save'),
          label: l10n.fbCaptureSave,
          working: _working,
          onPressed: _canSave ? () => unawaited(_save()) : null,
          disabledReason: _canSave ? null : l10n.fbCaptureNeedsText,
        ),
      ),
    );
  }
}
