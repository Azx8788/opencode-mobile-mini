import 'package:clock/clock.dart';

import 'factsbook_capabilities.dart';
import 'factsbook_trigger_types.dart';
import 'factsbook_types.dart';

/// The trigger half of the in-memory node (spec 44). Synthetic data only.
/// It behaves like the node where the app depends on it: a rule is replaced
/// only at the revision the person saw, a test reads the real one-line
/// grammar and writes nothing, a reminder proposal and an offer are decided
/// only against the digest they were shown, and an accepted offer keeps one
/// receipt per receipt key.
mixin FakeTriggerNode {
  bool get reachable;

  /// When false the node answers like one without triggers: `not_found`.
  bool triggersAvailable = true;

  final List<Rule> rulesList = [];
  final List<TriggerEvent> eventsList = [];
  final List<TriggerFiring> firingsList = [];
  final List<ReminderProposal> proposalsList = [];
  final List<ConversationOffer> offersList = [];
  final Map<String, StartReceipt> _receipts = {};
  var _triggerSerial = 500;

  /// The calls the app made, for tests (`rule.save`, `offer.accept`, ...).
  final triggerCalls = <String>[];

  /// What `capabilities()` answers; null means the node has no such endpoint
  /// (it answers `not_found`, like a node before B5).
  FactsBookCapabilities? nodeCapabilities = FactsBookCapabilities.b5;

  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  static String triggerId(String prefix, int n) {
    var rest = n;
    final out = StringBuffer();
    for (var i = 0; i < 26; i++) {
      out.write(_alphabet[rest % 32]);
      rest ~/= 32;
    }
    return '${prefix}_${out.toString().split('').reversed.join()}';
  }

  String _nextTrigger(String prefix) => triggerId(prefix, _triggerSerial++);

  void _need() {
    if (!reachable) throw const FactsBookException('node_unreachable');
    if (!triggersAvailable) {
      throw const FactsBookException('not_found', status: 404);
    }
  }

  /// A node with two rules, three events (one matched, one abstained, one
  /// capped), a reminder proposal and a conversation offer.
  void seedTriggers({String clientId = 'cli_00000000000000000000000001'}) {
    final now = clock.now();
    TriggerSource source(TriggerSourceKind kind, String instance) =>
        TriggerSource(clientId: clientId, kind: kind, instance: instance);
    final library = Rule(
      id: triggerId('rul', 5),
      revision: 1,
      updatedAt: now.subtract(const Duration(days: 3)),
      definition: RuleDefinition(
        name: 'Library appointments',
        enabled: true,
        source: source(TriggerSourceKind.share, 'manual-share'),
        template: const TriggerTemplate(id: TriggerTemplateId.appointment),
        area: 'general',
        containsAll: const [],
        outcomes: const [
          TriggerOutcome(TriggerOutcomeKind.reminder),
          TriggerOutcome(TriggerOutcomeKind.conversation),
        ],
        limitPerDay: 20,
      ),
    );
    final landlord = Rule(
      id: triggerId('rul', 6),
      revision: 2,
      updatedAt: now.subtract(const Duration(days: 1)),
      definition: RuleDefinition(
        name: 'Delivery notes',
        enabled: false,
        source: source(TriggerSourceKind.chatSelection, 'selected-chat'),
        template: const TriggerTemplate(id: TriggerTemplateId.delivery),
        area: 'general',
        containsAll: const ['parcel'],
        outcomes: const [TriggerOutcome(TriggerOutcomeKind.reminder)],
        limitPerDay: 5,
      ),
    );
    rulesList.addAll([library, landlord]);

    final matched = TriggerEvent(
      id: triggerId('evt', 6),
      revision: 1,
      source: library.definition.source,
      claims: const EventClaims(sender: 'Sam'),
      trust: EventTrust.thirdPartyUntrusted,
      area: 'general',
      sensitive: false,
      capturedAt: now.subtract(const Duration(hours: 2)),
      state: EventProcessingState.evaluated,
      reason: TriggerReason.matched,
      firings: [triggerId('trg', 7)],
    );
    final abstained = TriggerEvent(
      id: triggerId('evt', 7),
      revision: 1,
      source: library.definition.source,
      claims: const EventClaims(),
      trust: EventTrust.thirdPartyUntrusted,
      area: 'general',
      sensitive: true,
      capturedAt: now.subtract(const Duration(days: 1)),
      state: EventProcessingState.abstained,
      reason: TriggerReason.uncertain,
      firings: const [],
    );
    final capped = TriggerEvent(
      id: triggerId('evt', 8),
      revision: 1,
      source: library.definition.source,
      claims: const EventClaims(),
      trust: EventTrust.thirdPartyUntrusted,
      area: 'general',
      sensitive: false,
      capturedAt: now.subtract(const Duration(days: 2)),
      state: EventProcessingState.capped,
      reason: TriggerReason.ruleCap,
      firings: [triggerId('trg', 8)],
    );
    eventsList.addAll([matched, abstained, capped]);

    firingsList.addAll([
      TriggerFiring(
        id: triggerId('trg', 7),
        eventId: matched.id,
        ruleId: library.id,
        ruleRevision: 1,
        template: library.definition.template,
        at: matched.capturedAt,
        state: FiringState.proposed,
        outcomes: [triggerId('rvw', 9), triggerId('ofr', 8)],
      ),
      TriggerFiring(
        id: triggerId('trg', 8),
        eventId: capped.id,
        ruleId: library.id,
        ruleRevision: 1,
        template: library.definition.template,
        at: capped.capturedAt,
        state: FiringState.capped,
        outcomes: const [],
      ),
    ]);

    final when = DateTime(now.year, now.month, now.day + 4, 9);
    String two(int n) => n.toString().padLeft(2, '0');
    final date = '${when.year}-${two(when.month)}-${two(when.day)}';
    final preview = <String, Object?>{
      'what': 'Library visit',
      'date': date,
      'time': '09:00',
      'zone': 'vault',
      'locale': 'en',
      'repeat': null,
      'ambiguities': <String>[],
      'schedule': {
        'v': 1,
        'id': triggerId('sch', 9),
        'when': {'once': '${date}T09:00'},
        'zone': 'vault',
        'window': null,
        'catchup': 'coalesce',
      },
      'adjustments': <String>[],
      'settings_rev': 1,
      'effective_zone': 'UTC',
      'area': 'general',
      'sens': 'normal',
      'preview_digest': 'a' * 64,
    };
    proposalsList.add(
      ReminderProposal(
        id: triggerId('rvw', 9),
        revision: 1,
        eventId: matched.id,
        firingId: triggerId('trg', 7),
        area: 'general',
        preview: ReminderPreview.fromJson(preview),
        digest: 'b' * 64,
        state: ProposalState.proposed,
      ),
    );
    offersList.add(
      ConversationOffer(
        id: triggerId('ofr', 8),
        revision: 1,
        eventId: matched.id,
        firingId: triggerId('trg', 7),
        area: 'general',
        summary: 'Library visit',
        digest: 'c' * 64,
        state: OfferState.offered,
        expiresAt: now.add(const Duration(hours: 22)),
      ),
    );
  }

  // --- Rules ----------------------------------------------------------------

  Future<List<Rule>> rules() async {
    _need();
    return [
      for (final r in rulesList)
        if (!r.deleted) r,
    ];
  }

  Future<Rule> saveRule(RuleDefinition definition, {Rule? replacing}) async {
    triggerCalls.add(replacing == null ? 'rule.create' : 'rule.replace');
    _need();
    if (RuleRules.check(definition).isNotEmpty) {
      throw const FactsBookException('bad_request', status: 400);
    }
    if (replacing == null) {
      if (rulesList.where((r) => !r.deleted).length >= RuleRules.maxRules) {
        throw const FactsBookException('bad_request', status: 400);
      }
      final rule = Rule(
        id: _nextTrigger('rul'),
        revision: 1,
        definition: definition,
        updatedAt: clock.now(),
      );
      rulesList.add(rule);
      return rule;
    }
    final index = rulesList.indexWhere((r) => r.id == replacing.id);
    if (index < 0) throw const FactsBookException('not_found', status: 404);
    if (rulesList[index].revision != replacing.revision) {
      throw const FactsBookException('conflict', status: 409);
    }
    final rule = Rule(
      id: replacing.id,
      revision: replacing.revision + 1,
      definition: definition,
      updatedAt: clock.now(),
    );
    rulesList[index] = rule;
    return rule;
  }

  Future<Rule> deleteRule(Rule rule) async {
    triggerCalls.add('rule.delete');
    _need();
    final index = rulesList.indexWhere((r) => r.id == rule.id);
    if (index < 0) throw const FactsBookException('not_found', status: 404);
    if (rulesList[index].revision != rule.revision) {
      throw const FactsBookException('conflict', status: 409);
    }
    final gone = Rule(
      id: rule.id,
      revision: rule.revision + 1,
      definition: rule.definition,
      updatedAt: clock.now(),
      deleted: true,
    );
    rulesList[index] = gone;
    return gone;
  }

  static const _labels = {
    'en': {
      TriggerTemplateId.appointment: 'appointment',
      TriggerTemplateId.delivery: 'delivery',
      TriggerTemplateId.booking: 'booking',
      TriggerTemplateId.subscription: 'subscription renewal',
      TriggerTemplateId.billDue: 'bill due',
    },
    'ar': {
      TriggerTemplateId.appointment: 'موعد',
      TriggerTemplateId.delivery: 'توصيل',
      TriggerTemplateId.booking: 'حجز',
      TriggerTemplateId.subscription: 'تجديد اشتراك',
      TriggerTemplateId.billDue: 'استحقاق فاتورة',
    },
  };

  static String _digits(String text) {
    const arabic = '٠١٢٣٤٥٦٧٨٩';
    const persian = '۰۱۲۳۴۵۶۷۸۹';
    final out = StringBuffer();
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      final a = arabic.indexOf(ch);
      final p = persian.indexOf(ch);
      out.write(a >= 0 ? '$a' : (p >= 0 ? '$p' : ch));
    }
    return out.toString();
  }

  /// Reads the version-1 grammar: one line `<label>: <title> | YYYY-MM-DDTHH:MM`.
  Future<RuleTestResult> testRule(Rule rule, TriggerSample sample) async {
    triggerCalls.add('rule.test');
    _need();
    final index = rulesList.indexWhere((r) => r.id == rule.id);
    if (index < 0) throw const FactsBookException('not_found', status: 404);
    return _evaluate(rulesList[index].definition, sample);
  }

  Future<RuleTestResult> testDraft(
    RuleDefinition draft,
    TriggerSample sample,
  ) async {
    triggerCalls.add('rule.testDraft');
    _need();
    if (RuleRules.check(draft).isNotEmpty) {
      throw const FactsBookException('bad_request', status: 400);
    }
    return _evaluate(draft, sample);
  }

  Future<FactsBookCapabilities> capabilities() async {
    if (!reachable) throw const FactsBookException('node_unreachable');
    final caps = nodeCapabilities;
    if (caps == null) throw const FactsBookException('not_found', status: 404);
    return caps;
  }

  RuleTestResult _evaluate(RuleDefinition stored, TriggerSample sample) {
    RuleTestResult miss(TriggerReason reason) =>
        RuleTestResult(matched: false, reason: reason);
    if (!stored.enabled) return miss(TriggerReason.noEnabledRule);
    if (sample.kind != stored.source.kind) return miss(TriggerReason.noMatch);
    final claim = stored.senderClaim;
    if (claim != null &&
        (sample.claims.sender ?? '').trim().toLowerCase() !=
            claim.trim().toLowerCase()) {
      return miss(TriggerReason.noMatch);
    }
    final text = sample.text.trim();
    if (text.contains('\n') || text.isEmpty) {
      return miss(TriggerReason.uncertain);
    }
    final pattern = RegExp(r'^([^:]+):\s*(.+?)\s*\|\s*(\S+)$');
    final match = pattern.firstMatch(_digits(text));
    if (match == null) return miss(TriggerReason.uncertain);
    final label = match.group(1)!.trim().toLowerCase();
    final wanted = _labels[stored.template.locale]![stored.template.id]!;
    if (label != wanted) return miss(TriggerReason.noMatch);
    final when = RegExp(
      r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$',
    ).hasMatch(match.group(3)!);
    if (!when) return miss(TriggerReason.uncertain);
    final lowered = text.toLowerCase();
    for (final word in stored.containsAll) {
      if (!lowered.contains(word.toLowerCase())) {
        return miss(TriggerReason.noMatch);
      }
    }
    return RuleTestResult(
      matched: true,
      reason: TriggerReason.matched,
      summary: match.group(2)!.trim(),
      when: match.group(3),
    );
  }

  /// What `postEvent` was given, in order: the samples, for tests. The fake
  /// answers metadata only, like the node.
  final postedEvents = <TriggerSample>[];
  final Map<String, TriggerEvent> _eventKeys = {};

  /// When set, `postEvent` fails like this (the capture must still stand).
  FactsBookException? eventFailure;

  /// Whether each posted event carried the owner's signed classification.
  final postedClassified = <bool>[];

  Future<TriggerEvent> postEvent(
    TriggerSample sample, {
    required String idempotencyKey,
    bool classifyNormal = false,
  }) async {
    triggerCalls.add('event.post');
    _need();
    final failure = eventFailure;
    if (failure != null) throw failure;
    final seen = _eventKeys[idempotencyKey];
    if (seen != null) return seen;
    postedEvents.add(sample);
    postedClassified.add(classifyNormal);
    final id = _nextTrigger('evt');
    // A share or selected chat is kept encrypted and ignored by rules unless
    // the owner signed that it is ordinary.
    final protected = sample.kind != TriggerSourceKind.note && !classifyNormal;
    final now = clock.now();
    final firingIds = <String>[];
    var reason = TriggerReason.noEnabledRule;
    for (final rule in protected ? const <Rule>[] : rulesList) {
      if (rule.deleted || !rule.definition.enabled) continue;
      if (rule.definition.source.kind != sample.kind) continue;
      final result = _evaluate(rule.definition, sample);
      reason = result.reason;
      if (!result.matched) continue;
      final firing = _nextTrigger('trg');
      firingIds.add(firing);
      firingsList.add(
        TriggerFiring(
          id: firing,
          eventId: id,
          ruleId: rule.id,
          ruleRevision: rule.revision,
          template: rule.definition.template,
          at: now,
          state: FiringState.proposed,
          outcomes: const [],
        ),
      );
    }
    final event = TriggerEvent(
      id: id,
      revision: sample.revision,
      source: TriggerSource(
        clientId: 'cli_00000000000000000000000001',
        kind: sample.kind,
        instance: sample.sourceInstance,
      ),
      claims: sample.claims,
      trust: sample.kind == TriggerSourceKind.note
          ? EventTrust.userAuthored
          : (sample.kind == TriggerSourceKind.chatSelection
                ? EventTrust.userSelected
                : EventTrust.thirdPartyUntrusted),
      area: sample.area,
      sensitive: false,
      capturedAt: now,
      state: firingIds.isEmpty
          ? EventProcessingState.abstained
          : EventProcessingState.evaluated,
      reason: protected
          ? TriggerReason.uncertain
          : (firingIds.isEmpty ? reason : TriggerReason.matched),
      firings: firingIds,
      evidenceRef: _nextTrigger('itm'),
    );
    eventsList.add(event);
    _eventKeys[idempotencyKey] = event;
    return event;
  }

  // --- Events, firings -------------------------------------------------------

  Future<List<TriggerEvent>> events() async {
    _need();
    return [...eventsList];
  }

  Future<TriggerEvent> event(String id) async {
    _need();
    for (final e in eventsList) {
      if (e.id == id) return e;
    }
    throw const FactsBookException('not_found', status: 404);
  }

  Future<List<TriggerFiring>> firings() async {
    _need();
    return [...firingsList];
  }

  // --- Reminder proposals ----------------------------------------------------

  Future<List<ReminderProposal>> reminderProposals() async {
    _need();
    return [
      for (final p in proposalsList)
        if (p.state == ProposalState.proposed) p,
    ];
  }

  Future<MutationResult> decideReminderProposal(
    ReminderProposal proposal,
    ProposalDecision decision,
  ) async {
    triggerCalls.add('proposal:${decision.name}');
    _need();
    final index = proposalsList.indexWhere((p) => p.id == proposal.id);
    if (index < 0) throw const FactsBookException('not_found', status: 404);
    final stored = proposalsList[index];
    if (stored.revision != proposal.revision ||
        stored.digest != proposal.digest ||
        stored.state != ProposalState.proposed) {
      throw const FactsBookException('stale_approval', status: 412);
    }
    if (decision == ProposalDecision.skip) {
      return MutationResult(status: 'skipped', id: stored.id);
    }
    proposalsList[index] = ReminderProposal(
      id: stored.id,
      revision: stored.revision + 1,
      eventId: stored.eventId,
      firingId: stored.firingId,
      area: stored.area,
      preview: stored.preview,
      digest: stored.digest,
      state: decision == ProposalDecision.confirm
          ? ProposalState.confirmed
          : ProposalState.rejected,
    );
    return MutationResult(status: 'ok', id: stored.id);
  }

  Future<MutationResult> editReminderProposal(
    ReminderProposal proposal,
    ReminderPreview preview,
  ) async {
    triggerCalls.add('proposal:edit');
    _need();
    final index = proposalsList.indexWhere((p) => p.id == proposal.id);
    if (index < 0) throw const FactsBookException('not_found', status: 404);
    final stored = proposalsList[index];
    if (stored.revision != proposal.revision ||
        stored.digest != proposal.digest ||
        stored.state != ProposalState.proposed) {
      throw const FactsBookException('stale_approval', status: 412);
    }
    proposalsList[index] = ReminderProposal(
      id: stored.id,
      revision: stored.revision + 1,
      eventId: stored.eventId,
      firingId: stored.firingId,
      area: stored.area,
      preview: preview,
      digest: '${stored.revision + 1}'.padLeft(64, 'e'),
      state: ProposalState.proposed,
    );
    return MutationResult(status: 'ok', id: stored.id);
  }

  // --- Offers ----------------------------------------------------------------

  Future<List<ConversationOffer>> offers() async {
    _need();
    return [...offersList];
  }

  ConversationOffer _replaceOffer(
    int index,
    OfferState state, {
    StartReceipt? receipt,
  }) {
    final old = offersList[index];
    final next = ConversationOffer(
      id: old.id,
      revision: old.revision + 1,
      eventId: old.eventId,
      firingId: old.firingId,
      area: old.area,
      summary: old.summary,
      digest: old.digest,
      state: state,
      expiresAt: old.expiresAt,
      receipt: receipt ?? old.receipt,
    );
    offersList[index] = next;
    return next;
  }

  Future<StartReceipt> acceptOffer(
    ConversationOffer offer, {
    required String receiptKey,
  }) async {
    triggerCalls.add('offer.accept');
    _need();
    final seen = _receipts['${offer.id}/$receiptKey'];
    // The same receipt key is the same accept: one receipt, never two.
    if (seen != null) return seen;
    final index = offersList.indexWhere((o) => o.id == offer.id);
    if (index < 0) throw const FactsBookException('not_found', status: 404);
    final stored = offersList[index];
    if (stored.revision != offer.revision ||
        stored.digest != offer.digest ||
        stored.state != OfferState.offered ||
        !clock.now().isBefore(stored.expiresAt)) {
      throw const FactsBookException('stale_approval', status: 412);
    }
    final receipt = StartReceipt(
      id: _nextTrigger('run'),
      offerId: stored.id,
      receiptKey: receiptKey,
      status: StartStatus.pending,
      expiresAt: clock.now().add(const Duration(minutes: 15)),
    );
    _receipts['${offer.id}/$receiptKey'] = receipt;
    _replaceOffer(index, OfferState.pending, receipt: receipt);
    return receipt;
  }

  Future<StartReceipt> reportOffer(
    ConversationOffer offer,
    StartReceipt receipt,
    OfferReport report,
  ) async {
    triggerCalls.add('offer.report:${report.name}');
    _need();
    final index = offersList.indexWhere((o) => o.id == offer.id);
    if (index < 0) throw const FactsBookException('not_found', status: 404);
    final status = switch (report) {
      OfferReport.firstMessageSent => StartStatus.started,
      OfferReport.cancelled => StartStatus.cancelled,
      OfferReport.unknown => StartStatus.unknown,
    };
    final done = StartReceipt(
      id: receipt.id,
      offerId: receipt.offerId,
      receiptKey: receipt.receiptKey,
      status: status,
      expiresAt: receipt.expiresAt,
    );
    _receipts['${offer.id}/${receipt.receiptKey}'] = done;
    _replaceOffer(index, switch (status) {
      StartStatus.started => OfferState.started,
      StartStatus.cancelled => OfferState.cancelled,
      _ => OfferState.unknown,
    }, receipt: done);
    return done;
  }

  Future<ConversationOffer> cancelOffer(ConversationOffer offer) async {
    triggerCalls.add('offer.cancel');
    _need();
    final index = offersList.indexWhere((o) => o.id == offer.id);
    if (index < 0) throw const FactsBookException('not_found', status: 404);
    final stored = offersList[index];
    if (stored.revision != offer.revision || stored.digest != offer.digest) {
      throw const FactsBookException('stale_approval', status: 412);
    }
    return _replaceOffer(index, OfferState.cancelled);
  }
}
