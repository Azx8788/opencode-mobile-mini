import 'dart:async';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/factsbook/control_verifier.dart';
import '../../domain/factsbook/factsbook_capabilities.dart';
import '../../domain/factsbook/factsbook_gateway.dart';
import '../../domain/factsbook/factsbook_trigger_types.dart';
import '../../domain/factsbook/factsbook_types.dart';
import '../connection.dart' show connProvider;
import 'factsbook_outbox.dart';
import 'factsbook_session.dart';
import 'factsbook_triggers.dart';
import 'factsbook_store.dart';

/// The FactsBook pairing of the connected server profile. Without a
/// bootstrapped connection (previews, tests that built none) there is no
/// store, and the session is an unpaired one that never loads anything.
final factsBookSessionProvider = Provider<FactsBookSession>((ref) {
  FactsBookSession session;
  try {
    final conn = ref.watch(connProvider);
    final profileId = conn.profile?.id;
    session = profileId == null
        ? FactsBookSession.unpaired()
        : FactsBookSession(
            store: FactsBookStore(prefs: conn.store.prefs),
            profileId: profileId,
          );
  } on Exception {
    session = FactsBookSession.unpaired();
  } on UnimplementedError {
    session = FactsBookSession.unpaired();
  }
  ref.onDispose(session.dispose);
  unawaited(session.load());
  return session;
});

/// What the Memory section and the FactsBook pages show, and every write
/// they make.
final factsBookControllerProvider = Provider<FactsBookController>((ref) {
  final controller = FactsBookController(ref.watch(factsBookSessionProvider));
  ref.onDispose(controller.dispose);
  return controller;
});

enum FactsBookLoad { idle, loading, ready, failed }

/// What a capture came to. Never a loss: it is saved at the node, held by
/// the node in its own queue, held on this phone, or refused with the text
/// still on screen.
sealed class CaptureOutcome {
  const CaptureOutcome();
}

class CaptureSavedAtNode extends CaptureOutcome {
  const CaptureSavedAtNode(this.itemId);
  final String itemId;
}

class CaptureQueuedAtNode extends CaptureOutcome {
  const CaptureQueuedAtNode(this.itemId, this.entryId);
  final String itemId;
  final String? entryId;
}

class CaptureKeptOnPhone extends CaptureOutcome {
  const CaptureKeptOnPhone(this.entry);
  final CouldNotSaveEntry entry;
}

/// The phone's queue is full: nothing was kept; the text is still in the
/// editor.
class CaptureRefusedFull extends CaptureOutcome {
  const CaptureRefusedFull();
}

class FactsBookController extends ChangeNotifier {
  FactsBookController(this.session) : triggers = FactsBookTriggers(session) {
    session.addListener(_sessionChanged);
    triggers.addListener(_changed);
  }

  final FactsBookSession session;

  /// Event triggers: rules, outcomes to review and conversation offers.
  final FactsBookTriggers triggers;

  FactsBookLoad load = FactsBookLoad.idle;
  NodeStatus? status;
  List<ReviewItem> review = const [];

  /// The three things with the newest facts, for "Recently added".
  List<Thing> recent = const [];

  /// The node's queue and this phone's outbox, together.
  List<CouldNotSaveEntry> pending = const [];

  /// The last read failure; the screen words it.
  FactsBookException? error;

  var _generation = 0;
  var _disposed = false;

  bool get paired => session.paired;

  FactsBookGateway get _gateway => session.gateway ?? const _UnpairedGateway();

  /// The review cards a rule's reminder proposal stands in for are counted
  /// once: the node may list a proposal in both places.
  List<ReviewItem> get reviewCards {
    final proposed = {for (final p in triggers.proposals) p.id};
    return [
      for (final item in review)
        if (!proposed.contains(item.id)) item,
    ];
  }

  /// Everything waiting in Memory care: review cards and reminder proposals.
  int get reviewWaiting => reviewCards.length + triggers.proposals.length;

  /// What needs the person, derived from the review queue and Not saved yet.
  List<NeedsYouItem> get needsYou {
    final notSaved = pending
        .where((e) => e.state != CouldNotSaveState.discarded)
        .toList();
    DateTime? oldest;
    for (final entry in notSaved) {
      if (oldest == null || entry.createdAt.isBefore(oldest)) {
        oldest = entry.createdAt;
      }
    }
    return [
      if (reviewWaiting > 0)
        NeedsYouItem(kind: NeedsYouKind.review, count: reviewWaiting),
      if (notSaved.isNotEmpty)
        NeedsYouItem(
          kind: NeedsYouKind.notSaved,
          count: notSaved.length,
          since: oldest,
        ),
      if (triggers.openOffers().isNotEmpty)
        NeedsYouItem(
          kind: NeedsYouKind.offer,
          count: triggers.openOffers().length,
        ),
    ];
  }

  /// Counted once, here and in the Inbox.
  int get needsYouCount => needsYou.fold(0, (n, item) => n + item.count);

  /// The notes whose 30-day question is due.
  List<CouldNotSaveEntry> get dueForPrompt => [
    for (final entry in pending)
      if (entry.needsThirtyDayPrompt(clock.now())) entry,
  ];

  void _sessionChanged() {
    // A new pairing means a new node: start from nothing.
    status = null;
    review = const [];
    recent = const [];
    pending = const [];
    error = null;
    load = FactsBookLoad.idle;
    triggers.reset();
    _changed();
    if (session.paired) unawaited(refresh());
  }

  @override
  void dispose() {
    _disposed = true;
    session.removeListener(_sessionChanged);
    triggers.removeListener(_changed);
    triggers.dispose();
    super.dispose();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// An idempotency key made of letters only: the node runs its content
  /// classifier over an outbox event's key and refuses one with a long run of
  /// digits (a timestamp looks like a card number).
  String _key() {
    const letters = 'abcdefghijklmnopqrstuvwxyz';
    final random = Random.secure();
    return 'cap-${List.generate(24, (_) => letters[random.nextInt(26)]).join()}';
  }

  /// Reads everything the overview shows, after sending what the outbox
  /// holds. A failed read keeps the last copy (nothing claims to be live)
  /// and records [error].
  Future<void> refresh() async {
    final generation = ++_generation;
    if (load == FactsBookLoad.idle || load == FactsBookLoad.failed) {
      load = FactsBookLoad.loading;
      _changed();
    }
    try {
      try {
        await session.outbox.flush(_gateway);
      } on FactsBookException catch (failure) {
        if (!failure.unreachable) rethrow;
      }
      final results = await Future.wait<Object?>([
        _gateway.status(),
        _gateway.reviewItems(),
        _gateway.pendingCaptures(),
        _gateway.things(),
      ]);
      if (generation != _generation) return;
      status = results[0]! as NodeStatus;
      review = results[1]! as List<ReviewItem>;
      pending = [
        ...results[2]! as List<CouldNotSaveEntry>,
        for (final e in session.outbox.entries) e.asEntry(),
      ];
      recent = _newest(results[3]! as List<Thing>);
      error = null;
      load = FactsBookLoad.ready;
      // Offers wait for the person too; the node may not have them (older
      // node), which the triggers state reads as "not available yet".
      if (triggers.supported) unawaited(triggers.refresh(quiet: true));
    } on FactsBookException catch (failure) {
      if (generation != _generation) return;
      error = failure;
      pending = _phoneOnly(pending);
      load = status == null ? FactsBookLoad.failed : FactsBookLoad.ready;
    }
    _changed();
  }

  static List<Thing> _newest(List<Thing> things) {
    final withFacts =
        [
          for (final t in things)
            if (t.newestFact != null) t,
        ]..sort(
          (a, b) =>
              b.newestFact!.observedAt.compareTo(a.newestFact!.observedAt),
        );
    return withFacts.take(3).toList();
  }

  List<CouldNotSaveEntry> _phoneOnly(List<CouldNotSaveEntry> known) => [
    for (final e in known)
      if (!e.onPhone) e,
    for (final e in session.outbox.entries) e.asEntry(),
  ];

  /// Saves a capture. A node that cannot be reached is not an error here:
  /// the text goes to the outbox (D25), unless the outbox is full, in which
  /// case the newest is refused and the caller keeps the text on screen.
  ///
  /// With [rulesLook] and a node that lists the trigger capability, a note,
  /// shared text or chat selection goes to `/v1/events` instead of
  /// `/v1/inbox` (the node stores its evidence there and evaluates rules; the
  /// contract says not to post it to both). A share or selected chat is
  /// signed by the owner key as ordinary text, which needs this phone's
  /// approval key and the device prompt. If that cannot be done, or the node
  /// does not take it, the capture is saved to the inbox as before: nothing
  /// is lost and nothing is said twice.
  Future<CaptureOutcome> capture(
    CaptureRequest request, {
    bool rulesLook = false,
  }) async {
    final key = _key();
    if (rulesLook) {
      final saved = await _saveAsEvent(request, key);
      if (saved != null) {
        await refresh();
        return saved;
      }
    }
    CaptureOutcome outcome;
    try {
      final result = await _gateway.capture(request, idempotencyKey: key);
      outcome = result.saved
          ? CaptureSavedAtNode(result.itemId)
          : CaptureQueuedAtNode(result.itemId, result.couldntSaveId);
    } on FactsBookException catch (failure) {
      if (!failure.unreachable && failure.code != 'outbox_full') rethrow;
      try {
        final entry = await session.outbox.add(request, key);
        outcome = CaptureKeptOnPhone(entry.asEntry());
      } on OutboxFullException {
        outcome = const CaptureRefusedFull();
      }
    }
    await refresh();
    return outcome;
  }

  /// Posts [request] as an event the node's rules read. Null when it was not
  /// posted (no capability, no approval key, the person cancelled the device
  /// prompt, or the node refused or was not reached): the caller then saves
  /// it to the inbox. The answer holds no text and none is kept.
  Future<CaptureOutcome?> _saveAsEvent(
    CaptureRequest request,
    String captureKey,
  ) async {
    final kind = TriggerSourceKind.ofCapture(request.kind);
    if (kind == null || !triggers.supported) return null;
    final classify = kind != TriggerSourceKind.note;
    if (classify && !session.canApprove) return null;
    final suffix = captureKey.replaceFirst('cap-', '');
    try {
      final event = await _gateway.postEvent(
        TriggerSample(
          kind: kind,
          text: request.text,
          area: request.area ?? 'general',
          locale: guessEventLocale(request.text),
          sourceInstance: kind.defaultInstance,
          // Letters only, like every key this app makes.
          messageKey: 'msg-$suffix',
        ),
        idempotencyKey: 'evt-$suffix',
        classifyNormal: classify,
      );
      return CaptureSavedAtNode(event.evidenceRef);
    } on FactsBookException {
      return null;
    }
  }

  /// Tries a kept item again. Returns true when it was saved.
  Future<bool> retry(CouldNotSaveEntry entry) async {
    var saved = false;
    try {
      if (entry.onPhone) {
        saved = await session.outbox.flush(_gateway, only: entry.id) > 0;
      } else {
        saved = (await _gateway.retryCapture(
          entry.id,
          idempotencyKey: _key(),
        )).saved;
      }
    } finally {
      await refresh();
    }
    return saved;
  }

  Future<void> discard(CouldNotSaveEntry entry) async {
    if (entry.onPhone) {
      await session.outbox.remove(entry.id);
    } else {
      await _gateway.discardCapture(entry.id, idempotencyKey: _key());
    }
    await refresh();
  }

  /// Approve, edit, reject or skip a proposal. A changed one fails as stale
  /// ([FactsBookException.stale]) and the list is refetched so the fresh
  /// item shows.
  Future<void> decide(
    ReviewItem item,
    ReviewDecision decision, {
    Map<String, Object?>? edited,
  }) async {
    try {
      await _gateway.decideReview(item, decision, edited: edited);
    } on FactsBookException catch (failure) {
      if (failure.stale) await refresh();
      rethrow;
    }
    await refresh();
  }

  // Reads the pages make for themselves: the controller only passes them on,
  // so screens never hold the gateway.
  Future<NodeStatus> readStatus() => _gateway.status();

  Future<Thing> thing(String id) => _gateway.thing(id);

  /// A fact the person adds to [thing], or their new wording of one. Both
  /// wait for the person's OK in Needs you when the area asks first; the
  /// lists are read again so they show.
  Future<MutationResult> addFact(Thing thing, String text) async {
    final result = await _gateway.addFact(thing, text);
    await refresh();
    return result;
  }

  Future<MutationResult> editFact(Fact fact, String text) async {
    final result = await _gateway.editFact(fact, text);
    await refresh();
    return result;
  }

  Future<SearchResult> search(String query) => _gateway.search(query);

  Future<List<Thing>> things({ThingKind? kind}) => _gateway.things(kind: kind);

  Future<List<Reminder>> reminders() => _gateway.reminders();

  Future<ReminderPreview> previewReminder({
    required String what,
    required ReminderTiming timing,
    required String zone,
    required String locale,
    String? scheduleId,
    String area = 'general',
  }) => _gateway.previewReminder(
    what: what,
    timing: timing,
    zone: zone,
    locale: locale,
    scheduleId: scheduleId,
    area: area,
  );

  Future<MutationResult> createReminder(
    ReminderPreview preview, {
    bool floatingConfirmed = false,
  }) => _gateway.createReminder(preview, floatingConfirmed: floatingConfirmed);

  Future<MutationResult> updateReminder(
    Reminder reminder,
    ReminderPreview preview, {
    bool floatingConfirmed = false,
  }) => _gateway.updateReminder(
    reminder,
    preview,
    floatingConfirmed: floatingConfirmed,
  );

  Future<MutationResult> setReminderPaused(
    Reminder reminder, {
    required bool paused,
  }) => _gateway.setReminderPaused(reminder, paused: paused);

  Future<List<Area>> areas() => _gateway.areas();

  Future<MutationResult> setAreaShare(Area area, AreaShare share) =>
      _gateway.setAreaShare(area, share);

  Future<FactsBookSettings> settings() => _gateway.settings();

  Future<MutationResult> setBriefCap(FactsBookSettings current, int cap) =>
      _gateway.setBriefCap(current, cap);

  Future<MutationResult> setHomeZone(FactsBookSettings current, String zone) =>
      _gateway.setHomeZone(current, zone);

  Future<CaptureExport> exportCapture(String id) => _gateway.exportCapture(id);

  /// Checks the node's signed control chain against the fingerprint pinned
  /// when this phone was paired. Null when there is no pin to check against.
  Future<ControlVerification?> verifyControl() async {
    final pin = session.link?.rootFingerprint;
    if (pin == null) return null;
    return ControlVerifier.verify(
      await _gateway.control(),
      pinnedFingerprint: pin,
    );
  }
}

/// The gateway before pairing: every call says the phone is not signed in.
class _UnpairedGateway implements FactsBookGateway {
  const _UnpairedGateway();

  Never _no() => throw const FactsBookException('unauthorized');

  @override
  Future<NodeStatus> status() async => _no();
  @override
  Future<List<Thing>> things({ThingKind? kind}) async => _no();
  @override
  Future<Thing> thing(String id) async => _no();
  @override
  Future<MutationResult> addFact(Thing thing, String text) async => _no();
  @override
  Future<MutationResult> editFact(Fact fact, String text) async => _no();
  @override
  Future<SearchResult> search(String query) async => _no();
  @override
  Future<CaptureResult> capture(
    CaptureRequest request, {
    required String idempotencyKey,
  }) async => _no();
  @override
  Future<List<CouldNotSaveEntry>> pendingCaptures() async => _no();
  @override
  Future<CaptureResult> retryCapture(
    String id, {
    required String idempotencyKey,
  }) async => _no();
  @override
  Future<void> discardCapture(
    String id, {
    required String idempotencyKey,
  }) async => _no();
  @override
  Future<List<OutboxReceipt>> sendOutbox(List<OutboxEvent> events) async =>
      _no();
  @override
  Future<List<ReviewItem>> reviewItems() async => _no();
  @override
  Future<MutationResult> decideReview(
    ReviewItem item,
    ReviewDecision decision, {
    Map<String, Object?>? edited,
  }) async => _no();
  @override
  Future<ReminderPreview> previewReminder({
    required String what,
    required ReminderTiming timing,
    required String zone,
    required String locale,
    String? scheduleId,
    String area = 'general',
  }) async => _no();
  @override
  Future<MutationResult> createReminder(
    ReminderPreview preview, {
    bool urgent = false,
    bool floatingConfirmed = false,
  }) async => _no();
  @override
  Future<List<Reminder>> reminders() async => _no();
  @override
  Future<MutationResult> setReminderPaused(
    Reminder reminder, {
    required bool paused,
  }) async => _no();
  @override
  Future<MutationResult> updateReminder(
    Reminder reminder,
    ReminderPreview preview, {
    bool floatingConfirmed = false,
  }) async => _no();
  @override
  Future<FactsBookSettings> settings() async => _no();
  @override
  Future<MutationResult> setBriefCap(
    FactsBookSettings current,
    int cap,
  ) async => _no();
  @override
  Future<MutationResult> setHomeZone(
    FactsBookSettings current,
    String zone,
  ) async => _no();
  @override
  Future<CaptureExport> exportCapture(String id) async => _no();
  @override
  Future<ControlChain> control() async => _no();
  @override
  Future<List<Area>> areas() async => _no();
  @override
  Future<MutationResult> setAreaShare(Area area, AreaShare share) async =>
      _no();
  @override
  Future<TriggerEvent> postEvent(
    TriggerSample sample, {
    required String idempotencyKey,
    bool classifyNormal = false,
  }) async => _no();
  @override
  Future<RuleTestResult> testDraft(
    RuleDefinition draft,
    TriggerSample sample,
  ) async => _no();
  @override
  Future<FactsBookCapabilities> capabilities() async => _no();
  @override
  Future<MutationResult> editReminderProposal(
    ReminderProposal proposal,
    ReminderPreview preview,
  ) async => _no();
  @override
  Future<StartReceipt> reportOffer(
    ConversationOffer offer,
    StartReceipt receipt,
    OfferReport report,
  ) async => _no();
  @override
  Future<List<Rule>> rules() async => _no();
  @override
  Future<Rule> saveRule(RuleDefinition definition, {Rule? replacing}) async =>
      _no();
  @override
  Future<Rule> deleteRule(Rule rule) async => _no();
  @override
  Future<RuleTestResult> testRule(Rule rule, TriggerSample sample) async =>
      _no();
  @override
  Future<List<TriggerEvent>> events() async => _no();
  @override
  Future<TriggerEvent> event(String id) async => _no();
  @override
  Future<List<TriggerFiring>> firings() async => _no();
  @override
  Future<List<ReminderProposal>> reminderProposals() async => _no();
  @override
  Future<MutationResult> decideReminderProposal(
    ReminderProposal proposal,
    ProposalDecision decision,
  ) async => _no();
  @override
  Future<List<ConversationOffer>> offers() async => _no();
  @override
  Future<StartReceipt> acceptOffer(
    ConversationOffer offer, {
    required String receiptKey,
  }) async => _no();
  @override
  Future<ConversationOffer> cancelOffer(ConversationOffer offer) async => _no();
}
