import 'dart:async';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';

import '../../domain/factsbook/factsbook_capabilities.dart';
import '../../domain/factsbook/factsbook_gateway.dart';
import '../../domain/factsbook/factsbook_trigger_types.dart';
import '../../domain/factsbook/factsbook_types.dart';
import 'factsbook_session.dart';

enum TriggersLoad {
  idle,
  loading,
  ready,
  failed,

  /// The node does not offer triggers (its capability matrix does not list
  /// them, or it answered "not found"): the page says "not available yet".
  unavailable,
}

/// What the Triggers pages show and every write they make (spec 44): rules,
/// events, firings, reminder proposals and conversation offers. Every read
/// is gated on the node's capabilities; a node that lacks them is
/// [TriggersLoad.unavailable], never an error.
///
/// Nothing here holds the raw text of an event: the node does not return it.
class FactsBookTriggers extends ChangeNotifier {
  FactsBookTriggers(this._session);

  final FactsBookSession _session;

  TriggersLoad load = TriggersLoad.idle;
  List<Rule> rules = const [];
  List<TriggerEvent> events = const [];
  List<TriggerFiring> firings = const [];
  List<ReminderProposal> proposals = const [];
  List<ConversationOffer> offers = const [];
  FactsBookException? error;

  var _generation = 0;
  var _disposed = false;

  FactsBookCapabilities get _caps => _session.capabilities;

  /// Rules, events and the review of their outcomes.
  bool get supported => _caps.supports(FactsBookCapabilities.triggers);

  /// "Talk about this with your agent?" cards.
  bool get offersSupported =>
      supported && _caps.supports(FactsBookCapabilities.conversationOffers);

  /// Automatic conversation start is unavailable unless the node lists it
  /// as supported; its toggle is shown as unavailable otherwise.
  bool get autoStartSupported =>
      _caps.supports(FactsBookCapabilities.automaticConversationStart);

  /// The templates a rule may use, in the order the editor lists them.
  List<TriggerTemplateId> get templates {
    final listed = _caps.triggerTemplates;
    return [
      for (final id in TriggerTemplateId.values)
        if (id != TriggerTemplateId.billDue &&
            (listed.isEmpty || listed.contains(id.wire)))
          id,
    ];
  }

  FactsBookGateway? get _gateway => _session.gateway;

  FactsBookGateway get _node =>
      _session.gateway ?? (throw const FactsBookException('unauthorized'));

  /// Offers that can still be answered.
  List<ConversationOffer> openOffers([DateTime? now]) {
    final at = now ?? clock.now();
    return [
      for (final offer in offers)
        if (offer.isOpen(at)) offer,
    ];
  }

  void reset() {
    _generation++;
    load = TriggersLoad.idle;
    rules = const [];
    events = const [];
    firings = const [];
    proposals = const [];
    offers = const [];
    error = null;
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Reads everything the pages show. A failed read keeps the last copy.
  /// With [quiet] nothing flips to "loading" (a background refresh).
  Future<void> refresh({bool quiet = false}) async {
    if (!supported || _gateway == null) {
      load = supported ? TriggersLoad.idle : TriggersLoad.unavailable;
      _changed();
      return;
    }
    final generation = ++_generation;
    if (!quiet &&
        (load == TriggersLoad.idle ||
            load == TriggersLoad.failed ||
            load == TriggersLoad.unavailable)) {
      load = TriggersLoad.loading;
      _changed();
    }
    try {
      final node = _node;
      final newRules = await node.rules();
      final newEvents = await node.events();
      final newFirings = await node.firings();
      final newProposals = await node.reminderProposals();
      final newOffers = offersSupported
          ? await node.offers()
          : const <ConversationOffer>[];
      if (generation != _generation) return;
      rules = newRules;
      events = newEvents;
      firings = newFirings;
      proposals = newProposals;
      offers = newOffers;
      error = null;
      load = TriggersLoad.ready;
    } on FactsBookException catch (failure) {
      if (generation != _generation) return;
      if (failure.code == 'not_found' || failure.notEnabled) {
        load = TriggersLoad.unavailable;
        error = null;
      } else {
        error = failure;
        load = rules.isEmpty && load != TriggersLoad.ready
            ? TriggersLoad.failed
            : TriggersLoad.ready;
      }
    }
    _changed();
  }

  // --- Reading what was read -------------------------------------------------

  Rule? ruleById(String id) {
    for (final rule in rules) {
      if (rule.id == id) return rule;
    }
    return null;
  }

  TriggerEvent? eventById(String id) {
    for (final event in events) {
      if (event.id == id) return event;
    }
    return null;
  }

  /// The firings of one event, newest first.
  List<TriggerFiring> firingsOfEvent(String eventId) => [
    for (final f in firings)
      if (f.eventId == eventId) f,
  ]..sort((a, b) => b.at.compareTo(a.at));

  /// The firing that made [outcomeId] (a review card, a proposal or an
  /// offer).
  TriggerFiring? firingOfOutcome(String outcomeId) {
    for (final f in firings) {
      if (f.outcomes.contains(outcomeId)) return f;
    }
    return null;
  }

  /// The rule a firing belongs to.
  String? firingRuleId(String firingId) {
    for (final f in firings) {
      if (f.id == firingId) return f.ruleId;
    }
    return null;
  }

  /// How a rule did in the last seven days.
  RuleActivity activity(String ruleId, {DateTime? now}) {
    final since = (now ?? clock.now()).subtract(const Duration(days: 7));
    var proposed = 0;
    var ignored = 0;
    final mine = <String>{};
    for (final f in firings) {
      if (f.ruleId != ruleId || f.at.isBefore(since)) continue;
      mine.add(f.id);
      if (f.state == FiringState.proposed) {
        proposed++;
      } else {
        ignored++;
      }
    }
    final offerCount = offers.where((o) => mine.contains(o.firingId)).length;
    return RuleActivity(
      proposed: proposed,
      ignored: ignored,
      offers: offerCount,
    );
  }

  /// Rules grouped by where their events come from, in a fixed order.
  Map<TriggerSourceKind, List<Rule>> get rulesBySource => {
    for (final kind in TriggerSourceKind.values)
      if (rules.any((r) => r.definition.source.kind == kind))
        kind: [
          for (final r in rules)
            if (r.definition.source.kind == kind) r,
        ],
  };

  // --- Writes -----------------------------------------------------------------

  /// Creates a rule, or replaces [replacing] at the revision seen. Returns
  /// the rule as the node now holds it.
  Future<Rule> saveRule(RuleDefinition definition, {Rule? replacing}) =>
      _write(() => _node.saveRule(definition, replacing: replacing));

  Future<Rule> setPaused(Rule rule, {required bool paused}) => _write(
    () => _node.saveRule(
      rule.definition.copyWith(enabled: !paused),
      replacing: rule,
    ),
  );

  Future<void> deleteRule(Rule rule) async {
    await _write(() => _node.deleteRule(rule));
  }

  /// What a rule that is not saved yet would do with [sample]. Nothing is
  /// written; no proof is needed.
  Future<RuleTestResult> testDraft(
    RuleDefinition draft,
    TriggerSample sample,
  ) => _node.testDraft(draft, sample);

  /// What the saved [rule] would do with [sample]. Nothing is written, so
  /// nothing is refreshed.
  Future<RuleTestResult> testRule(Rule rule, TriggerSample sample) =>
      _node.testRule(rule, sample);

  Future<MutationResult> decideProposal(
    ReminderProposal proposal,
    ProposalDecision decision,
  ) async {
    try {
      final result = await _node.decideReminderProposal(proposal, decision);
      unawaited(refresh(quiet: true));
      return result;
    } on FactsBookException catch (failure) {
      if (failure.stale) unawaited(refresh(quiet: true));
      rethrow;
    }
  }

  /// The key an offer is accepted with. The same offer always gets the same
  /// key, so asking twice (a retry, a second phone) returns one receipt and
  /// starts nothing twice. Letters only: keys are never content-classified,
  /// but a digit run still looks like a card number to a person.
  static String receiptKeyFor(ConversationOffer offer) {
    final hash = sha256.convert('${offer.id}/${offer.digest}'.codeUnits);
    final letters = StringBuffer('offer-');
    for (final byte in hash.bytes.take(24)) {
      letters.writeCharCode(0x61 + (byte % 26));
    }
    return letters.toString();
  }

  /// Reports what became of an accepted offer's chat (the first message was
  /// sent, the person left, or the send is unknown). Best effort: the node
  /// also lets a pending receipt run out.
  Future<void> reportOffer(
    ConversationOffer offer,
    StartReceipt receipt,
    OfferReport report,
  ) async {
    try {
      await _node.reportOffer(offer, receipt, report);
    } on FactsBookException {
      // Reported again by nobody: the pending receipt expires on the node.
    }
    unawaited(refresh(quiet: true));
  }

  /// Replaces a reminder proposal's preview; it stays proposed under a new
  /// revision and digest, and confirming it is a separate decision.
  Future<void> editProposal(
    ReminderProposal proposal,
    ReminderPreview preview,
  ) async {
    try {
      await _node.editReminderProposal(proposal, preview);
      await refresh(quiet: true);
    } on FactsBookException catch (failure) {
      if (failure.stale) unawaited(refresh(quiet: true));
      rethrow;
    }
  }

  Future<StartReceipt> acceptOffer(ConversationOffer offer) async {
    try {
      final receipt = await _node.acceptOffer(
        offer,
        receiptKey: receiptKeyFor(offer),
      );
      unawaited(refresh(quiet: true));
      return receipt;
    } on FactsBookException catch (failure) {
      if (failure.stale) unawaited(refresh(quiet: true));
      rethrow;
    }
  }

  Future<void> cancelOffer(ConversationOffer offer) async {
    await _write(() => _node.cancelOffer(offer));
  }

  Future<T> _write<T>(Future<T> Function() write) async {
    try {
      final result = await write();
      await refresh(quiet: true);
      return result;
    } on FactsBookException catch (failure) {
      // A changed rule or offer shows its new state.
      if (failure.stale) await refresh(quiet: true);
      rethrow;
    }
  }
}

/// What a chat opened from an offer starts with: a plain lead-in and the
/// offer's minimized summary, nothing else. The raw message is never part of
/// an offer, so it cannot reach the chat from here.
String offerChatSeed(ConversationOffer offer, {required String leadIn}) =>
    '${leadIn.trim()}\n\n${offer.summary.trim()}';
