import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/factsbook/factsbook_trigger_types.dart';
import '../../../domain/factsbook/factsbook_types.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/factsbook/factsbook_controller.dart';
import '../../app_iconography.dart';
import '../../kit/kit.dart';
import 'factsbook_routes.dart';
import 'factsbook_text.dart';
import 'trigger_text.dart';

/// Rule editor (spec 44, "Rule editor"): a rule in plain words. When the
/// message is a shared text, a saved chat or a note; says something like one
/// kind of message (and optionally some words); then it proposes a reminder
/// and/or offers a chat. "Try it on a sample" asks the node what the saved
/// rule would do, and saves nothing. A rule is signed by this phone's
/// approval key; one that changed on the node meanwhile is reloaded, never
/// overwritten.
class FactsBookRuleEditorScreen extends ConsumerStatefulWidget {
  const FactsBookRuleEditorScreen({super.key, this.rule});

  /// Null for a new rule.
  final Rule? rule;

  @override
  ConsumerState<FactsBookRuleEditorScreen> createState() =>
      _FactsBookRuleEditorScreenState();
}

class _FactsBookRuleEditorScreenState
    extends ConsumerState<FactsBookRuleEditorScreen> {
  final _name = TextEditingController();
  final _words = TextEditingController();
  final _sender = TextEditingController();
  List<String> _areaChoices = const ['general'];
  final _sample = TextEditingController();

  /// The rule as the node holds it; null until a new rule is first saved.
  Rule? _saved;
  var _kind = TriggerSourceKind.share;
  var _template = TriggerTemplateId.appointment;
  var _locale = 'en';
  var _reminder = true;
  var _conversation = false;
  var _enabled = true;
  var _limit = 20;
  var _area = 'general';
  List<TriggerOutcome> _kept = const [];
  TriggerSource? _source;

  bool _saving = false;
  bool _testing = false;
  String? _problem;
  String? _notice;
  bool _noticeIsGood = false;
  RuleTestResult? _result;
  Object? _testFailure;

  Future<void> _loadAreas() async {
    try {
      final areas = await _controller.areas();
      final normal = [
        for (final a in areas)
          if (!a.sensitiveStorage) a.slug,
      ];
      if (mounted && normal.isNotEmpty) {
        setState(() => _areaChoices = {...normal, _area}.toList());
      }
    } on FactsBookException {
      // The area stays as it is; the node checks it again on save.
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadAreas());
    });
    final rule = widget.rule;
    if (rule != null) {
      _load(rule);
    } else {
      final app = WidgetsBinding.instance.platformDispatcher.locale;
      _locale = app.languageCode == 'ar' ? 'ar' : 'en';
      _reminder = true;
      _conversation = true;
    }
  }

  void _load(Rule rule) {
    final d = rule.definition;
    _saved = rule;
    _name.text = d.name;
    _words.text = d.containsAll.join(', ');
    _sender.text = d.senderClaim ?? '';
    _kind = d.source.kind;
    _source = d.source;
    _template = d.template.id;
    _locale = d.template.locale;
    _reminder = d.hasOutcome(TriggerOutcomeKind.reminder);
    _conversation = d.hasOutcome(TriggerOutcomeKind.conversation);
    _kept = [
      for (final o in d.outcomes)
        if (o.kind == TriggerOutcomeKind.fact) o,
    ];
    _enabled = d.enabled;
    _limit = d.limitPerDay;
    _area = d.area;
  }

  @override
  void dispose() {
    _name.dispose();
    _words.dispose();
    _sender.dispose();
    _sample.dispose();
    super.dispose();
  }

  FactsBookController get _controller => ref.read(factsBookControllerProvider);

  TriggerSource _sourceNow() {
    final existing = _source;
    if (existing != null && existing.kind == _kind) return existing;
    return TriggerSource(
      clientId:
          _controller.session.link?.clientId ??
          _saved?.definition.source.clientId ??
          '',
      kind: _kind,
      instance: _kind.defaultInstance,
    );
  }

  RuleDefinition _definition() => RuleDefinition(
    name: _name.text.trim(),
    enabled: _enabled,
    source: _sourceNow(),
    template: TriggerTemplate(id: _template, locale: _locale),
    area: _area,
    containsAll: RuleRules.splitWords(_words.text),
    senderClaim: _sender.text.trim().isEmpty ? null : _sender.text.trim(),
    outcomes: [
      if (_reminder) const TriggerOutcome(TriggerOutcomeKind.reminder),
      ..._kept,
      if (_conversation) const TriggerOutcome(TriggerOutcomeKind.conversation),
    ],
    limitPerDay: _limit,
  );

  bool get _dirty {
    final saved = _saved;
    if (saved == null) return true;
    return jsonEncode(_definition().toJson()) !=
        jsonEncode(saved.definition.toJson());
  }

  void _edited() => setState(() {
    _problem = null;
    _result = null;
    _testFailure = null;
  });

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final triggers = _controller.triggers;
    final definition = _definition();
    final problems = RuleRules.check(
      definition,
      templates: triggers.templates.toSet(),
    );
    if (problems.isNotEmpty) {
      setState(() => _problem = problemWords(l10n, problems.first));
      return;
    }
    setState(() {
      _saving = true;
      _problem = null;
      _notice = null;
    });
    try {
      final rule = await triggers.saveRule(definition, replacing: _saved);
      if (!mounted) return;
      setState(() {
        _saved = rule;
        _source = rule.definition.source;
        _noticeIsGood = true;
        _notice = l10n.fbRuleSaved;
      });
    } on FactsBookException catch (failure) {
      if (!mounted) return;
      if (failure.stale) {
        // Show what the node holds now, and let the person decide again.
        final current = triggers.ruleById(_saved?.id ?? '');
        setState(() {
          if (current != null) _load(current);
          _noticeIsGood = false;
          _notice = l10n.fbRuleStale;
        });
      } else {
        setState(() {
          _noticeIsGood = false;
          _notice = failureWords(l10n, failure);
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final rule = _saved;
    if (rule == null) return;
    final l10n = AppLocalizations.of(context);
    final navigator = Navigator.of(context);
    final ok = await showKitConfirm(
      context,
      title: l10n.fbRuleDeleteTitle,
      body: l10n.fbRuleDeleteBody(rule.definition.name),
      confirmLabel: l10n.fbRuleDelete,
      kind: KitConfirmKind.destructive,
    );
    if (!ok || !mounted) return;
    setState(() => _saving = true);
    try {
      await _controller.triggers.deleteRule(rule);
      if (mounted) navigator.pop();
    } on FactsBookException catch (failure) {
      if (!mounted) return;
      setState(() {
        _noticeIsGood = false;
        _notice = failure.stale
            ? l10n.fbRuleStale
            : failureWords(l10n, failure);
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _test() async {
    if (_sample.text.trim().isEmpty) return;
    final d = _definition();
    setState(() {
      _testing = true;
      _result = null;
      _testFailure = null;
    });
    try {
      // A draft is tested as it stands, saved or not; nothing is written.
      final result = await _controller.triggers.testDraft(
        d,
        TriggerSample(
          kind: d.source.kind,
          text: _sample.text.trim(),
          area: d.area,
          locale: d.template.locale,
          sourceInstance: d.source.instance,
        ),
      );
      if (mounted) setState(() => _result = result);
    } on FactsBookException catch (failure) {
      if (mounted) setState(() => _testFailure = failure);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  void _useExample() {
    _sample.text = sampleExample(
      TriggerTemplate(id: _template, locale: _locale),
      clock.now(),
    );
    setState(() {
      _result = null;
      _testFailure = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final controller = ref.watch(factsBookControllerProvider);
    controller.session.approvalReason = l10n.fbAuthReason;
    final triggers = controller.triggers;
    final canChange = controller.session.canApprove;
    final rails = EdgeInsetsDirectional.symmetric(horizontal: tokens.gutter);
    final saved = _saved;
    final dirty = _dirty;
    final templates = triggers.templates;
    return KitScreen(
      topBar: KitTopBar(
        title: saved == null ? l10n.fbRuleNewTitle : l10n.fbRuleEditTitle,
        subtitle: saved == null
            ? null
            : bidiName(context, saved.definition.name),
      ),
      width: KitScreenWidth.reading,
      loading: _saving,
      loadingLabel: l10n.fbRuleSave,
      body: ListView(
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
                key: const ValueKey('factsbook-rule-needs-owner'),
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
                key: const ValueKey('factsbook-rule-notice'),
                icon: _noticeIsGood
                    ? AppIconography.check
                    : AppIconography.info,
                message: _notice!,
                onDismiss: () => setState(() => _notice = null),
                dismissLabel: l10n.fbDismiss,
              ),
            ),
          Padding(
            padding: rails,
            child: KitField(
              fieldKey: const ValueKey('factsbook-rule-name'),
              controller: _name,
              label: l10n.fbRuleNameLabel,
              hint: l10n.fbRuleNameHint,
              enabled: canChange,
              disabledReason: canChange ? null : l10n.fbCareNeedsOwnerShort,
              onChanged: (_) => _edited(),
            ),
          ),
          KitSectionLabel(l10n.fbRuleWhen),
          Padding(
            padding: rails,
            child: KitSegmented<TriggerSourceKind>(
              semanticsLabel: l10n.fbRuleWhenLabel,
              selected: _kind,
              onChanged: canChange
                  ? (kind) {
                      _kind = kind;
                      _edited();
                    }
                  : null,
              disabledReason: canChange ? null : l10n.fbCareNeedsOwnerShort,
              segments: [
                KitSegment(
                  key: const ValueKey('factsbook-rule-kind-share'),
                  value: TriggerSourceKind.share,
                  label: l10n.fbSourceKindShare,
                ),
                KitSegment(
                  key: const ValueKey('factsbook-rule-kind-chat'),
                  value: TriggerSourceKind.chatSelection,
                  label: l10n.fbSourceKindChat,
                ),
                KitSegment(
                  key: const ValueKey('factsbook-rule-kind-note'),
                  value: TriggerSourceKind.note,
                  label: l10n.fbSourceKindNote,
                ),
              ],
            ),
          ),
          KitSectionLabel(l10n.fbRuleSays),
          KitRowGroup(
            leadingIcons: false,
            children: [
              KitPickerRow<TriggerTemplateId>(
                rowKey: const ValueKey('factsbook-rule-template'),
                title: l10n.fbRuleTemplateLabel,
                selected: _template,
                valueLabel: templateWords(l10n, _template),
                choices: [
                  for (final id in {...templates, _template})
                    KitChoice(value: id, title: templateWords(l10n, id)),
                ],
                onSelected: canChange
                    ? (id) {
                        _template = id;
                        _edited();
                      }
                    : null,
                disabledReason: canChange ? null : l10n.fbCareNeedsOwnerShort,
              ),
              KitPickerRow<String>(
                rowKey: const ValueKey('factsbook-rule-language'),
                title: l10n.fbRuleLanguageLabel,
                selected: _locale,
                valueLabel: _locale == 'ar'
                    ? l10n.fbRuleLangAr
                    : l10n.fbRuleLangEn,
                choices: [
                  KitChoice(value: 'en', title: l10n.fbRuleLangEn),
                  KitChoice(value: 'ar', title: l10n.fbRuleLangAr),
                ],
                onSelected: canChange
                    ? (value) {
                        _locale = value;
                        _edited();
                      }
                    : null,
                disabledReason: canChange ? null : l10n.fbCareNeedsOwnerShort,
              ),
            ],
          ),
          KitGroupNote(message: l10n.fbRuleTemplateHelp),
          Padding(
            padding: rails,
            child: KitField(
              fieldKey: const ValueKey('factsbook-rule-words'),
              controller: _words,
              label: l10n.fbRuleWordsLabel,
              helper: l10n.fbRuleWordsHelp,
              enabled: canChange,
              disabledReason: canChange ? null : l10n.fbCareNeedsOwnerShort,
              onChanged: (_) => _edited(),
            ),
          ),
          Padding(
            padding: rails.add(EdgeInsetsDirectional.only(top: tokens.space3)),
            child: KitField(
              fieldKey: const ValueKey('factsbook-rule-sender'),
              controller: _sender,
              label: l10n.fbRuleSenderLabel,
              helper: l10n.fbRuleSenderHelp,
              enabled: canChange,
              disabledReason: canChange ? null : l10n.fbCareNeedsOwnerShort,
              onChanged: (_) => _edited(),
            ),
          ),
          KitSectionLabel(l10n.fbRuleThen),
          KitRowGroup(
            leadingIcons: false,
            children: [
              KitSwitchRow(
                switchKey: const ValueKey('factsbook-rule-reminder'),
                title: l10n.fbRuleOutcomeReminder,
                supporting: l10n.fbRuleOutcomeReminderDetail,
                value: _reminder,
                onChanged: canChange
                    ? (v) {
                        _reminder = v;
                        _edited();
                      }
                    : null,
                disabledReason: canChange ? null : l10n.fbCareNeedsOwnerShort,
              ),
              KitSwitchRow(
                switchKey: const ValueKey('factsbook-rule-conversation'),
                title: l10n.fbRuleOutcomeConversation,
                supporting: l10n.fbRuleOutcomeConversationDetail,
                value: _conversation,
                onChanged: canChange && triggers.offersSupported
                    ? (v) {
                        _conversation = v;
                        _edited();
                      }
                    : null,
                disabledReason: canChange
                    ? l10n.fbRuleOfferUnavailable
                    : l10n.fbCareNeedsOwnerShort,
              ),
              KitSwitchRow(
                switchKey: const ValueKey('factsbook-rule-autostart'),
                title: l10n.fbRuleAutoStart,
                value: false,
                // The contract allows only false in this milestone, whatever
                // the matrix says; the reason says why.
                onChanged: null,
                disabledReason: l10n.fbRuleAutoStartOff,
              ),
            ],
          ),
          if (_kept.isNotEmpty)
            KitGroupNote(message: l10n.fbRuleOutcomeFactKept),
          KitRowGroup(
            leadingIcons: false,
            children: [
              KitPickerRow<String>(
                rowKey: const ValueKey('factsbook-rule-area'),
                title: l10n.fbRuleAreaLabel,
                selected: _area,
                valueLabel: areaName(l10n, _area),
                choices: [
                  for (final slug in _areaChoices)
                    KitChoice(value: slug, title: areaName(l10n, slug)),
                ],
                onSelected: canChange
                    ? (slug) {
                        _area = slug;
                        _edited();
                      }
                    : null,
                disabledReason: canChange ? null : l10n.fbCareNeedsOwnerShort,
              ),
              KitPickerRow<int>(
                rowKey: const ValueKey('factsbook-rule-limit'),
                title: l10n.fbRuleLimit,
                selected: _limit,
                valueLabel: l10n.fbRuleLimitValue(_limit),
                choices: [
                  for (final n in {1, 3, 5, 10, 20, _limit}.toList()..sort())
                    KitChoice(value: n, title: l10n.fbRuleLimitValue(n)),
                ],
                onSelected: canChange
                    ? (n) {
                        _limit = n;
                        _edited();
                      }
                    : null,
                disabledReason: canChange ? null : l10n.fbCareNeedsOwnerShort,
              ),
              KitSwitchRow(
                switchKey: const ValueKey('factsbook-rule-enabled'),
                title: l10n.fbRuleOn,
                supporting: l10n.fbRuleOnDetail,
                value: _enabled,
                onChanged: canChange
                    ? (v) {
                        _enabled = v;
                        _edited();
                      }
                    : null,
                disabledReason: canChange ? null : l10n.fbCareNeedsOwnerShort,
              ),
            ],
          ),
          if (_problem != null)
            Padding(
              padding: rails.add(
                EdgeInsetsDirectional.only(top: tokens.space3),
              ),
              child: KitNotice(
                key: const ValueKey('factsbook-rule-problem'),
                icon: AppIconography.info,
                message: _problem!,
              ),
            ),
          KitSectionLabel(l10n.fbRuleTest),
          _testSection(context, l10n, tokens, saved, dirty),
          if (saved != null)
            Padding(
              padding: rails.add(
                EdgeInsetsDirectional.only(top: tokens.space4),
              ),
              child: KitButton.fromAction(
                KitAction(
                  key: const ValueKey('factsbook-rule-delete'),
                  label: l10n.fbRuleDelete,
                  icon: AppIconography.delete,
                  destructive: true,
                  onPressed: canChange && !_saving
                      ? () => unawaited(_delete())
                      : null,
                  disabledReason: canChange ? null : l10n.fbCareNeedsOwnerShort,
                ),
                role: KitButtonRole.secondary,
                expand: false,
              ),
            ),
        ],
      ),
      bottom: KitActionBlock(
        primary: KitAction(
          key: const ValueKey('factsbook-rule-save'),
          label: l10n.fbRuleSave,
          working: _saving,
          onPressed: canChange && !_saving && dirty
              ? () => unawaited(_save())
              : null,
          disabledReason: canChange ? null : l10n.fbCareNeedsOwnerShort,
        ),
      ),
    );
  }

  Widget _testSection(
    BuildContext context,
    AppLocalizations l10n,
    KitTokens tokens,
    Rule? saved,
    bool dirty,
  ) {
    final rails = EdgeInsetsDirectional.symmetric(horizontal: tokens.gutter);
    final problems = RuleRules.check(_definition());
    final canTest = problems.isEmpty;
    final reason = canTest ? null : problemWords(l10n, problems.first);
    final result = _result;
    return Padding(
      padding: rails,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.space2,
        children: [
          KitField(
            fieldKey: const ValueKey('factsbook-rule-sample'),
            controller: _sample,
            label: l10n.fbRuleSampleLabel,
            kind: KitFieldKind.multiline,
            enabled: canTest,
            disabledReason: reason,
            onChanged: (_) => setState(() {
              _result = null;
              _testFailure = null;
            }),
          ),
          Wrap(
            spacing: tokens.space2,
            runSpacing: tokens.space2,
            children: [
              KitButton.fromAction(
                KitAction(
                  key: const ValueKey('factsbook-rule-example'),
                  label: l10n.fbRuleSampleExample,
                  onPressed: canTest ? _useExample : null,
                  disabledReason: reason,
                ),
                role: KitButtonRole.secondary,
                expand: false,
              ),
              KitButton.fromAction(
                KitAction(
                  key: const ValueKey('factsbook-rule-test'),
                  label: result == null
                      ? l10n.fbRuleTestRun
                      : l10n.fbRuleTestAgain,
                  working: _testing,
                  onPressed:
                      canTest && !_testing && _sample.text.trim().isNotEmpty
                      ? () => unawaited(_test())
                      : null,
                  disabledReason: reason,
                ),
                role: KitButtonRole.secondary,
                expand: false,
              ),
            ],
          ),
          KitText(
            l10n.fbRuleTestDraftNote,
            role: KitTextRole.caption,
            tone: KitTextTone.secondary,
          ),
          if (_testFailure != null)
            KitNotice(
              key: const ValueKey('factsbook-rule-test-failed'),
              icon: AppIconography.info,
              message: failureWords(l10n, _testFailure),
            ),
          if (result != null) _resultNotice(context, l10n, saved, result),
        ],
      ),
    );
  }

  Widget _resultNotice(
    BuildContext context,
    AppLocalizations l10n,
    Rule? saved,
    RuleTestResult result,
  ) {
    if (!result.matched) {
      return KitNotice(
        key: const ValueKey('factsbook-rule-test-result'),
        icon: AppIconography.info,
        message:
            '${l10n.fbRuleTestNoMatch} ${triggerReasonWords(l10n, result.reason)}',
      );
    }
    final what = result.summary;
    final when = result.when;
    final found = what == null
        ? l10n.fbRuleTestMatchPlain
        : l10n.fbRuleTestMatch(
            bidiName(context, what),
            when == null ? '' : isoWhenWords(context, when),
          );
    final outcomes = outcomesLine(l10n, _definition().outcomes);
    return KitNotice(
      key: const ValueKey('factsbook-rule-test-result'),
      icon: AppIconography.check,
      message: outcomes.isEmpty
          ? found
          : '$found ${l10n.fbRuleTestWould(outcomes)}',
    );
  }
}
