import 'factsbook_capabilities.dart';
import 'factsbook_trigger_types.dart';
import 'factsbook_types.dart';

/// The protocol-neutral door to a FactsBook node (App API v1,
/// `factsbook/api/openapi-v1.yaml`). The UI talks to this and nothing else;
/// [FakeFactsBookGateway] answers in tests and [HttpFactsBookGateway] calls
/// `/v1`.
///
/// Every method throws [FactsBookException] on a failure the person can act
/// on (the node's `code`, or `node_unreachable` when no answer came).
/// Mutations carry an idempotency key so a retry never saves twice.
abstract interface class FactsBookGateway {
  /// `GET /v1/status`.
  Future<NodeStatus> status();

  /// `GET /v1/things?kind=` (every page).
  Future<List<Thing>> things({ThingKind? kind});

  /// `GET /v1/things/{id}`.
  Future<Thing> thing(String id);

  /// `POST /v1/things/{id}/facts`: a fact the person adds to [thing]. The
  /// node answers `ok` or, where the area asks the person first, `proposed`
  /// with a review id that waits in Needs you. [text] is one line. A thing
  /// that changed fails with [FactsBookException.stale]. There is no
  /// delete: the v1 contract has no `DELETE /v1/facts/{id}`.
  Future<MutationResult> addFact(Thing thing, String text);

  /// `PATCH /v1/facts/{id}`: the person's new wording of [fact], proposed for
  /// review the same way.
  Future<MutationResult> editFact(Fact fact, String text);

  /// `GET /v1/search?q=` (text match, v1).
  Future<SearchResult> search(String query);

  /// `POST /v1/inbox`. `queued` means the node holds it in its own Not saved
  /// yet queue.
  Future<CaptureResult> capture(
    CaptureRequest request, {
    required String idempotencyKey,
  });

  /// `GET /v1/inbox/pending`: the node's Not saved yet queue.
  Future<List<CouldNotSaveEntry>> pendingCaptures();

  /// `POST /v1/inbox/{id}/retry`.
  Future<CaptureResult> retryCapture(
    String id, {
    required String idempotencyKey,
  });

  /// `DELETE /v1/inbox/{id}`. The caller has already asked the person.
  Future<void> discardCapture(String id, {required String idempotencyKey});

  /// `POST /v1/outbox`: captures made while the node was unreachable, each
  /// with its own key. One receipt per event, in order.
  Future<List<OutboxReceipt>> sendOutbox(List<OutboxEvent> events);

  /// `GET /v1/review` (every page).
  Future<List<ReviewItem>> reviewItems();

  /// `POST /v1/review/{id}/decision`, signed by the owner key. A changed
  /// item fails with [FactsBookException.stale] and is never applied.
  Future<MutationResult> decideReview(
    ReviewItem item,
    ReviewDecision decision, {
    Map<String, Object?>? edited,
  });

  /// `POST /v1/reminders/parse`: the node's reading of a reminder in its
  /// structured schedule form, with the title apart. [scheduleId] keeps a
  /// schedule's identity stable on an edit. Nothing is saved.
  Future<ReminderPreview> previewReminder({
    required String what,
    required ReminderTiming timing,
    required String zone,
    required String locale,
    String? scheduleId,
    String area = 'general',
  });

  /// `POST /v1/reminders`: confirms exactly [preview].
  Future<MutationResult> createReminder(
    ReminderPreview preview, {
    bool urgent = false,
    bool floatingConfirmed = false,
  });

  /// `GET /v1/reminders` (every page).
  Future<List<Reminder>> reminders();

  /// `PATCH /v1/reminders/{id}` with `paused`.
  Future<MutationResult> setReminderPaused(
    Reminder reminder, {
    required bool paused,
  });

  /// `PATCH /v1/reminders/{id}` with a confirmed preview (edit).
  Future<MutationResult> updateReminder(
    Reminder reminder,
    ReminderPreview preview, {
    bool floatingConfirmed = false,
  });

  /// `GET /v1/areas`.
  Future<List<Area>> areas();

  /// `PATCH /v1/areas/{slug}`: who else may read the area, signed by the
  /// owner key against the current policy revision.
  Future<MutationResult> setAreaShare(Area area, AreaShare share);

  /// `GET /v1/config` (admin).
  Future<FactsBookSettings> settings();

  /// `PATCH /v1/config` with a new daily brief cap, signed by the owner key
  /// against the revision the person saw.
  Future<MutationResult> setBriefCap(FactsBookSettings current, int cap);

  /// `PATCH /v1/config` with a new home time zone (an IANA name), signed by
  /// the owner key against the revision the person saw.
  Future<MutationResult> setHomeZone(FactsBookSettings current, String zone);

  /// `GET /v1/inbox/{id}/export`: an unsaved capture as an encrypted object.
  Future<CaptureExport> exportCapture(String id);

  /// `GET /v1/control?since=0` (admin): the signed control chain.
  Future<ControlChain> control();

  // --- Event triggers (spec 44, node capability `local_trigger_slice`) -----
  // The UI asks these only where the capability matrix lists them; a node
  // without them answers `not_found` or `not_enabled`.

  /// `GET /v1/rules` (every page), without the deleted ones.
  Future<List<Rule>> rules();

  /// `POST /v1/rules` (a new rule) or `PUT /v1/rules/{id}` (a replacement,
  /// which is also how pause and resume work), signed by the owner key
  /// against the revision the person saw. A changed rule fails with
  /// [FactsBookException.stale].
  Future<Rule> saveRule(RuleDefinition definition, {Rule? replacing});

  /// `DELETE /v1/rules/{id}`, signed. The caller has already asked.
  Future<Rule> deleteRule(Rule rule);

  /// `POST /v1/rules/{id}/test`: what the saved rule would do with [sample].
  /// Nothing is written.
  Future<RuleTestResult> testRule(Rule rule, TriggerSample sample);

  /// `POST /v1/rules/test`: what a rule that is not saved yet would do with
  /// [sample]. Nothing is written, no proof is needed.
  Future<RuleTestResult> testDraft(RuleDefinition draft, TriggerSample sample);

  /// `GET /v1/capabilities` (read): the node's own matrix. A node without it
  /// answers `not_found`.
  Future<FactsBookCapabilities> capabilities();

  /// `GET /v1/events` (every page): metadata only, never the raw text.
  Future<List<TriggerEvent>> events();

  /// `GET /v1/events/{id}`.
  Future<TriggerEvent> event(String id);

  /// `GET /v1/trigger-firings` (every page).
  Future<List<TriggerFiring>> firings();

  /// `GET /v1/reminder-proposals` (every page).
  Future<List<ReminderProposal>> reminderProposals();

  /// `POST /v1/reminder-proposals/{id}/decision`, signed, bound to the exact
  /// revision and digest the person saw.
  Future<MutationResult> decideReminderProposal(
    ReminderProposal proposal,
    ProposalDecision decision,
  );

  /// The same endpoint with `decision: edit`, signed: replaces the proposal's
  /// preview with [preview] (parsed by the node). The proposal stays
  /// proposed under a new revision and digest; confirming is a separate
  /// decision.
  Future<MutationResult> editReminderProposal(
    ReminderProposal proposal,
    ReminderPreview preview,
  );

  /// `GET /v1/offers` (every page).
  Future<List<ConversationOffer>> offers();

  /// `POST /v1/offers/{id}/accept` with `adapter: client_report`: the person
  /// said yes to exactly this revision and digest. The answer is a `pending`
  /// receipt (at most 15 minutes): opening a chat is not a start. [receiptKey]
  /// is stable per offer, so a retry or a second phone sees the same receipt.
  Future<StartReceipt> acceptOffer(
    ConversationOffer offer, {
    required String receiptKey,
  });

  /// `POST /v1/offers/{id}/receipt`: what became of the chat. `started` is
  /// reported only with the first message sent.
  Future<StartReceipt> reportOffer(
    ConversationOffer offer,
    StartReceipt receipt,
    OfferReport report,
  );

  /// `POST /v1/offers/{id}/cancel`.
  Future<ConversationOffer> cancelOffer(ConversationOffer offer);

  /// `POST /v1/events`: tells the node a note, shared text or chat selection
  /// arrived, so enabled rules can look at it. The node answers metadata
  /// only (never the text back). [idempotencyKey] makes a retry the same
  /// event. Callers treat a failure as "the rules did not look", never as a
  /// failed capture.
  ///
  /// With [classifyNormal] the owner key signs, for this exact request, that
  /// the text is ordinary: a share or selected chat is kept encrypted and
  /// ignored by rules without it.
  Future<TriggerEvent> postEvent(
    TriggerSample sample, {
    required String idempotencyKey,
    bool classifyNormal = false,
  });
}
