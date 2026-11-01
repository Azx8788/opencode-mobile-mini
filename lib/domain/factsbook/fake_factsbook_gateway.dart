import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart' show sha256;

import 'factsbook_gateway.dart';
import 'factsbook_types.dart';
import 'fake_factsbook_triggers.dart';
import 'jcs.dart';

/// An in-memory FactsBook node for tests and previews: synthetic data only
/// ("Sam", "[Bank A] Visa ••42", "[AMOUNT] CUR"), never real personal data.
/// It answers in the shapes of `openapi-v1.yaml` and behaves like the node:
/// a search matches words, a retried capture never saves twice, a reminder
/// can only be confirmed with the digest of the preview it was shown, and a
/// review item that changed fails as stale.
class FakeFactsBookGateway with FakeTriggerNode implements FactsBookGateway {
  FakeFactsBookGateway({
    List<Thing>? things,
    List<ReviewItem>? review,
    List<CouldNotSaveEntry>? pending,
    List<Reminder>? remindersList,
    List<Area>? areaList,
    this.reachable = true,
  }) : _things = [...(things ?? _sampleThings())],
       _review = [...(review ?? _sampleReview())],
       _pending = [...(pending ?? const [])],
       _reminders = [...(remindersList ?? const [])],
       _areas = [...(areaList ?? _sampleAreas())];

  /// The ready-made node: Sam, a card, a bill, a passport, a dentist event,
  /// three proposals to review, one note the node holds (locked folder) and
  /// four areas.
  factory FakeFactsBookGateway.sample() => FakeFactsBookGateway(
    pending: [
      CouldNotSaveEntry(
        id: _id('cqs', 1),
        itemId: _id('itm', 90),
        reason: CouldNotSaveReason.keyLocked,
        createdAt: clock.now().subtract(const Duration(days: 2, hours: 3)),
      ),
    ],
    remindersList: [
      Reminder(
        id: _id('rem', 1),
        what: 'Dentist',
        schedule: ReminderSchedule(
          id: _id('sch', 1),
          when: ScheduleWhen({
            'once': _localIso(
              DateTime(
                clock.now().year,
                clock.now().month,
                clock.now().day + 10,
                10,
              ),
            ),
          }),
          zone: 'vault',
          raw: const {},
        ),
        locale: 'en',
        revision: 1,
      ),
    ],
  );

  /// The ready-made node plus the trigger data: two rules, three events, a
  /// reminder proposal and a conversation offer.
  factory FakeFactsBookGateway.withTriggers() =>
      FakeFactsBookGateway.sample()..seedTriggers();

  /// When false, every call fails the way a lost connection does.
  @override
  bool reachable;

  /// When true, `status()` fails (for the failed-read and last-copy states).
  bool readsFail = false;

  /// When true, only the outbox batch call fails like a lost connection (the
  /// node answers reads), so notes can stay on the phone while pages load.
  bool failOutbox = false;

  /// Words the node adds to every preview (a clock change, a month end), for
  /// the adjustment state of the reminder check.
  List<String> previewAdjustments = const [];

  final List<Thing> _things;
  final List<ReviewItem> _review;
  final List<CouldNotSaveEntry> _pending;
  final List<Reminder> _reminders;
  final List<Area> _areas;
  final Map<String, CaptureResult> _seenKeys = {};
  final Set<String> _staleReviews = {};
  var _serial = 100;

  /// Calls received, for tests: `capture`, `retry`, `discard`, `decide:...`.
  final calls = <String>[];

  /// The idempotency keys captures arrived with, in order.
  final keys = <String>[];

  /// Marks a review item as changed since it was listed: deciding it fails
  /// as stale.
  void makeStale(String reviewId) => _staleReviews.add(reviewId);

  static String _id(String prefix, int n) {
    const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    var rest = n;
    final out = StringBuffer();
    for (var i = 0; i < 26; i++) {
      out.write(alphabet[rest % 32]);
      rest ~/= 32;
    }
    return '${prefix}_${out.toString().split('').reversed.join()}';
  }

  String _next(String prefix) => _id(prefix, _serial++);

  static String _localIso(DateTime at) =>
      '${at.year.toString().padLeft(4, '0')}-'
      '${at.month.toString().padLeft(2, '0')}-'
      '${at.day.toString().padLeft(2, '0')}T'
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}';

  void _needNode() {
    if (!reachable) throw const FactsBookException('node_unreachable');
  }

  // --- Reads ---------------------------------------------------------------

  @override
  Future<NodeStatus> status() async {
    _needNode();
    if (readsFail) throw const FactsBookException('node_unreachable');
    final now = clock.now();
    return NodeStatus(
      executor: _id('dev', 1),
      key: 'locked',
      indexSensitive: 'locked',
      safeInCloud: false,
      careOverdueReason: 'not_enabled',
      generatedAt: now,
      stateRevision: 1,
      modules: {
        'replication': ModuleStatus(
          state: ModuleState.disabled,
          code: 'not_enabled',
          since: now.subtract(const Duration(hours: 3)),
        ),
        'storage': ModuleStatus(
          state: ModuleState.ok,
          since: now.subtract(const Duration(hours: 3)),
          lastOk: now.subtract(const Duration(minutes: 2)),
        ),
        'cloud': ModuleStatus(
          state: ModuleState.absent,
          code: 'not_configured',
          since: now.subtract(const Duration(hours: 3)),
        ),
        'care': ModuleStatus(
          state: ModuleState.disabled,
          code: 'not_enabled',
          since: now.subtract(const Duration(hours: 3)),
        ),
      },
    );
  }

  @override
  Future<List<Thing>> things({ThingKind? kind}) async {
    _needNode();
    return [
      for (final thing in _things)
        if (kind == null || thing.kind == kind) thing,
    ];
  }

  @override
  Future<Thing> thing(String id) async {
    _needNode();
    for (final thing in _things) {
      if (thing.id == id) return thing;
    }
    throw const FactsBookException('not_found');
  }

  /// The area the last capture asked for, for tests.
  String? lastCaptureArea;

  /// Facts added or edited through the gateway, for tests: `thing id: text`.
  final factWrites = <String>[];

  @override
  Future<MutationResult> addFact(Thing thing, String text) async {
    calls.add('fact.add');
    _needNode();
    final index = _things.indexWhere((t) => t.id == thing.id);
    if (index < 0) throw const FactsBookException('not_found');
    if (_things[index].revision != thing.revision) {
      throw const FactsBookException('precondition_failed', status: 412);
    }
    factWrites.add('${thing.id}: $text');
    return _proposeFact(_things[index], ReviewClass.factAdd, text, 'fact.add');
  }

  @override
  Future<MutationResult> editFact(Fact fact, String text) async {
    calls.add('fact.edit');
    _needNode();
    final index = _things.indexWhere((t) => t.id == fact.thingId);
    if (index < 0) throw const FactsBookException('not_found');
    factWrites.add('${fact.id}: $text');
    return _proposeFact(
      _things[index],
      ReviewClass.factUpdate,
      text,
      'fact.update',
    );
  }

  /// A fact change waits in Needs you for the person's OK, as the node does
  /// for an area that asks first.
  MutationResult _proposeFact(
    Thing thing,
    ReviewClass reviewClass,
    String text,
    String kind,
  ) {
    final id = _next('rvw');
    _review.add(
      ReviewItem(
        id: id,
        reviewClass: reviewClass,
        state: ReviewState.proposed,
        digest: _digestOf({'id': id, 'text': text}),
        preconditions: {thing.id: thing.revision},
        proposal: {'kind': kind, 'text': text},
        area: thing.area,
      ),
    );
    return MutationResult(status: 'proposed', id: id, reviewId: id);
  }

  @override
  Future<SearchResult> search(String query) async {
    _needNode();
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return SearchResult(query: query, hits: const []);
    final hits = <SearchHit>[];
    for (final thing in _things) {
      for (final fact in thing.facts) {
        final hay = '${thing.title} ${fact.text}'.toLowerCase();
        if (words.every(hay.contains)) {
          hits.add(
            SearchHit(
              thingId: thing.id,
              factId: fact.id,
              title: thing.title,
              snippet: fact.text,
              source: fact.source,
              provenance: fact.provenance,
              observedAt: fact.observedAt,
              area: fact.area,
            ),
          );
        }
      }
    }
    hits.sort((a, b) => b.observedAt.compareTo(a.observedAt));
    return SearchResult(query: query, hits: hits, lockedNotesSkipped: true);
  }

  @override
  Future<List<CouldNotSaveEntry>> pendingCaptures() async {
    _needNode();
    return [
      for (final entry in _pending)
        if (entry.state != CouldNotSaveState.discarded) entry,
    ];
  }

  @override
  Future<List<ReviewItem>> reviewItems() async {
    _needNode();
    return [
      for (final item in _review)
        if (item.state == ReviewState.proposed) item,
    ];
  }

  @override
  Future<List<Reminder>> reminders() async {
    _needNode();
    return [..._reminders];
  }

  @override
  Future<List<Area>> areas() async {
    _needNode();
    return [..._areas];
  }

  // --- Writes ---------------------------------------------------------------

  @override
  Future<CaptureResult> capture(
    CaptureRequest request, {
    required String idempotencyKey,
  }) async {
    lastCaptureArea = request.area;
    calls.add('capture');
    keys.add(idempotencyKey);
    _needNode();
    final seen = _seenKeys[idempotencyKey];
    // The same key is the same capture: no second copy (F114).
    if (seen != null) return seen;
    final itemId = _next('itm');
    CaptureResult result;
    if (request.area == 'health') {
      // The locked folder cannot be written until unlocked: the node holds it.
      final entry = CouldNotSaveEntry(
        id: _next('cqs'),
        itemId: itemId,
        reason: CouldNotSaveReason.keyLocked,
        createdAt: clock.now(),
      );
      _pending.add(entry);
      result = CaptureResult(
        saved: false,
        itemId: itemId,
        couldntSaveId: entry.id,
      );
    } else {
      _record(request);
      result = CaptureResult(saved: true, itemId: itemId);
    }
    _seenKeys[idempotencyKey] = result;
    return result;
  }

  void _record(CaptureRequest request) {
    final now = clock.now();
    final title = request.text.split(RegExp(r'[.\n]')).first.trim();
    final thingId = _next('top');
    final fact = Fact(
      id: _next('f'),
      thingId: thingId,
      text: request.text.trim(),
      provenance: request.kind == CaptureKind.note
          ? FactProvenance.told
          : FactProvenance.seen,
      source: request.kind == CaptureKind.note ? '' : 'text you shared',
      observedAt: now,
      area: request.area ?? 'family',
    );
    _things.insert(
      0,
      Thing(
        id: thingId,
        title: title,
        kind: ThingKind.topic,
        area: request.area ?? 'family',
        updatedAt: now,
        facts: [fact],
      ),
    );
  }

  @override
  Future<CaptureResult> retryCapture(
    String id, {
    required String idempotencyKey,
  }) async {
    calls.add('retry');
    _needNode();
    final index = _pending.indexWhere((e) => e.id == id);
    if (index < 0) throw const FactsBookException('not_found');
    final entry = _pending[index];
    if (entry.reason == CouldNotSaveReason.keyLocked) {
      // Still locked: the node keeps it and says so.
      _pending[index] = entry.copyWith(
        retries: entry.retries + 1,
        state: CouldNotSaveState.kept,
      );
      return CaptureResult(
        saved: false,
        itemId: entry.itemId ?? '',
        couldntSaveId: entry.id,
      );
    }
    _pending.removeAt(index);
    return CaptureResult(saved: true, itemId: entry.itemId ?? '');
  }

  @override
  Future<void> discardCapture(
    String id, {
    required String idempotencyKey,
  }) async {
    calls.add('discard');
    _needNode();
    _pending.removeWhere((e) => e.id == id);
  }

  @override
  Future<List<OutboxReceipt>> sendOutbox(List<OutboxEvent> events) async {
    calls.add('outbox');
    _needNode();
    if (failOutbox) throw const FactsBookException('node_unreachable');
    final receipts = <OutboxReceipt>[];
    for (final event in events) {
      final duplicate = _seenKeys.containsKey(event.key);
      final request = CaptureRequest.fromJson(event.payload);
      if (request.text.length > 200000) {
        receipts.add(
          OutboxReceipt(
            key: event.key,
            status: OutboxReceiptStatus.refused,
            error: const FactsBookException('bad_request'),
          ),
        );
        continue;
      }
      await capture(request, idempotencyKey: event.key);
      receipts.add(
        OutboxReceipt(
          key: event.key,
          status: duplicate
              ? OutboxReceiptStatus.duplicate
              : OutboxReceiptStatus.accepted,
        ),
      );
    }
    return receipts;
  }

  @override
  Future<MutationResult> decideReview(
    ReviewItem item,
    ReviewDecision decision, {
    Map<String, Object?>? edited,
  }) async {
    calls.add('decide:${decision.name}');
    _needNode();
    final index = _review.indexWhere((r) => r.id == item.id);
    if (index < 0) throw const FactsBookException('not_found');
    if (_staleReviews.contains(item.id) ||
        _review[index].digest != item.digest) {
      final old = _review[index];
      _review[index] = ReviewItem(
        id: old.id,
        reviewClass: old.reviewClass,
        state: ReviewState.stale,
        digest: old.digest,
        preconditions: old.preconditions,
        proposal: old.proposal,
        area: old.area,
      );
      throw const FactsBookException('stale_approval', status: 412);
    }
    if (decision == ReviewDecision.skip) {
      return MutationResult(status: 'skipped', id: item.id);
    }
    final old = _review[index];
    _review[index] = ReviewItem(
      id: old.id,
      reviewClass: old.reviewClass,
      state: decision == ReviewDecision.reject
          ? ReviewState.rejected
          : ReviewState.approved,
      digest: old.digest,
      preconditions: old.preconditions,
      proposal: old.proposal,
      area: old.area,
    );
    return MutationResult(status: 'ok', id: item.id);
  }

  static String _digestOf(Map<String, Object?> preview) =>
      sha256.convert(Jcs.bytes(preview)).toString();

  @override
  Future<ReminderPreview> previewReminder({
    required String what,
    required ReminderTiming timing,
    required String zone,
    required String locale,
    String? scheduleId,
    String area = 'general',
  }) async {
    _needNode();
    final when = timing.toWhen();
    final once = when['once'] as String?;
    final ambiguities = <String>[
      if (what.trim().isEmpty) 'Enter a reminder title.',
    ];
    final value = <String, Object?>{
      'what': what.trim(),
      'date': once?.substring(0, 10),
      'time': once?.substring(11) ?? when['at'],
      'zone': zone,
      'locale': locale,
      'repeat': when['every'],
      'ambiguities': ambiguities,
      'schedule': {
        'v': 1,
        'id': scheduleId ?? _next('sch'),
        'when': when,
        'zone': zone,
        'window': null,
        'catchup': 'coalesce',
      },
      'adjustments': previewAdjustments,
      'settings_rev': 1,
      'effective_zone': 'UTC',
      'area': area,
      'sens': 'normal',
    };
    value['preview_digest'] = _digestOf(value);
    return ReminderPreview.fromJson(value);
  }

  void _verify(ReminderPreview preview) {
    final unsigned = {...preview.raw}..remove('preview_digest');
    if (_digestOf(unsigned) != preview.digest || !preview.confirmable) {
      throw const FactsBookException('conflict', status: 409);
    }
  }

  @override
  Future<MutationResult> createReminder(
    ReminderPreview preview, {
    bool urgent = false,
    bool floatingConfirmed = false,
  }) async {
    calls.add('reminder.create');
    _needNode();
    _verify(preview);
    final id = _next('rem');
    _reminders.add(
      Reminder(
        id: id,
        what: preview.what,
        schedule: preview.schedule!,
        locale: preview.locale,
        urgent: urgent,
        revision: 1,
      ),
    );
    return MutationResult(status: 'ok', id: id, revision: 1);
  }

  @override
  Future<MutationResult> setReminderPaused(
    Reminder reminder, {
    required bool paused,
  }) async {
    calls.add(paused ? 'reminder.pause' : 'reminder.resume');
    _needNode();
    final index = _reminders.indexWhere((r) => r.id == reminder.id);
    if (index < 0) throw const FactsBookException('not_found');
    if (_reminders[index].revision != reminder.revision) {
      throw const FactsBookException('conflict', status: 409);
    }
    final old = _reminders[index];
    _reminders[index] = Reminder(
      id: old.id,
      what: old.what,
      schedule: old.schedule,
      locale: old.locale,
      urgent: old.urgent,
      paused: paused,
      revision: old.revision + 1,
    );
    return MutationResult(status: 'ok', id: old.id, revision: old.revision + 1);
  }

  @override
  Future<MutationResult> updateReminder(
    Reminder reminder,
    ReminderPreview preview, {
    bool floatingConfirmed = false,
  }) async {
    calls.add('reminder.update');
    _needNode();
    _verify(preview);
    final index = _reminders.indexWhere((r) => r.id == reminder.id);
    if (index < 0) throw const FactsBookException('not_found');
    final old = _reminders[index];
    if (old.revision != reminder.revision) {
      throw const FactsBookException('conflict', status: 409);
    }
    _reminders[index] = Reminder(
      id: old.id,
      what: preview.what,
      schedule: preview.schedule!,
      locale: preview.locale,
      urgent: old.urgent,
      paused: old.paused,
      revision: old.revision + 1,
    );
    return MutationResult(status: 'ok', id: old.id, revision: old.revision + 1);
  }

  @override
  Future<MutationResult> setAreaShare(Area area, AreaShare share) async {
    calls.add('area:${area.slug}');
    _needNode();
    final index = _areas.indexWhere((a) => a.slug == area.slug);
    if (index < 0) throw const FactsBookException('not_found');
    _areas[index] = _areas[index].copyWith(share: share);
    return MutationResult(status: 'ok', id: _id('dev', 1));
  }

  /// The control chain `control()` answers with; null means the node does
  /// not offer it.
  ControlChain? controlChain;

  FactsBookSettings _settings = FactsBookSettings.fromJson({
    'rev': 1,
    'vault_zone': 'UTC',
    'lock_timeout_minutes': 15,
    'brief': {'cap_per_day': 5, 'time': '08:00', 'quiet_hours': '22:00-07:00'},
    'budget': {'monthly_money': 0, 'currency': 'CUR', 'monthly_tokens': 0},
  });

  @override
  Future<FactsBookSettings> settings() async {
    _needNode();
    return _settings;
  }

  @override
  Future<MutationResult> setBriefCap(FactsBookSettings current, int cap) async {
    calls.add('settings:cap:$cap');
    _needNode();
    if (current.revision != _settings.revision) {
      throw const FactsBookException('precondition_failed', status: 412);
    }
    _settings = FactsBookSettings.fromJson({
      ...current.withBriefCap(cap),
      'rev': current.revision + 1,
    });
    return MutationResult(
      status: 'ok',
      id: _id('dev', 1),
      revision: _settings.revision,
    );
  }

  @override
  Future<MutationResult> setHomeZone(
    FactsBookSettings current,
    String zone,
  ) async {
    calls.add('settings:zone:$zone');
    _needNode();
    if (current.revision != _settings.revision) {
      throw const FactsBookException('precondition_failed', status: 412);
    }
    _settings = FactsBookSettings.fromJson({
      ...current.withHomeZone(zone),
      'rev': current.revision + 1,
    });
    return MutationResult(
      status: 'ok',
      id: _id('dev', 1),
      revision: _settings.revision,
    );
  }

  @override
  Future<CaptureExport> exportCapture(String id) async {
    calls.add('export');
    _needNode();
    final entry = _pending.where((e) => e.id == id).firstOrNull;
    if (entry == null) throw const FactsBookException('not_found');
    return CaptureExport(
      item: entry.itemId ?? '',
      text:
          '{\n  "v": 1,\n  "cqs": "${entry.id}",\n  "format": '
          '"factsbook-encrypted-capture"\n}',
    );
  }

  @override
  Future<ControlChain> control() async {
    _needNode();
    final chain = controlChain;
    if (chain == null) {
      throw const FactsBookException('not_enabled', status: 501);
    }
    return chain;
  }

  // --- Synthetic data -------------------------------------------------------

  static DateTime _ago(Duration d) => clock.now().subtract(d);

  static Fact _fact(
    int n,
    String thing,
    String text,
    FactProvenance provenance,
    Duration ago, {
    String source = '',
    String area = 'family',
    FactReview review = FactReview.approved,
  }) => Fact(
    id: _id('f', n),
    thingId: thing,
    text: text,
    provenance: provenance,
    source: source,
    observedAt: _ago(ago),
    area: area,
    review: review,
    revision: 1,
  );

  static List<Thing> _sampleThings() {
    final sam = _id('per', 1);
    final card = _id('crd', 1);
    final bill = _id('bil', 1);
    final passport = _id('doc', 1);
    final dentist = _id('evt', 1);
    return [
      Thing(
        id: dentist,
        title: 'Dentist',
        kind: ThingKind.event,
        area: 'health',
        updatedAt: _ago(const Duration(hours: 3)),
        facts: [
          _fact(
            1,
            dentist,
            'Dentist appointment Wed 21 Oct 10:00. Bring the insurance card.',
            FactProvenance.told,
            const Duration(hours: 3),
            area: 'health',
          ),
          _fact(
            2,
            dentist,
            'Planning the dentist visit: book it before the trip.',
            FactProvenance.seen,
            const Duration(days: 8),
            source: 'a chat you saved',
            area: 'health',
          ),
        ],
      ),
      Thing(
        id: sam,
        title: 'Sam',
        kind: ThingKind.person,
        area: 'family',
        updatedAt: _ago(const Duration(days: 2)),
        facts: [
          _fact(
            3,
            sam,
            'Birthday is 14 March.',
            FactProvenance.told,
            const Duration(days: 131),
          ),
          _fact(
            4,
            sam,
            'Probably pays the electricity bill by card ••42.',
            FactProvenance.guessed,
            const Duration(days: 2),
            source: 'a chat you saved',
            review: FactReview.proposed,
          ),
        ],
      ),
      Thing(
        id: card,
        title: '[Bank A] Visa ••42',
        kind: ThingKind.card,
        area: 'money',
        updatedAt: _ago(const Duration(days: 2)),
        facts: [
          _fact(
            5,
            card,
            'Statement is due on the 15th of each month.',
            FactProvenance.seen,
            const Duration(days: 8),
            source: 'text you shared',
            area: 'money',
          ),
          _fact(
            6,
            card,
            'Annual fee is [AMOUNT] CUR.',
            FactProvenance.told,
            const Duration(days: 29),
            area: 'money',
          ),
          _fact(
            7,
            card,
            'Used for groceries.',
            FactProvenance.guessed,
            const Duration(days: 2),
            source: 'a chat you saved',
            area: 'money',
            review: FactReview.proposed,
          ),
        ],
      ),
      Thing(
        id: bill,
        title: 'Electricity bill',
        kind: ThingKind.bill,
        area: 'money',
        updatedAt: _ago(const Duration(days: 2)),
        facts: [
          _fact(
            8,
            bill,
            'Paid by card ••42 on the 18th.',
            FactProvenance.guessed,
            const Duration(days: 2),
            source: 'a chat you saved',
            area: 'money',
          ),
        ],
      ),
      Thing(
        id: passport,
        title: 'Passport',
        kind: ThingKind.document,
        area: 'family',
        updatedAt: _ago(const Duration(days: 29)),
        facts: [
          _fact(
            9,
            passport,
            'Expires 14 Feb 2027.',
            FactProvenance.told,
            const Duration(days: 29),
          ),
        ],
      ),
    ];
  }

  static List<ReviewItem> _sampleReview() => [
    for (var i = 0; i < 3; i++)
      ReviewItem(
        id: _id('rvw', i + 1),
        reviewClass: ReviewClass.factAdd,
        state: ReviewState.proposed,
        digest: _id('x', i)
            .replaceAll(RegExp('[^0-9a-f]'), 'a')
            .padRight(64, 'b')
            .substring(0, 64),
        preconditions: {_id('per', 1): 1},
        targets: [_id('per', 1)],
        area: i == 1 ? 'money' : 'family',
        risk: i == 1 ? const ['money'] : const [],
        proposal: {
          'kind': 'fact.add',
          'thing_id': _id('per', 1),
          'fact_id': null,
          'text': [
            'Sam likes books',
            'Sam pays the bill by card ••42',
            'Sam walks in the morning',
          ][i],
          'category': 'preference',
        },
      ),
  ];

  static List<Area> _sampleAreas() => [
    for (final (slug, sensitive, first, read) in [
      ('family', false, false, true),
      ('money', true, true, false),
      ('health', true, true, false),
      ('work', false, false, true),
    ])
      Area(
        slug: slug,
        sensitiveStorage: sensitive,
        reviewFirst: first,
        share: AreaShare(readByDefault: read),
        brief: !sensitive,
        export: !sensitive,
        notify: sensitive ? 'generic' : 'masked',
      ),
  ];
}
