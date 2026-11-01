import 'package:flutter/foundation.dart';

/// Value types of the FactsBook App API v1, matching the node's published
/// contract (`factsbook/api/openapi-v1.yaml`, schema names in comments).
/// Protocol-neutral: the UI reads these and never a JSON map. Every
/// `fromJson` ignores unknown keys (`/v1` only adds fields) and never throws
/// on an unknown enum word: it falls to the most cautious reading.
/// `test/factsbook/factsbook_contract_test.dart` parses the node's own
/// fixtures with these, so a contract change breaks a test.

/// Which of two things in a list is read as a map of strings.
Map<String, Object?> _map(Object? value) =>
    (value as Map).cast<String, Object?>();

List<T> _list<T>(Object? value, T Function(Map<String, Object?>) read) => [
  for (final item in (value as List? ?? const [])) read(_map(item)),
];

DateTime _time(Object? value) => DateTime.parse(value! as String);

DateTime? _timeOrNull(Object? value) =>
    value == null ? null : DateTime.parse(value as String);

/// How a fact came to be known (`Fact.provenance`).
enum FactProvenance {
  /// The person said it ("You told it").
  told,

  /// Read from a source ("From <source>").
  seen,

  /// Inferred ("It guessed").
  guessed,

  /// Computed from other facts.
  calculated,

  /// A hand edit whose author is not verified (02-contracts 3.4). Shown like
  /// a guess: it never reads as told.
  external;

  /// An unknown word reads as [guessed]: a claim never gains trust by being
  /// unrecognised.
  static FactProvenance parse(Object? raw) {
    for (final value in values) {
      if (value.name == raw) return value;
    }
    return guessed;
  }
}

/// `Fact.review`.
enum FactReview {
  proposed,
  approved,
  autoSafe('auto_safe'),
  rejected;

  const FactReview([this._wire]);
  final String? _wire;
  String get wire => _wire ?? name;

  static FactReview parse(Object? raw) {
    for (final value in values) {
      if (value.wire == raw) return value;
    }
    // Unknown: not approved, so it still reads as waiting.
    return proposed;
  }
}

/// `Fact.status`.
enum FactStatus {
  active,
  disputed,
  archived;

  static FactStatus parse(Object? raw) {
    for (final value in values) {
      if (value.name == raw) return value;
    }
    return active;
  }
}

/// `Evidence`: where a claim was read, and when.
@immutable
class Evidence {
  const Evidence({required this.source, required this.observedAt});

  final String source;
  final DateTime observedAt;

  factory Evidence.fromJson(Map<String, Object?> json) => Evidence(
    source: json['source'] as String,
    observedAt: _time(json['observed_at']),
  );
}

/// One fact (`Fact`): always with provenance, source and date (D25).
@immutable
class Fact {
  const Fact({
    required this.id,
    required this.thingId,
    required this.text,
    required this.provenance,
    required this.observedAt,
    required this.source,
    this.category = '',
    this.area = '',
    this.sensitive = false,
    this.revision = 0,
    this.review = FactReview.approved,
    this.status = FactStatus.active,
    this.support = const [],
  });

  /// `f_<ULID>`.
  final String id;
  final String thingId;
  final String text;
  final String category;

  /// An item id (`itm_...`) or the node's words; [sourceWords] in the UI
  /// turns it into plain language.
  final String source;
  final DateTime observedAt;
  final FactProvenance provenance;
  final String area;
  final bool sensitive;
  final int revision;
  final FactReview review;
  final FactStatus status;
  final List<Evidence> support;

  /// A guess or proposal that has not been approved.
  bool get waitingForOk => review == FactReview.proposed;

  factory Fact.fromJson(Map<String, Object?> json) => Fact(
    id: json['id']! as String,
    thingId: json['thing_id']! as String,
    text: json['text']! as String,
    category: (json['category'] as String?) ?? '',
    source: (json['source'] as String?) ?? '',
    observedAt: _time(json['observed_at']),
    provenance: FactProvenance.parse(json['provenance']),
    area: (json['area'] as String?) ?? '',
    sensitive: json['sens'] == 'sensitive',
    revision: (json['rev'] as num?)?.toInt() ?? 0,
    review: FactReview.parse(json['review']),
    status: FactStatus.parse(json['status']),
    support: _list(json['support'], Evidence.fromJson),
  );
}

/// `Thing.kind`.
enum ThingKind {
  person,
  organisation,
  account,
  card,
  bill,
  invoice,
  place,
  project,
  topic,
  event,
  document,
  subscription,
  warranty,
  health,

  /// A kind a newer node added.
  other;

  static ThingKind parse(Object? raw) {
    for (final value in values) {
      if (value.name == raw) return value;
    }
    return other;
  }
}

/// A thing and its facts (`Thing`).
@immutable
class Thing {
  const Thing({
    required this.id,
    required this.title,
    required this.kind,
    required this.updatedAt,
    this.area = '',
    this.sensitive = false,
    this.revision = 0,
    this.facts = const [],
  });

  /// `per_`, `crd_`, `doc_` ... `<ULID>`.
  final String id;
  final String title;
  final ThingKind kind;
  final String area;
  final bool sensitive;
  final int revision;
  final List<Fact> facts;
  final DateTime updatedAt;

  /// The newest fact: what a list row's source and date line speaks of.
  Fact? get newestFact {
    Fact? newest;
    for (final fact in facts) {
      if (newest == null || fact.observedAt.isAfter(newest.observedAt)) {
        newest = fact;
      }
    }
    return newest;
  }

  factory Thing.fromJson(Map<String, Object?> json) => Thing(
    id: json['id']! as String,
    title: (json['title'] as String?) ?? '',
    kind: ThingKind.parse(json['kind']),
    area: (json['area'] as String?) ?? '',
    sensitive: json['sens'] == 'sensitive',
    revision: (json['rev'] as num?)?.toInt() ?? 0,
    facts: _list(json['facts'], Fact.fromJson),
    updatedAt: _time(json['updated_at']),
  );
}

/// One search result (`SearchHit`): source and date on every hit (G31).
@immutable
class SearchHit {
  const SearchHit({
    required this.thingId,
    required this.factId,
    required this.title,
    required this.snippet,
    required this.source,
    required this.provenance,
    required this.observedAt,
    this.area = '',
  });

  final String thingId;
  final String factId;
  final String title;
  final String snippet;
  final String source;
  final FactProvenance provenance;
  final DateTime observedAt;
  final String area;

  factory SearchHit.fromJson(Map<String, Object?> json) => SearchHit(
    thingId: json['thing_id']! as String,
    factId: json['fact_id']! as String,
    title: (json['title'] as String?) ?? '',
    snippet: (json['snippet'] as String?) ?? '',
    source: (json['source'] as String?) ?? '',
    provenance: FactProvenance.parse(json['provenance']),
    observedAt: _time(json['observed_at']),
    area: (json['area'] as String?) ?? '',
  );
}

@immutable
class SearchResult {
  const SearchResult({
    required this.query,
    required this.hits,
    this.lockedNotesSkipped = false,
  });

  final String query;
  final List<SearchHit> hits;

  /// Locked notes are not searched until unlocked (G21, screen 11 banner).
  final bool lockedNotesSkipped;
}

/// `Capture.kind`.
enum CaptureKind {
  note,
  chatSelection('chat_selection'),
  share,
  importText('import');

  const CaptureKind([String? wire]) : _wire = wire;
  final String? _wire;
  String get wire => _wire ?? name;

  static CaptureKind parse(Object? raw) {
    for (final kind in values) {
      if (kind.wire == raw) return kind;
    }
    return note;
  }
}

/// A capture the person sends (`Capture`, `POST /v1/inbox`).
@immutable
class CaptureRequest {
  const CaptureRequest({required this.kind, required this.text, this.area});

  final CaptureKind kind;
  final String text;
  final String? area;

  /// The trust the app claims: a typed note is user-authored, a shared or
  /// pasted text is user-selected. The node sets the origin role itself
  /// from the paired client.
  String get trust => switch (kind) {
    CaptureKind.note => 'user_authored',
    CaptureKind.importText => 'imported',
    _ => 'user_selected',
  };

  Map<String, Object?> toJson() => {
    'kind': kind.wire,
    'text': text,
    'area': ?area,
    'trust': trust,
  };

  factory CaptureRequest.fromJson(Map<String, Object?> json) => CaptureRequest(
    kind: CaptureKind.parse(json['kind']),
    text: json['text']! as String,
    area: json['area'] as String?,
  );
}

/// `CaptureResult`: the node saved it, or kept it in its own Not saved yet
/// queue (`queued`). Never a loss.
@immutable
class CaptureResult {
  const CaptureResult({
    required this.saved,
    required this.itemId,
    this.couldntSaveId,
  });

  final bool saved;
  final String itemId;
  final String? couldntSaveId;

  factory CaptureResult.fromJson(Map<String, Object?> json) => CaptureResult(
    saved: json['status'] == 'saved',
    itemId: json['item_id']! as String,
    couldntSaveId: json['couldnt_save_id'] as String?,
  );
}

/// `Schedule.when`: one of the node's schedule forms. Kept as the raw
/// object so a form this app does not know round-trips untouched.
@immutable
class ScheduleWhen {
  const ScheduleWhen(this.raw);

  final Map<String, Object?> raw;

  /// `{"once": "2026-10-15T09:00"}`: a local date-time.
  DateTime? get once {
    final value = raw['once'];
    return value is String ? DateTime.tryParse(value) : null;
  }

  /// `day`, `week`, `month`, `year`, an interval like `6h`, or null.
  String? get every => raw['every'] as String?;

  String? get at => raw['at'] as String?;
}

/// `Schedule`.
@immutable
class ReminderSchedule {
  const ReminderSchedule({
    required this.id,
    required this.when,
    required this.zone,
    required this.raw,
  });

  final String id;
  final ScheduleWhen when;

  /// `vault`, `floating` or an IANA name.
  final String zone;
  final Map<String, Object?> raw;

  factory ReminderSchedule.fromJson(Map<String, Object?> json) =>
      ReminderSchedule(
        id: json['id']! as String,
        when: ScheduleWhen(_map(json['when'])),
        zone: (json['zone'] as String?) ?? 'vault',
        raw: json,
      );
}

/// The node's own reading of a reminder before anything is saved (`Preview`,
/// `POST /v1/reminders/parse`). D27: date, time, zone and locale are shown
/// before saving. The digest binds exactly this object, so it is sent back
/// unchanged to confirm.
@immutable
class ReminderPreview {
  const ReminderPreview({
    required this.what,
    required this.zone,
    required this.locale,
    required this.ambiguities,
    required this.adjustments,
    required this.digest,
    required this.raw,
    this.settingsRevision = 0,
    this.effectiveZone = '',
    this.area = 'general',
    this.sensitive = false,
    this.date,
    this.time,
    this.repeat,
    this.schedule,
  });

  final String what;
  final String? date;
  final String? time;
  final String zone;

  /// `en` or `ar`.
  final String locale;
  final String? repeat;

  /// The node's words for what it could not settle. It cannot be confirmed
  /// while any remain.
  final List<String> ambiguities;
  final ReminderSchedule? schedule;
  final List<String> adjustments;
  final String digest;

  /// The object as received (with `preview_digest`), sent back to confirm.
  final Map<String, Object?> raw;

  /// The settings revision the node read the zone from; a confirmation must
  /// keep it (the digest binds it).
  final int settingsRevision;

  /// The IANA zone `vault` or `floating` resolved to.
  final String effectiveZone;

  /// The area the reminder belongs to, and whether it is sensitive.
  final String area;
  final bool sensitive;

  bool get confirmable => schedule != null && ambiguities.isEmpty;

  /// The reminder's local date-time, when it is a one-time reminder.
  DateTime? get at => schedule?.when.once;

  factory ReminderPreview.fromJson(Map<String, Object?> json) =>
      ReminderPreview(
        what: (json['what'] as String?) ?? '',
        date: json['date'] as String?,
        time: json['time'] as String?,
        zone: (json['zone'] as String?) ?? 'vault',
        locale: (json['locale'] as String?) ?? 'en',
        repeat: json['repeat'] as String?,
        ambiguities: [for (final a in json['ambiguities'] as List? ?? []) '$a'],
        schedule: json['schedule'] == null
            ? null
            : ReminderSchedule.fromJson(_map(json['schedule'])),
        adjustments: [for (final a in json['adjustments'] as List? ?? []) '$a'],
        digest: json['preview_digest']! as String,
        raw: json,
        settingsRevision: (json['settings_rev'] as num?)?.toInt() ?? 0,
        effectiveZone: (json['effective_zone'] as String?) ?? '',
        area: (json['area'] as String?) ?? 'general',
        sensitive: json['sens'] == 'sensitive',
      );
}

/// A saved reminder (`Reminder`), kept independently of chats (G26).
@immutable
class Reminder {
  const Reminder({
    required this.id,
    required this.what,
    required this.schedule,
    required this.locale,
    this.urgent = false,
    this.paused = false,
    this.revision = 0,
    this.source,
    this.area = 'general',
    this.sensitive = false,
    this.done = false,
    this.snoozedUntil,
  });

  final String id;
  final String what;
  final ReminderSchedule schedule;
  final String locale;
  final String area;
  final bool sensitive;
  final bool urgent;
  final bool paused;
  final int revision;
  final String? source;
  final bool done;
  final DateTime? snoozedUntil;

  factory Reminder.fromJson(Map<String, Object?> json) => Reminder(
    id: json['id']! as String,
    what: (json['what'] as String?) ?? '',
    schedule: ReminderSchedule.fromJson(_map(json['schedule'])),
    locale: (json['locale'] as String?) ?? 'en',
    urgent: json['urgent'] == true,
    paused: json['paused'] == true,
    revision: (json['rev'] as num?)?.toInt() ?? 0,
    source: json['source'] as String?,
    area: (json['area'] as String?) ?? 'general',
    sensitive: json['sens'] == 'sensitive',
    done: json['done'] == true,
    snoozedUntil: _timeOrNull(json['snoozed_until']),
  );
}

/// How often a reminder repeats, as far as this app builds it (the contract
/// also has intervals, events and cron: those show and pause, never edit).
enum ReminderRepeat { never, daily, weekly, monthly, yearly }

/// When a reminder fires, in the node's schedule forms (`Schedule.when`):
/// one time, or every day, week, month or year. [at] carries the clock time
/// (and, for a one-time reminder, the date; for a yearly one, the month and
/// day).
@immutable
class ReminderTiming {
  const ReminderTiming({
    required this.repeat,
    required this.at,
    this.weekdays = const {},
    this.dayOfMonth = 1,
    this.lastDay = false,
  });

  final ReminderRepeat repeat;

  /// The date and clock time: all of it for [ReminderRepeat.never], the clock
  /// time (and month and day for yearly) for the others.
  final DateTime at;

  /// 1 (Monday) to 7 (Sunday), for weekly.
  final Set<int> weekdays;

  /// 1 to 31 for monthly; [lastDay] means the last day of each month.
  final int dayOfMonth;
  final bool lastDay;

  static const _names = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

  static String _two(int n) => n.toString().padLeft(2, '0');

  String get _clock => '${_two(at.hour)}:${_two(at.minute)}';

  /// The `when` object the node reads.
  Map<String, Object?> toWhen() => switch (repeat) {
    ReminderRepeat.never => {
      'once':
          '${at.year.toString().padLeft(4, '0')}-${_two(at.month)}-'
          '${_two(at.day)}T$_clock',
    },
    ReminderRepeat.daily => {'every': 'day', 'at': _clock},
    ReminderRepeat.weekly => {
      'every': 'week',
      'on': [for (final d in (weekdays.toList()..sort())) _names[d - 1]],
      'at': _clock,
    },
    ReminderRepeat.monthly => {
      'every': 'month',
      'day': lastDay ? 'last' : dayOfMonth,
      'at': _clock,
    },
    ReminderRepeat.yearly => {
      'every': 'year',
      'month': at.month,
      'day': at.day,
      'at': _clock,
    },
  };

  /// Reads a `when` back, or null for a form this app does not build.
  static ReminderTiming? fromWhen(ScheduleWhen when) {
    final once = when.once;
    if (once != null) {
      return ReminderTiming(repeat: ReminderRepeat.never, at: once);
    }
    final raw = when.raw;
    final time = (raw['at'] as String?)?.split(':');
    final hour = time == null ? null : int.tryParse(time.first);
    final minute = time == null || time.length < 2
        ? null
        : int.tryParse(time[1]);
    if (hour == null || minute == null) return null;
    DateTime clock(int month, int day) =>
        DateTime(2000, month, day, hour, minute);
    switch (raw['every']) {
      case 'day':
        return ReminderTiming(repeat: ReminderRepeat.daily, at: clock(1, 1));
      case 'week':
        final days = {
          for (final d in raw['on'] as List? ?? const [])
            if (_names.contains('$d')) _names.indexOf('$d') + 1,
        };
        if (days.isEmpty) return null;
        return ReminderTiming(
          repeat: ReminderRepeat.weekly,
          at: clock(1, 1),
          weekdays: days,
        );
      case 'month':
        final day = raw['day'];
        return ReminderTiming(
          repeat: ReminderRepeat.monthly,
          at: clock(1, 1),
          lastDay: day == 'last',
          dayOfMonth: day is int ? day : 1,
        );
      case 'year':
        final month = raw['month'];
        final day = raw['day'];
        if (month is! int || day is! int) return null;
        return ReminderTiming(
          repeat: ReminderRepeat.yearly,
          at: clock(month, day),
        );
    }
    return null;
  }

  ReminderTiming copyWith({
    ReminderRepeat? repeat,
    DateTime? at,
    Set<int>? weekdays,
    int? dayOfMonth,
    bool? lastDay,
  }) => ReminderTiming(
    repeat: repeat ?? this.repeat,
    at: at ?? this.at,
    weekdays: weekdays ?? this.weekdays,
    dayOfMonth: dayOfMonth ?? this.dayOfMonth,
    lastDay: lastDay ?? this.lastDay,
  );
}

/// `Review.class` (02-contracts 3.9).
enum ReviewClass {
  factAdd('fact_add'),
  factUpdate('fact_update'),
  factSupersede('fact_supersede'),
  merge('merge'),
  link('link'),
  archive('archive'),
  forget('forget'),
  watch('watch'),
  reminder('reminder'),
  importCandidate('import_candidate'),
  promotion('promotion');

  const ReviewClass(this.wire);
  final String wire;

  static ReviewClass parse(Object? raw) {
    for (final c in values) {
      if (c.wire == raw) return c;
    }
    return factAdd;
  }
}

/// `Review.state`.
enum ReviewState {
  proposed,
  approved,
  rejected,
  stale;

  static ReviewState parse(Object? raw) {
    for (final s in values) {
      if (s.name == raw) return s;
    }
    return stale;
  }
}

/// A proposal waiting for the person (`Review`, `rvw_<ULID>`, D23).
@immutable
class ReviewItem {
  const ReviewItem({
    required this.id,
    required this.reviewClass,
    required this.state,
    required this.digest,
    required this.preconditions,
    required this.proposal,
    this.targets = const [],
    this.evidence = const [],
    this.current,
    this.area = '',
    this.sensitive = false,
    this.risk = const [],
    this.expiresAt,
  });

  final String id;
  final ReviewClass reviewClass;
  final ReviewState state;
  final String digest;

  /// `{entity id: revision}`: bound into the signed decision.
  final Map<String, int> preconditions;

  /// The operation bundle approval would apply (`proposal.text` for a fact).
  final Map<String, Object?> proposal;
  final List<String> targets;
  final List<Evidence> evidence;
  final Map<String, Object?>? current;
  final String area;
  final bool sensitive;

  /// `money`, `health`, `id`, `contradiction`, `low_confidence`.
  final List<String> risk;
  final DateTime? expiresAt;

  /// The proposed text, when the proposal has one.
  String? get text => proposal['text'] as String?;

  factory ReviewItem.fromJson(Map<String, Object?> json) => ReviewItem(
    id: json['rvw']! as String,
    reviewClass: ReviewClass.parse(json['class']),
    state: ReviewState.parse(json['state']),
    digest: json['digest']! as String,
    preconditions: {
      for (final entry in _map(json['preconditions']).entries)
        entry.key: (entry.value as num).toInt(),
    },
    proposal: _map(json['proposal']),
    targets: [for (final t in json['targets'] as List? ?? []) '$t'],
    evidence: _list(json['evidence'], Evidence.fromJson),
    current: json['current'] == null ? null : _map(json['current']),
    area: (json['area'] as String?) ?? '',
    sensitive: json['sens'] == 'sensitive',
    risk: [for (final r in json['risk'] as List? ?? []) '$r'],
    expiresAt: _timeOrNull(json['expires_at']),
  );
}

/// What the person decides on a proposal (`Decision.decision`).
enum ReviewDecision { approve, edit, reject, skip }

/// `MutationResult`.
@immutable
class MutationResult {
  const MutationResult({
    required this.status,
    required this.id,
    this.revision,
    this.reviewId,
  });

  /// `ok`, `proposed`, `pending` or `skipped`.
  final String status;
  final String id;
  final int? revision;
  final String? reviewId;

  factory MutationResult.fromJson(Map<String, Object?> json) => MutationResult(
    status: (json['status'] as String?) ?? 'ok',
    id: json['id']! as String,
    revision: (json['rev'] as num?)?.toInt(),
    reviewId: json['review_id'] as String?,
  );
}

/// `Share`: who else may read an area.
@immutable
class AreaShare {
  const AreaShare({
    this.readByDefault = false,
    this.allow = const [],
    this.deny = const [],
  });

  /// `default: read` (true) or `none`.
  final bool readByDefault;
  final List<String> allow;
  final List<String> deny;

  factory AreaShare.fromJson(Map<String, Object?> json) => AreaShare(
    readByDefault: json['default'] == 'read',
    allow: [for (final a in json['allow'] as List? ?? []) '$a'],
    deny: [for (final a in json['deny'] as List? ?? []) '$a'],
  );

  Map<String, Object?> toJson() => {
    'default': readByDefault ? 'read' : 'none',
    'allow': allow,
    'deny': deny,
  };
}

/// `Area`: a named area with its rules. Built-in areas only; the contract
/// has no call to create one.
@immutable
class Area {
  const Area({
    required this.slug,
    required this.sensitiveStorage,
    required this.reviewFirst,
    required this.share,
    required this.brief,
    required this.export,
    required this.notify,
  });

  final String slug;

  /// `storage: sensitive`: the locked folder.
  final bool sensitiveStorage;

  /// `review: first` (everything waits for the person) versus
  /// `auto_safe_only`.
  final bool reviewFirst;
  final AreaShare share;
  final bool brief;
  final bool export;

  /// `generic`, `masked` or `full`.
  final String notify;

  Area copyWith({AreaShare? share}) => Area(
    slug: slug,
    sensitiveStorage: sensitiveStorage,
    reviewFirst: reviewFirst,
    share: share ?? this.share,
    brief: brief,
    export: export,
    notify: notify,
  );

  factory Area.fromJson(Map<String, Object?> json) => Area(
    slug: json['slug']! as String,
    sensitiveStorage: json['storage'] == 'sensitive',
    reviewFirst: json['review'] == 'first',
    share: AreaShare.fromJson(_map(json['share'])),
    brief: json['brief'] == true,
    export: json['export'] == true,
    notify: (json['notify'] as String?) ?? 'generic',
  );

  Map<String, Object?> toJson() => {
    'slug': slug,
    'storage': sensitiveStorage ? 'sensitive' : 'normal',
    'review': reviewFirst ? 'first' : 'auto_safe_only',
    'share': share.toJson(),
    'brief': brief,
    'export': export,
    'notify': notify,
  };
}

/// `CouldntSave.reason_code` (closed list, 02-contracts 3.10), plus the
/// phone's own refusal when its queue is full.
enum CouldNotSaveReason {
  storageFull('storage_full'),
  classificationFailed('classification_failed'),
  parserError('parser_error'),
  nodeUnreachable('node_unreachable'),
  outboxFull('outbox_full'),
  cloudQuota('cloud_quota'),
  keyLocked('key_locked'),
  validationRejected('validation_rejected');

  const CouldNotSaveReason(this.wire);
  final String wire;

  static CouldNotSaveReason parse(Object? raw) {
    for (final r in values) {
      if (r.wire == raw) return r;
    }
    return nodeUnreachable;
  }
}

/// `CouldntSave.state`.
enum CouldNotSaveState { queued, retrying, saved, kept, discarded }

/// A "Not saved yet" entry: the node's (`CouldntSave`, `cqs_<ULID>`, no text,
/// only the item it holds) or this phone's own outbox (with its [text]).
/// Kept until the person discards it (F105, D32); at 30 days the app asks
/// Retry, Export or Discard.
@immutable
class CouldNotSaveEntry {
  const CouldNotSaveEntry({
    required this.id,
    required this.reason,
    required this.createdAt,
    this.itemId,
    this.text,
    this.retries = 0,
    this.state = CouldNotSaveState.queued,
    this.promptDue = false,
    this.onPhone = false,
  });

  final String id;

  /// The inbox item the node holds; null for a phone entry.
  final String? itemId;

  /// The text, for a phone entry only (the node keeps its own copy). Never
  /// logged.
  final String? text;
  final CouldNotSaveReason reason;
  final DateTime createdAt;
  final int retries;
  final CouldNotSaveState state;

  /// The node's own 30-day flag (`prompt_due`).
  final bool promptDue;

  /// In this phone's outbox, not yet at the node.
  final bool onPhone;

  static const askAfter = Duration(days: 30);

  /// True from day 30: the screen asks Retry, Export or Discard.
  bool needsThirtyDayPrompt(DateTime now) =>
      promptDue || (onPhone && now.difference(createdAt) >= askAfter);

  CouldNotSaveEntry copyWith({
    int? retries,
    CouldNotSaveState? state,
    CouldNotSaveReason? reason,
  }) => CouldNotSaveEntry(
    id: id,
    itemId: itemId,
    text: text,
    reason: reason ?? this.reason,
    createdAt: createdAt,
    retries: retries ?? this.retries,
    state: state ?? this.state,
    promptDue: promptDue,
    onPhone: onPhone,
  );

  factory CouldNotSaveEntry.fromJson(Map<String, Object?> json) =>
      CouldNotSaveEntry(
        id: json['cqs']! as String,
        itemId: json['item'] as String?,
        reason: CouldNotSaveReason.parse(json['reason_code']),
        createdAt: _time(json['created_at']),
        retries: (json['retries'] as num?)?.toInt() ?? 0,
        state: CouldNotSaveState.values.firstWhere(
          (s) => s.name == json['state'],
          orElse: () => CouldNotSaveState.queued,
        ),
        promptDue: json['prompt_due'] == true,
      );
}

/// What a Needs-you row is (derived by the app from the review queue and
/// Not saved yet: the node has no separate needs-you list in v1).
enum NeedsYouKind { review, notSaved, offer }

@immutable
class NeedsYouItem {
  const NeedsYouItem({required this.kind, required this.count, this.since});

  final NeedsYouKind kind;
  final int count;
  final DateTime? since;
}

/// `Status.modules[*].state`, `index.*`: the canonical states. Absent,
/// stale, failed and disabled stay distinct; `ok` never means "working now".
enum ModuleState {
  ok,
  waiting,
  stale,
  failed,
  disabled,
  absent;

  static ModuleState parse(Object? raw) {
    for (final s in values) {
      if (s.name == raw) return s;
    }
    // An unknown state is shown as the least reassuring known one.
    return failed;
  }
}

/// `Module`.
@immutable
class ModuleStatus {
  const ModuleStatus({required this.state, this.code, this.since, this.lastOk});

  final ModuleState state;

  /// The node's reason code ("not_configured"); words come from the app.
  final String? code;
  final DateTime? since;
  final DateTime? lastOk;

  factory ModuleStatus.fromJson(Map<String, Object?> json) => ModuleStatus(
    state: ModuleState.parse(json['state']),
    code: json['code'] as String?,
    since: _timeOrNull(json['since']),
    lastOk: _timeOrNull(json['last_ok']),
  );
}

/// `Status`: the node as the app sees it.
@immutable
class NodeStatus {
  const NodeStatus({
    required this.modules,
    this.executor,
    this.key = 'absent',
    this.indexNormal = ModuleState.ok,
    this.indexSensitive = 'locked',
    this.staleSeconds,
    this.safeInCloud = false,
    this.lastCareAt,
    this.careOverdueReason,
    this.generatedAt,
    this.stateRevision = 0,
  });

  final Map<String, ModuleStatus> modules;

  /// When the node made this report, and its revision.
  final DateTime? generatedAt;
  final int stateRevision;

  /// The working device's id, when one is set.
  final String? executor;

  /// `absent`, `locked` or `unlocked`.
  final String key;

  /// `index.normal`: ok, waiting (rebuilding) or failed.
  final ModuleState indexNormal;

  /// `index.sensitive`: locked, waiting, failed or ok.
  final String indexSensitive;

  /// The age of the cloud copy; null when cloud freshness has never been
  /// established (no cloud configured): never read as fresh.
  final int? staleSeconds;

  /// False with no cloud configured: no claim of a backup.
  final bool safeInCloud;
  final DateTime? lastCareAt;
  final String? careOverdueReason;

  ModuleStatus module(String name) =>
      modules[name] ?? const ModuleStatus(state: ModuleState.absent);

  factory NodeStatus.fromJson(Map<String, Object?> json) {
    final index = json['index'] == null
        ? const <String, Object?>{}
        : _map(json['index']);
    return NodeStatus(
      modules: {
        for (final entry in _map(json['modules']).entries)
          entry.key: ModuleStatus.fromJson(_map(entry.value)),
      },
      executor: json['executor'] as String?,
      key: (json['key'] as String?) ?? 'absent',
      indexNormal: ModuleState.parse(index['normal']),
      indexSensitive: (index['sensitive'] as String?) ?? 'locked',
      staleSeconds: (json['stale_seconds'] as num?)?.toInt(),
      generatedAt: _timeOrNull(json['generated_at']),
      stateRevision: (json['state_revision'] as num?)?.toInt() ?? 0,
      safeInCloud: json['safe_in_cloud'] == true,
      lastCareAt: _timeOrNull(json['last_care_at']),
      careOverdueReason: json['care_overdue_reason'] as String?,
    );
  }
}

/// One event of an outbox batch (`OutboxEvent`): a capture made while the
/// node could not be reached, with its own idempotency key.
@immutable
class OutboxEvent {
  const OutboxEvent({required this.key, required this.payload});

  final String key;

  /// The `Capture` body.
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => {
    'key': key,
    'type': 'capture',
    'payload': payload,
  };
}

/// `Receipt.status` for one outbox event.
enum OutboxReceiptStatus { accepted, duplicate, refused }

/// `Receipt`.
@immutable
class OutboxReceipt {
  const OutboxReceipt({required this.key, required this.status, this.error});

  final String key;
  final OutboxReceiptStatus status;
  final FactsBookException? error;

  factory OutboxReceipt.fromJson(Map<String, Object?> json) => OutboxReceipt(
    key: json['key']! as String,
    status: OutboxReceiptStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => OutboxReceiptStatus.refused,
    ),
    error: json['error'] == null
        ? null
        : FactsBookException.fromJson(_map(json['error'])),
  );
}

/// What a pairing gave back (`PairResponse`). The token is a credential: it
/// goes to secure storage and nowhere else.
@immutable
class PairResult {
  const PairResult({
    required this.token,
    required this.clientId,
    required this.scopes,
    required this.vault,
    required this.rootFingerprint,
    required this.node,
  });

  final String token;
  final String clientId;
  final List<String> scopes;
  final String vault;
  final String rootFingerprint;
  final String node;

  factory PairResult.fromJson(Map<String, Object?> json) => PairResult(
    token: json['token']! as String,
    clientId: json['client_id']! as String,
    scopes: [for (final s in json['scopes'] as List? ?? []) '$s'],
    vault: json['vault']! as String,
    rootFingerprint: json['root_fingerprint']! as String,
    node: json['node']! as String,
  );
}

/// A failure from the node, as plain words (`Error`: `{error:{code,message,
/// hint,retry_after_s,request_id}}`), or from reaching it. `message` and
/// `hint` come from the node's fixed catalogue; the app words its own copy
/// from [code] and puts [requestId] under Details. Never shown raw.
class FactsBookException implements Exception {
  const FactsBookException(
    this.code, {
    this.message,
    this.hint,
    this.requestId,
    this.retryAfterSeconds,
    this.status,
  });

  /// The node's `code`, or `node_unreachable` / `bad_response` for a call
  /// that never got an answer the app can read.
  final String code;
  final String? message;
  final String? hint;
  final String? requestId;
  final int? retryAfterSeconds;

  /// The HTTP status, when there was one.
  final int? status;

  /// `501 not_enabled`: the node does not offer this yet.
  bool get notEnabled => code == 'not_enabled';

  /// The change was based on something that has since changed.
  bool get stale =>
      code == 'stale_approval' ||
      code == 'precondition_failed' ||
      code == 'conflict';

  /// Could not reach the node at all: the capture path keeps the text.
  bool get unreachable => code == 'node_unreachable';

  factory FactsBookException.fromJson(
    Map<String, Object?> json, {
    int? status,
  }) => FactsBookException(
    (json['code'] as String?) ?? 'internal',
    message: json['message'] as String?,
    hint: json['hint'] as String?,
    requestId: json['request_id'] as String?,
    retryAfterSeconds: (json['retry_after_s'] as num?)?.toInt(),
    status: status,
  );

  @override
  String toString() => 'FactsBookException($code)';
}

/// `Brief`: the daily brief's settings.
@immutable
class BriefSettings {
  const BriefSettings({
    required this.capPerDay,
    required this.time,
    required this.quietHours,
  });

  final int capPerDay;

  /// `HH:MM`.
  final String time;

  /// `HH:MM-HH:MM`.
  final String quietHours;

  factory BriefSettings.fromJson(Map<String, Object?> json) => BriefSettings(
    capPerDay: (json['cap_per_day'] as num).toInt(),
    time: json['time']! as String,
    quietHours: json['quiet_hours']! as String,
  );

  Map<String, Object?> toJson() => {
    'cap_per_day': capPerDay,
    'time': time,
    'quiet_hours': quietHours,
  };

  BriefSettings copyWith({int? capPerDay}) => BriefSettings(
    capPerDay: capPerDay ?? this.capPerDay,
    time: time,
    quietHours: quietHours,
  );
}

/// `Settings` (`GET /v1/config`, admin).
@immutable
class FactsBookSettings {
  const FactsBookSettings({
    required this.revision,
    required this.vaultZone,
    required this.lockTimeoutMinutes,
    required this.brief,
    required this.raw,
  });

  final int revision;
  final String vaultZone;
  final int lockTimeoutMinutes;
  final BriefSettings brief;

  /// The object as received, so a change sends back everything else
  /// untouched (the budget stays at the node's value).
  final Map<String, Object?> raw;

  factory FactsBookSettings.fromJson(Map<String, Object?> json) =>
      FactsBookSettings(
        revision: (json['rev'] as num).toInt(),
        vaultZone: json['vault_zone']! as String,
        lockTimeoutMinutes: (json['lock_timeout_minutes'] as num).toInt(),
        brief: BriefSettings.fromJson(_map(json['brief'])),
        raw: json,
      );

  /// The settings with a new brief cap, for `PATCH /v1/config`.
  Map<String, Object?> withBriefCap(int cap) => {
    ...raw,
    'brief': brief.copyWith(capPerDay: cap).toJson(),
  };

  /// The same settings with another home time zone (an IANA name).
  Map<String, Object?> withHomeZone(String zone) => {
    ...raw,
    'vault_zone': zone,
  };
}

/// `CaptureExport`: an unsaved capture as an encrypted object the node
/// hands back. It does not unlock sensitive storage; opening it needs the
/// original local recovery credentials.
@immutable
class CaptureExport {
  const CaptureExport({required this.text, required this.item});

  /// The object as JSON text, for the person to keep.
  final String text;
  final String item;
}

/// `ControlRecord` and `ControlResponse` (`GET /v1/control`, admin): the
/// signed control chain and the root's verification material.
@immutable
class ControlRecord {
  const ControlRecord({
    required this.cseq,
    required this.kind,
    required this.signer,
    required this.sig,
    required this.raw,
    this.prev,
  });

  final int cseq;
  final String kind;
  final String signer;
  final String sig;
  final String? prev;
  final Map<String, Object?> raw;

  factory ControlRecord.fromJson(Map<String, Object?> json) => ControlRecord(
    cseq: (json['cseq'] as num).toInt(),
    kind: json['kind']! as String,
    signer: json['signer']! as String,
    sig: json['sig']! as String,
    prev: json['prev'] as String?,
    raw: json,
  );
}

@immutable
class ControlChain {
  const ControlChain({
    required this.vault,
    required this.rootFingerprint,
    required this.rootPublicKey,
    required this.records,
    required this.cseq,
    required this.forked,
    this.executor,
  });

  final String vault;
  final String rootFingerprint;
  final String rootPublicKey;
  final List<ControlRecord> records;
  final int cseq;

  /// Two competing records at one position: authority is paused.
  final bool forked;
  final String? executor;

  factory ControlChain.fromJson(Map<String, Object?> json) => ControlChain(
    vault: json['vault']! as String,
    rootFingerprint: json['root_fingerprint']! as String,
    rootPublicKey: json['root_public_key']! as String,
    records: _list(json['records'], ControlRecord.fromJson),
    cseq: (json['cseq'] as num).toInt(),
    forked: json['forked'] == true,
    executor: json['executor'] as String?,
  );
}

/// `Client` (`GET /v1/clients`, admin).
@immutable
class PairedClient {
  const PairedClient({
    required this.id,
    required this.scopes,
    required this.kind,
    this.ownerDevice,
  });

  final String id;
  final List<String> scopes;
  final String kind;
  final String? ownerDevice;

  factory PairedClient.fromJson(Map<String, Object?> json) => PairedClient(
    id: json['id']! as String,
    scopes: [for (final s in json['scopes'] as List? ?? []) '$s'],
    kind: (json['kind'] as String?) ?? 'client',
    ownerDevice: json['owner_device'] as String?,
  );
}
