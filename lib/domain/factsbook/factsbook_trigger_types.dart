import 'package:flutter/foundation.dart';

import 'factsbook_types.dart';

/// Value types of the node's local event triggers (spec 44, App API 1.3):
/// rules, tests, events, firings, reminder proposals and conversation
/// offers. Like the rest of the contract types, every `fromJson` ignores
/// unknown keys and never throws on an unknown enum word. No type here ever
/// holds the raw text of an event: the node does not return it, and an offer
/// carries only its minimized summary.

Map<String, Object?> _map(Object? value) =>
    (value as Map).cast<String, Object?>();

List<T> _list<T>(Object? value, T Function(Map<String, Object?>) read) => [
  for (final item in (value as List? ?? const [])) read(_map(item)),
];

DateTime _time(Object? value) => DateTime.parse(value! as String);

/// Where an event comes from (`TriggerSource.kind`). Notifications are not a
/// source in this milestone (gate G-NL).
enum TriggerSourceKind {
  note('note'),
  share('share'),
  chatSelection('chat_selection');

  const TriggerSourceKind(this.wire);
  final String wire;

  /// The opaque source instance this app binds a rule to, and posts events
  /// under, for each kind. Opaque ASCII; never content.
  String get defaultInstance => switch (this) {
    note => 'manual-note',
    share => 'manual-share',
    chatSelection => 'selected-chat',
  };

  /// The event kind of a capture, or null for a kind rules do not read
  /// (an import).
  static TriggerSourceKind? ofCapture(CaptureKind kind) => switch (kind) {
    CaptureKind.note => note,
    CaptureKind.share => share,
    CaptureKind.chatSelection => chatSelection,
    CaptureKind.importText => null,
  };

  static TriggerSourceKind parse(Object? raw) {
    for (final kind in values) {
      if (kind.wire == raw) return kind;
    }
    return share;
  }
}

/// `TriggerSource`: an authenticated client, a kind and an opaque instance.
/// This binding is the rule's consent; the sender or app name an event
/// claims never is.
@immutable
class TriggerSource {
  const TriggerSource({
    required this.clientId,
    required this.kind,
    required this.instance,
  });

  final String clientId;
  final TriggerSourceKind kind;
  final String instance;

  factory TriggerSource.fromJson(Map<String, Object?> json) => TriggerSource(
    clientId: (json['client_id'] as String?) ?? '',
    kind: TriggerSourceKind.parse(json['kind']),
    instance: (json['instance'] as String?) ?? '',
  );

  Map<String, Object?> toJson() => {
    'client_id': clientId,
    'kind': kind.wire,
    'instance': instance,
  };

  @override
  bool operator ==(Object other) =>
      other is TriggerSource &&
      other.clientId == clientId &&
      other.kind == kind &&
      other.instance == instance;

  @override
  int get hashCode => Object.hash(clientId, kind, instance);
}

/// `TriggerTemplate.id`. `billDue` is reserved: the node refuses it until
/// money storage is qualified, so the editor never offers it.
enum TriggerTemplateId {
  appointment('appointment'),
  delivery('delivery'),
  booking('booking'),
  subscription('subscription'),
  billDue('bill_due');

  const TriggerTemplateId(this.wire);
  final String wire;

  static TriggerTemplateId parse(Object? raw) {
    for (final id in values) {
      if (id.wire == raw) return id;
    }
    return appointment;
  }
}

/// `TriggerTemplate`: the versioned deterministic reading of a message.
@immutable
class TriggerTemplate {
  const TriggerTemplate({
    required this.id,
    this.version = currentVersion,
    this.locale = 'en',
  });

  /// The template format the node reads (B5: version 2).
  static const currentVersion = 2;

  final TriggerTemplateId id;
  final int version;

  /// `en` or `ar`: the language of the template's labels.
  final String locale;

  factory TriggerTemplate.fromJson(Map<String, Object?> json) =>
      TriggerTemplate(
        id: TriggerTemplateId.parse(json['id']),
        version: (json['version'] as num?)?.toInt() ?? currentVersion,
        locale: json['locale'] == 'ar' ? 'ar' : 'en',
      );

  Map<String, Object?> toJson() => {
    'id': id.wire,
    'version': version,
    'locale': locale,
  };

  @override
  bool operator ==(Object other) =>
      other is TriggerTemplate &&
      other.id == id &&
      other.version == version &&
      other.locale == locale;

  @override
  int get hashCode => Object.hash(id, version, locale);
}

/// `TriggerOutcome.kind`. A fact outcome is an ordinary review candidate; a
/// reminder outcome is a proposal that needs confirming; a conversation
/// outcome is an offer.
enum TriggerOutcomeKind {
  fact,
  reminder,
  conversation;

  static TriggerOutcomeKind? parse(Object? raw) {
    for (final kind in values) {
      if (kind.name == raw) return kind;
    }
    return null;
  }
}

/// `TriggerOutcome`. The raw map is kept so a fact outcome the app does not
/// build (thing, base revision) is sent back exactly as the node gave it.
@immutable
class TriggerOutcome {
  const TriggerOutcome(this.kind, {this.raw});

  final TriggerOutcomeKind kind;
  final Map<String, Object?>? raw;

  static TriggerOutcome? fromJson(Map<String, Object?> json) {
    final kind = TriggerOutcomeKind.parse(json['kind']);
    return kind == null ? null : TriggerOutcome(kind, raw: json);
  }

  Map<String, Object?> toJson() => raw ?? {'kind': kind.name};

  @override
  bool operator ==(Object other) =>
      other is TriggerOutcome && other.kind == kind;

  @override
  int get hashCode => kind.hashCode;
}

const Object _keep = Object();

/// `RuleDefinition` (format version 1).
@immutable
class RuleDefinition {
  const RuleDefinition({
    required this.name,
    required this.enabled,
    required this.source,
    required this.template,
    required this.area,
    required this.containsAll,
    required this.outcomes,
    required this.limitPerDay,
    this.autoStart = false,
    this.senderClaim,
  });

  final String name;
  final bool enabled;
  final TriggerSource source;
  final TriggerTemplate template;
  final String area;

  /// Literal, normalized substrings that must all appear (at most 4, each at
  /// most 40 bytes). Not regular expressions.
  final List<String> containsAll;
  final List<TriggerOutcome> outcomes;
  final int limitPerDay;

  /// Always false in this milestone: automatic starts are unavailable.
  final bool autoStart;

  /// An exact, normalized match on the sender an untrusted message claims.
  /// A claim anyone can make: a filter, never proof of who sent it.
  final String? senderClaim;

  bool hasOutcome(TriggerOutcomeKind kind) =>
      outcomes.any((o) => o.kind == kind);

  RuleDefinition copyWith({
    String? name,
    bool? enabled,
    TriggerSource? source,
    TriggerTemplate? template,
    String? area,
    List<String>? containsAll,
    List<TriggerOutcome>? outcomes,
    int? limitPerDay,
    Object? senderClaim = _keep,
  }) => RuleDefinition(
    name: name ?? this.name,
    enabled: enabled ?? this.enabled,
    source: source ?? this.source,
    template: template ?? this.template,
    area: area ?? this.area,
    containsAll: containsAll ?? this.containsAll,
    outcomes: outcomes ?? this.outcomes,
    limitPerDay: limitPerDay ?? this.limitPerDay,
    autoStart: autoStart,
    senderClaim: identical(senderClaim, _keep)
        ? this.senderClaim
        : senderClaim as String?,
  );

  factory RuleDefinition.fromJson(Map<String, Object?> json) => RuleDefinition(
    name: (json['name'] as String?) ?? '',
    enabled: json['enabled'] != false,
    source: TriggerSource.fromJson(_map(json['source'])),
    template: TriggerTemplate.fromJson(_map(json['template'])),
    area: (json['area'] as String?) ?? 'general',
    containsAll: [for (final c in json['contains_all'] as List? ?? []) '$c'],
    outcomes: [
      for (final o in json['outcomes'] as List? ?? [])
        ?TriggerOutcome.fromJson(_map(o)),
    ],
    limitPerDay: (json['limit_per_day'] as num?)?.toInt() ?? 20,
    autoStart: json['auto_start'] == true,
    senderClaim: json['sender_claim'] as String?,
  );

  Map<String, Object?> toJson() => {
    'v': 1,
    'name': name,
    'enabled': enabled,
    'source': source.toJson(),
    'template': template.toJson(),
    'area': area,
    'contains_all': containsAll,
    'outcomes': [for (final o in outcomes) o.toJson()],
    'limit_per_day': limitPerDay,
    // The node accepts only false until automatic starts are qualified.
    'auto_start': false,
    if (senderClaim != null && senderClaim!.trim().isNotEmpty)
      'sender_claim': senderClaim,
  };
}

/// What is wrong with a draft rule, before the node is asked. The node
/// checks all of it again; this keeps a person from sending what it will
/// refuse.
enum RuleProblem {
  nameEmpty,
  nameTooLong,
  tooManyWords,
  wordEmpty,
  wordTooLong,
  noOutcome,
  templateUnavailable,
  limitOutOfRange,
  senderClaimInvalid,
}

/// The rules of a rule, from the contract: a name of 1 to 80 bytes, at most
/// 4 words of 1 to 40 bytes, 1 to 3 outcomes, 1 to 20 firings a day, and a
/// template the node lists.
abstract final class RuleRules {
  static const maxNameBytes = 80;
  static const maxWords = 4;
  static const maxWordBytes = 40;
  static const maxOutcomes = 3;
  static const maxPerDay = 20;
  static const maxRules = 64;

  static int bytes(String text) => text.runes.fold(
    0,
    (n, r) => n + (r < 0x80 ? 1 : (r < 0x800 ? 2 : (r < 0x10000 ? 3 : 4))),
  );

  /// Trims, drops empty entries, and removes repeats (case-insensitively),
  /// the way the editor turns what was typed into the rule's words.
  static List<String> cleanWords(Iterable<String> words) {
    final seen = <String>{};
    return [
      for (final word in words)
        if (word.trim().isNotEmpty && seen.add(word.trim().toLowerCase()))
          word.trim(),
    ];
  }

  /// Splits a typed line on commas (Latin and Arabic) and line breaks.
  static List<String> splitWords(String text) =>
      cleanWords(text.split(RegExp(r'[,،\n]')));

  static List<RuleProblem> check(
    RuleDefinition rule, {
    Set<TriggerTemplateId> templates = const {
      TriggerTemplateId.appointment,
      TriggerTemplateId.delivery,
      TriggerTemplateId.booking,
      TriggerTemplateId.subscription,
    },
  }) => [
    if (rule.name.trim().isEmpty) RuleProblem.nameEmpty,
    if (bytes(rule.name.trim()) > maxNameBytes) RuleProblem.nameTooLong,
    if (rule.containsAll.length > maxWords) RuleProblem.tooManyWords,
    if (rule.containsAll.any((w) => w.trim().isEmpty)) RuleProblem.wordEmpty,
    if (rule.containsAll.any((w) => bytes(w) > maxWordBytes))
      RuleProblem.wordTooLong,
    if (rule.outcomes.isEmpty) RuleProblem.noOutcome,
    if (!templates.contains(rule.template.id)) RuleProblem.templateUnavailable,
    if (rule.limitPerDay < 1 || rule.limitPerDay > maxPerDay)
      RuleProblem.limitOutOfRange,
    if (rule.senderClaim != null &&
        (rule.senderClaim!.trim().isEmpty ||
            bytes(rule.senderClaim!.trim()) > maxNameBytes))
      RuleProblem.senderClaimInvalid,
  ];
}

/// `Rule`: a stored rule at a revision. A deleted rule keeps its history but
/// is not listed to the person.
@immutable
class Rule {
  const Rule({
    required this.id,
    required this.revision,
    required this.definition,
    required this.updatedAt,
    this.deleted = false,
  });

  final String id;
  final int revision;
  final RuleDefinition definition;
  final DateTime updatedAt;
  final bool deleted;

  factory Rule.fromJson(Map<String, Object?> json) => Rule(
    id: json['id']! as String,
    revision: (json['rev'] as num?)?.toInt() ?? 0,
    definition: RuleDefinition.fromJson(_map(json['definition'])),
    updatedAt: _time(json['updated_at']),
    deleted: json['deleted'] == true,
  );
}

/// `EventClaims`: what the sender said it was. A claim, never proof.
@immutable
class EventClaims {
  const EventClaims({this.app, this.sender});

  final String? app;
  final String? sender;

  factory EventClaims.fromJson(Map<String, Object?> json) => EventClaims(
    app: json['app'] as String?,
    sender: json['sender'] as String?,
  );

  Map<String, Object?> toJson() => {'app': ?app, 'sender': ?sender};
}

/// The template language a text is written in: Arabic when it has Arabic
/// letters, else English. The node reads only these two.
String guessEventLocale(String text) =>
    RegExp(r'[\u0600-\u06FF\u0750-\u077F]').hasMatch(text) ? 'ar' : 'en';

/// `TriggerCapture`: the sample a rule is tested on. Test sends it and
/// nothing is stored. Kept to the same shape as a real event.
@immutable
class TriggerSample {
  const TriggerSample({
    required this.kind,
    required this.text,
    required this.area,
    required this.locale,
    required this.sourceInstance,
    this.messageKey = 'sample',
    this.revision = 1,
    this.claims = const EventClaims(),
  });

  final TriggerSourceKind kind;
  final String text;
  final String area;
  final String locale;
  final String sourceInstance;
  final String messageKey;
  final int revision;
  final EventClaims claims;

  Map<String, Object?> toJson() => {
    'kind': kind.wire,
    'text': text,
    'area': area,
    'locale': locale,
    'source_instance': sourceInstance,
    'message_key': messageKey,
    'revision': revision,
    if (claims.app != null || claims.sender != null) 'claims': claims.toJson(),
  };
}

/// `EventProcessing.state`.
enum EventProcessingState {
  evaluated,
  abstained,
  capped;

  static EventProcessingState parse(Object? raw) {
    for (final s in values) {
      if (s.name == raw) return s;
    }
    return abstained;
  }
}

/// `EventProcessing.reason` and `RuleTestResult.reason`. An unknown word
/// reads as "uncertain": the cautious reading.
enum TriggerReason {
  matched('matched'),
  noMatch('no_match'),
  uncertain('uncertain'),
  sensitiveUnavailable('sensitive_unavailable'),
  sourceCap('source_cap'),
  vaultCap('vault_cap'),
  ruleCap('rule_cap'),
  stormCollapsed('storm_collapsed'),
  noEnabledRule('no_enabled_rule'),
  targetStale('target_stale'),
  targetMissing('target_missing'),
  targetDenied('target_denied'),
  rejected('rejected');

  const TriggerReason(this.wire);
  final String wire;

  static TriggerReason parse(Object? raw) {
    for (final r in values) {
      if (r.wire == raw) return r;
    }
    return uncertain;
  }
}

/// `RuleTestResult`: what a rule would do with a sample. Nothing was saved.
@immutable
class RuleTestResult {
  const RuleTestResult({
    required this.matched,
    required this.reason,
    this.summary,
    this.when,
  });

  final bool matched;
  final TriggerReason reason;

  /// The title the rule found, when it matched.
  final String? summary;

  /// The date and time it found, local ISO text.
  final String? when;

  factory RuleTestResult.fromJson(Map<String, Object?> json) => RuleTestResult(
    matched: json['matched'] == true,
    reason: TriggerReason.parse(json['reason']),
    summary: json['summary'] as String?,
    when: json['when'] as String?,
  );
}

/// `TriggerEvent.trust`.
enum EventTrust {
  userAuthored('user_authored'),
  userSelected('user_selected'),
  thirdPartyUntrusted('third_party_untrusted');

  const EventTrust(this.wire);
  final String wire;

  /// An unknown word reads as untrusted.
  static EventTrust parse(Object? raw) {
    for (final t in values) {
      if (t.wire == raw) return t;
    }
    return thirdPartyUntrusted;
  }
}

/// `TriggerEvent`: metadata only, never the raw text.
@immutable
class TriggerEvent {
  const TriggerEvent({
    required this.id,
    required this.revision,
    required this.source,
    required this.claims,
    required this.trust,
    required this.area,
    required this.sensitive,
    required this.capturedAt,
    required this.state,
    required this.reason,
    required this.firings,
    this.evidenceRef = '',
  });

  final String id;
  final int revision;

  /// The stored evidence item (`itm_`): the capture the node kept.
  final String evidenceRef;
  final TriggerSource source;
  final EventClaims claims;
  final EventTrust trust;
  final String area;

  /// `sens` was not `normal` (sensitive or uncertain).
  final bool sensitive;
  final DateTime capturedAt;
  final EventProcessingState state;
  final TriggerReason reason;

  /// Firing ids (`trg_`).
  final List<String> firings;

  factory TriggerEvent.fromJson(Map<String, Object?> json) {
    final processing = _map(json['processing']);
    return TriggerEvent(
      id: json['id']! as String,
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      source: TriggerSource.fromJson(_map(json['source'])),
      claims: EventClaims.fromJson(
        json['claims'] == null ? const {} : _map(json['claims']),
      ),
      trust: EventTrust.parse(json['trust']),
      area: (json['area'] as String?) ?? 'general',
      sensitive: json['sens'] != 'normal',
      capturedAt: _time(json['captured_at']),
      state: EventProcessingState.parse(processing['state']),
      reason: TriggerReason.parse(processing['reason']),
      firings: [for (final f in json['firings'] as List? ?? []) '$f'],
      evidenceRef: (json['evidence_ref'] as String?) ?? '',
    );
  }
}

/// `TriggerFiring.state`.
enum FiringState {
  proposed,
  capped,
  collapsed,
  suppressed;

  static FiringState parse(Object? raw) {
    for (final s in values) {
      if (s.name == raw) return s;
    }
    return suppressed;
  }
}

/// `TriggerFiring`: one rule acting on one event. [outcomes] are ids of the
/// review cards, reminder proposals and offers it made.
@immutable
class TriggerFiring {
  const TriggerFiring({
    required this.id,
    required this.eventId,
    required this.ruleId,
    required this.ruleRevision,
    required this.template,
    required this.at,
    required this.state,
    required this.outcomes,
    this.collapsedCount = 0,
    this.collapseInto,
  });

  final String id;
  final String eventId;
  final String ruleId;
  final int ruleRevision;
  final TriggerTemplate template;
  final DateTime at;
  final FiringState state;
  final List<String> outcomes;

  /// How many more messages were folded into this one (a burst).
  final int collapsedCount;
  final String? collapseInto;

  factory TriggerFiring.fromJson(Map<String, Object?> json) => TriggerFiring(
    id: json['id']! as String,
    eventId: json['event_id']! as String,
    ruleId: json['rule_id']! as String,
    ruleRevision: (json['rule_revision'] as num?)?.toInt() ?? 0,
    template: TriggerTemplate.fromJson(_map(json['template'])),
    at: _time(json['at']),
    state: FiringState.parse(json['state']),
    outcomes: [for (final o in json['outcomes'] as List? ?? []) '$o'],
    collapsedCount: (json['collapsed_count'] as num?)?.toInt() ?? 0,
    collapseInto: json['collapse_into'] as String?,
  );
}

/// `ReminderProposal.state`.
enum ProposalState {
  proposed,
  confirmed,
  rejected,
  stale;

  static ProposalState parse(Object? raw) {
    for (final s in values) {
      if (s.name == raw) return s;
    }
    return stale;
  }
}

/// `ReminderProposal`: a reminder a rule suggests. It is never a schedule
/// until the person confirms exactly this [preview].
@immutable
class ReminderProposal {
  const ReminderProposal({
    required this.id,
    required this.revision,
    required this.eventId,
    required this.firingId,
    required this.area,
    required this.preview,
    required this.digest,
    required this.state,
  });

  final String id;
  final int revision;
  final String eventId;
  final String firingId;
  final String area;
  final ReminderPreview preview;
  final String digest;
  final ProposalState state;

  factory ReminderProposal.fromJson(Map<String, Object?> json) =>
      ReminderProposal(
        id: json['id']! as String,
        revision: (json['rev'] as num?)?.toInt() ?? 0,
        eventId: (json['event_id'] as String?) ?? '',
        firingId: (json['firing_id'] as String?) ?? '',
        area: (json['area'] as String?) ?? 'general',
        preview: ReminderPreview.fromJson(_map(json['preview'])),
        digest: json['digest']! as String,
        state: ProposalState.parse(json['state']),
      );
}

/// What the person decides on a reminder proposal.
enum ProposalDecision { confirm, reject, skip }

/// `StartReceipt.status`.
enum StartStatus {
  /// Accepted; waiting for the first message to be sent (at most 15 minutes).
  pending,
  started,
  unknown,
  cancelled;

  static StartStatus parse(Object? raw) {
    for (final s in values) {
      if (s.name == raw) return s;
    }
    return unknown;
  }
}

/// `StartReceipt`: the one durable record of an offer's start, the same on
/// every client. An `unknown` one is never dispatched again.
@immutable
class StartReceipt {
  const StartReceipt({
    required this.id,
    required this.offerId,
    required this.receiptKey,
    required this.status,
    this.expiresAt,
  });

  final String id;
  final String offerId;
  final String receiptKey;
  final StartStatus status;
  final DateTime? expiresAt;

  factory StartReceipt.fromJson(Map<String, Object?> json) => StartReceipt(
    id: json['id']! as String,
    offerId: (json['offer_id'] as String?) ?? '',
    receiptKey: (json['receipt_key'] as String?) ?? '',
    status: StartStatus.parse(json['status']),
    expiresAt: json['expires_at'] == null ? null : _time(json['expires_at']),
  );
}

/// What this app reports about an accepted offer's chat.
enum OfferReport {
  /// The first message was sent (`started`, `first_message_sent: true`).
  firstMessageSent,

  /// The person left without sending.
  cancelled,

  /// A send was tried and its result is not known; never retried.
  unknown,
}

/// `ConversationOffer.state`.
enum OfferState {
  offered,

  /// Accepted; the chat has not had its first message yet.
  pending,
  started,
  unknown,
  cancelled;

  static OfferState parse(Object? raw) {
    for (final s in values) {
      if (s.name == raw) return s;
    }
    return cancelled;
  }
}

/// `ConversationOffer`: "Talk about this with your agent?". Only [summary]
/// may seed a chat; the raw message is never part of an offer.
@immutable
class ConversationOffer {
  const ConversationOffer({
    required this.id,
    required this.revision,
    required this.eventId,
    required this.firingId,
    required this.area,
    required this.summary,
    required this.digest,
    required this.state,
    required this.expiresAt,
    this.receipt,
  });

  final String id;
  final int revision;
  final String eventId;
  final String firingId;
  final String area;
  final String summary;
  final String digest;
  final OfferState state;
  final DateTime expiresAt;
  final StartReceipt? receipt;

  bool isOpen(DateTime now) =>
      state == OfferState.offered && now.isBefore(expiresAt);

  factory ConversationOffer.fromJson(Map<String, Object?> json) =>
      ConversationOffer(
        id: json['id']! as String,
        revision: (json['rev'] as num?)?.toInt() ?? 0,
        eventId: (json['event_id'] as String?) ?? '',
        firingId: (json['firing_id'] as String?) ?? '',
        area: (json['area'] as String?) ?? 'general',
        summary: (json['summary'] as String?) ?? '',
        digest: json['digest']! as String,
        state: OfferState.parse(json['state']),
        expiresAt: _time(json['expires_at']),
        receipt: json['start_receipt'] == null
            ? null
            : StartReceipt.fromJson(_map(json['start_receipt'])),
      );
}

/// How a rule fared recently, for the Triggers list: counted from firings.
@immutable
class RuleActivity {
  const RuleActivity({this.proposed = 0, this.ignored = 0, this.offers = 0});

  final int proposed;
  final int ignored;
  final int offers;
}

/// Reads a list envelope's items with [read].
List<T> readItems<T>(
  Map<String, Object?> json,
  T Function(Map<String, Object?>) read,
) => _list(json['items'], read);
