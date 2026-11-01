import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import 'factsbook_gateway.dart';
import 'factsbook_capabilities.dart';
import 'factsbook_trigger_types.dart';
import 'factsbook_types.dart';
import 'owner_signer.dart';

/// The App API v1 over HTTP (`factsbook/api/openapi-v1.yaml`): a bearer
/// token, JSON, and the node's error envelope mapped to
/// [FactsBookException] (the app words it; the node's `request_id` goes under
/// Details). Mutations carry an `Idempotency-Key`. Review decisions, area
/// sharing and settings also carry the owner [OwnerSigner]'s proof; without
/// one they fail with `owner_required`.
///
/// Nothing here logs a body, a token or a header.
class HttpFactsBookGateway implements FactsBookGateway {
  HttpFactsBookGateway({
    required this.baseUrl,
    required String token,
    this.owner,
    Dio? dio,
    Random? random,
    this.retryDelay = const Duration(milliseconds: 250),
  }) : _random = random ?? Random.secure(),
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 8),
               receiveTimeout: const Duration(seconds: 20),
               sendTimeout: const Duration(seconds: 20),
               responseType: ResponseType.plain,
               validateStatus: (_) => true,
             ),
           ),
       _token = token;

  final Uri baseUrl;
  final OwnerSigner? owner;
  final Dio _dio;
  final Random _random;
  final String _token;

  /// How long to wait before asking again after a 429 (grows with each try).
  final Duration retryDelay;

  /// The node answers 429 `slow_down` to a request that arrives while it is
  /// busy with another (it takes one request at a time), whatever
  /// `retry_after_s` says. So requests go one at a time, in order, and a 429
  /// is asked again a few times, briefly, before it is shown. Every
  /// mutation carries its idempotency key and is refused before it is
  /// processed, so asking again never saves twice.
  Future<void> _tail = Future<void>.value();

  Future<T> _one<T>(Future<T> Function() task) {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return previous
        .catchError((Object _) {})
        .then((_) => task())
        .whenComplete(done.complete);
  }

  /// A page limit a list call follows, so one bad cursor cannot loop.
  static const _maxPages = 20;

  String _key() {
    // Letters only: the node's content classifier reads keys too.
    const letters = 'abcdefghijklmnopqrstuvwxyz';
    return 'app-${List.generate(24, (_) => letters[_random.nextInt(26)]).join()}';
  }

  Future<Object?> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    String? idempotencyKey,
    bool authorized = true,
  }) => _one(() async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await sendRequest(
          _dio,
          baseUrl,
          method,
          path,
          token: authorized ? _token : null,
          query: query,
          body: body,
          idempotencyKey: idempotencyKey,
        );
      } on FactsBookException catch (failure) {
        // 429 `slow_down` and 503 `busy` both mean "ask again in a moment".
        final again = failure.status == 429 || failure.code == 'busy';
        if (!again || attempt >= 3) rethrow;
        await Future<void>.delayed(retryDelay * (attempt + 1));
      }
    }
  });

  Future<List<T>> _all<T>(
    String path,
    T Function(Map<String, Object?>) read, {
    Map<String, String> query = const {},
  }) async {
    final out = <T>[];
    String? cursor;
    for (var page = 0; page < _maxPages; page++) {
      final json = _object(
        await _send(
          'GET',
          path,
          query: {'limit': '200', ...query, 'cursor': ?cursor},
        ),
      );
      for (final item in json['items'] as List? ?? const []) {
        out.add(read((item as Map).cast<String, Object?>()));
      }
      cursor = json['next_cursor'] as String?;
      if (cursor == null) break;
    }
    return out;
  }

  static Map<String, Object?> _object(Object? json) {
    if (json is Map) return json.cast<String, Object?>();
    throw const FactsBookException('bad_response');
  }

  /// Parses a response with [read], so a body the app cannot read is a plain
  /// failure and never a crash.
  static T _read<T>(Object? json, T Function(Map<String, Object?>) read) {
    try {
      return read(_object(json));
    } on FactsBookException {
      rethrow;
    } on Object {
      throw const FactsBookException('bad_response');
    }
  }

  Future<Map<String, Object?>> _signed(
    String method,
    String path,
    Map<String, Object?> body,
  ) async {
    final signer = owner;
    if (signer == null) throw const FactsBookException('owner_required');
    return {
      ...body,
      'proof': await signer.proof(method: method, path: path, body: body),
    };
  }

  @override
  Future<NodeStatus> status() async =>
      _read(await _send('GET', '/v1/status'), NodeStatus.fromJson);

  @override
  Future<List<Thing>> things({ThingKind? kind}) => _all(
    '/v1/things',
    Thing.fromJson,
    query: {if (kind != null && kind != ThingKind.other) 'kind': kind.name},
  );

  /// The categories `FactInput` accepts; anything else is sent as a note.
  static const _categories = {
    'preference',
    'habit',
    'fact',
    'note',
    'task',
    'relationship',
    'event',
  };

  @override
  Future<MutationResult> addFact(Thing thing, String text) async => _read(
    await _send(
      'POST',
      '/v1/things/${Uri.encodeComponent(thing.id)}/facts',
      body: {'text': text, 'category': 'note', 'base_rev': thing.revision},
      idempotencyKey: _key(),
    ),
    MutationResult.fromJson,
  );

  @override
  Future<MutationResult> editFact(Fact fact, String text) async => _read(
    await _send(
      'PATCH',
      '/v1/facts/${Uri.encodeComponent(fact.id)}',
      body: {
        'text': text,
        'category': _categories.contains(fact.category)
            ? fact.category
            : 'note',
        'base_rev': fact.revision,
      },
      idempotencyKey: _key(),
    ),
    MutationResult.fromJson,
  );

  @override
  Future<Thing> thing(String id) async => _read(
    await _send('GET', '/v1/things/${Uri.encodeComponent(id)}'),
    Thing.fromJson,
  );

  @override
  Future<SearchResult> search(String query) async {
    final hits = await _all(
      '/v1/search',
      SearchHit.fromJson,
      query: {'q': query},
    );
    var lockedSkipped = true;
    try {
      lockedSkipped = (await status()).indexSensitive != 'ok';
    } on FactsBookException {
      // The hits stand; the locked-notes line stays on.
    }
    return SearchResult(
      query: query,
      hits: hits,
      lockedNotesSkipped: lockedSkipped,
    );
  }

  @override
  Future<CaptureResult> capture(
    CaptureRequest request, {
    required String idempotencyKey,
  }) async => _read(
    await _send(
      'POST',
      '/v1/inbox',
      body: request.toJson(),
      idempotencyKey: idempotencyKey,
    ),
    CaptureResult.fromJson,
  );

  @override
  Future<List<CouldNotSaveEntry>> pendingCaptures() =>
      _all('/v1/inbox/pending', CouldNotSaveEntry.fromJson);

  @override
  Future<CaptureResult> retryCapture(
    String id, {
    required String idempotencyKey,
  }) async => _read(
    await _send(
      'POST',
      '/v1/inbox/${Uri.encodeComponent(id)}/retry',
      idempotencyKey: idempotencyKey,
    ),
    CaptureResult.fromJson,
  );

  @override
  Future<void> discardCapture(
    String id, {
    required String idempotencyKey,
  }) async {
    await _send(
      'DELETE',
      '/v1/inbox/${Uri.encodeComponent(id)}',
      idempotencyKey: idempotencyKey,
    );
  }

  @override
  Future<List<OutboxReceipt>> sendOutbox(List<OutboxEvent> events) async {
    final json = _object(
      await _send(
        'POST',
        '/v1/outbox',
        body: {
          'events': [for (final e in events) e.toJson()],
        },
        idempotencyKey: _key(),
      ),
    );
    return [
      for (final r in json['receipts'] as List? ?? const [])
        OutboxReceipt.fromJson((r as Map).cast<String, Object?>()),
    ];
  }

  @override
  Future<List<ReviewItem>> reviewItems() async => [
    // The node lists every proposal it has had; only the ones still waiting
    // are the person's to decide (approved, rejected and stale ones are not).
    for (final item in await _all('/v1/review', ReviewItem.fromJson))
      if (item.state == ReviewState.proposed) item,
  ];

  @override
  Future<MutationResult> decideReview(
    ReviewItem item,
    ReviewDecision decision, {
    Map<String, Object?>? edited,
  }) async {
    final path = '/v1/review/${Uri.encodeComponent(item.id)}/decision';
    final body = await _signed('POST', path, {
      'decision': decision.name,
      'digest': item.digest,
      'preconditions': item.preconditions,
      'edited': ?edited,
    });
    return _read(
      await _send('POST', path, body: body, idempotencyKey: _key()),
      MutationResult.fromJson,
    );
  }

  static String _id(Random random) {
    // A schedule id the node accepts: `sch_` and 26 Crockford characters,
    // the first of them 0 to 7.
    const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    final body = StringBuffer(alphabet[random.nextInt(8)]);
    for (var i = 0; i < 25; i++) {
      body.write(alphabet[random.nextInt(32)]);
    }
    return 'sch_$body';
  }

  /// The structured form the node reads: the schedule as JSON text and the
  /// title in its own field, so nothing depends on a free-text shape.
  static String scheduleText({
    required String id,
    required ReminderTiming timing,
    required String zone,
  }) => jsonEncode({
    'v': 1,
    'id': id,
    'when': timing.toWhen(),
    'zone': zone,
    'window': null,
    'catchup': 'coalesce',
  });

  @override
  Future<ReminderPreview> previewReminder({
    required String what,
    required ReminderTiming timing,
    required String zone,
    required String locale,
    String? scheduleId,
    String area = 'general',
  }) async => _read(
    await _send(
      'POST',
      '/v1/reminders/parse',
      body: {
        'text': scheduleText(
          id: scheduleId ?? _id(_random),
          timing: timing,
          zone: zone,
        ),
        'what': what.trim(),
        'locale': locale,
        'zone': zone,
        'area': area,
      },
    ),
    ReminderPreview.fromJson,
  );

  @override
  Future<MutationResult> createReminder(
    ReminderPreview preview, {
    bool urgent = false,
    bool floatingConfirmed = false,
  }) async => _read(
    await _send(
      'POST',
      '/v1/reminders',
      body: {
        'preview': preview.raw,
        'preview_digest': preview.digest,
        'confirmed': true,
        'urgent': urgent,
        if (floatingConfirmed) 'floating_confirmed': true,
      },
      idempotencyKey: _key(),
    ),
    MutationResult.fromJson,
  );

  @override
  Future<List<Reminder>> reminders() =>
      _all('/v1/reminders', Reminder.fromJson);

  @override
  Future<MutationResult> setReminderPaused(
    Reminder reminder, {
    required bool paused,
  }) async => _read(
    await _send(
      'PATCH',
      '/v1/reminders/${Uri.encodeComponent(reminder.id)}',
      body: {'base_rev': reminder.revision, 'paused': paused},
      idempotencyKey: _key(),
    ),
    MutationResult.fromJson,
  );

  @override
  Future<MutationResult> updateReminder(
    Reminder reminder,
    ReminderPreview preview, {
    bool floatingConfirmed = false,
  }) async => _read(
    await _send(
      'PATCH',
      '/v1/reminders/${Uri.encodeComponent(reminder.id)}',
      body: {
        'base_rev': reminder.revision,
        'preview': preview.raw,
        'preview_digest': preview.digest,
        'confirmed': true,
        if (floatingConfirmed) 'floating_confirmed': true,
      },
      idempotencyKey: _key(),
    ),
    MutationResult.fromJson,
  );

  @override
  Future<List<Area>> areas() => _all('/v1/areas', Area.fromJson);

  @override
  Future<MutationResult> setAreaShare(Area area, AreaShare share) async {
    if (owner == null) throw const FactsBookException('owner_required');
    final policy = _object(await _send('GET', '/v1/policy'));
    final path = '/v1/areas/${Uri.encodeComponent(area.slug)}';
    final body = await _signed('PATCH', path, {
      'base_rev': (policy['policy_version'] as num?)?.toInt() ?? 0,
      'area': area.copyWith(share: share).toJson(),
    });
    return _read(
      await _send('PATCH', path, body: body, idempotencyKey: _key()),
      MutationResult.fromJson,
    );
  }

  @override
  Future<FactsBookSettings> settings() async =>
      _read(await _send('GET', '/v1/config'), FactsBookSettings.fromJson);

  @override
  Future<MutationResult> setBriefCap(FactsBookSettings current, int cap) async {
    const path = '/v1/config';
    final body = await _signed('PATCH', path, {
      'base_rev': current.revision,
      'settings': current.withBriefCap(cap),
    });
    return _read(
      await _send('PATCH', path, body: body, idempotencyKey: _key()),
      MutationResult.fromJson,
    );
  }

  @override
  Future<MutationResult> setHomeZone(
    FactsBookSettings current,
    String zone,
  ) async {
    const path = '/v1/config';
    final body = await _signed('PATCH', path, {
      'base_rev': current.revision,
      'settings': current.withHomeZone(zone),
    });
    return _read(
      await _send('PATCH', path, body: body, idempotencyKey: _key()),
      MutationResult.fromJson,
    );
  }

  @override
  Future<CaptureExport> exportCapture(String id) async {
    final json = await _send(
      'GET',
      '/v1/inbox/${Uri.encodeComponent(id)}/export',
    );
    final object = _object(json);
    return CaptureExport(
      text: const JsonEncoder.withIndent('  ').convert(object),
      item: (object['item'] as String?) ?? '',
    );
  }

  @override
  Future<ControlChain> control() async => _read(
    await _send('GET', '/v1/control', query: {'since': '0'}),
    ControlChain.fromJson,
  );

  // --- Event triggers ------------------------------------------------------

  @override
  Future<List<Rule>> rules() async => [
    for (final rule in await _all('/v1/rules', Rule.fromJson))
      if (!rule.deleted) rule,
  ];

  @override
  Future<Rule> saveRule(RuleDefinition definition, {Rule? replacing}) async {
    final path = replacing == null
        ? '/v1/rules'
        : '/v1/rules/${Uri.encodeComponent(replacing.id)}';
    final method = replacing == null ? 'POST' : 'PUT';
    final body = await _signed(method, path, {
      'base_rev': replacing?.revision ?? 0,
      'rule': definition.toJson(),
    });
    return _read(
      await _send(method, path, body: body, idempotencyKey: _key()),
      Rule.fromJson,
    );
  }

  @override
  Future<Rule> deleteRule(Rule rule) async {
    final path = '/v1/rules/${Uri.encodeComponent(rule.id)}';
    final body = await _signed('DELETE', path, {'base_rev': rule.revision});
    return _read(
      await _send('DELETE', path, body: body, idempotencyKey: _key()),
      Rule.fromJson,
    );
  }

  @override
  Future<RuleTestResult> testRule(Rule rule, TriggerSample sample) async =>
      _read(
        await _send(
          'POST',
          '/v1/rules/${Uri.encodeComponent(rule.id)}/test',
          body: {'sample': sample.toJson()},
        ),
        RuleTestResult.fromJson,
      );

  @override
  Future<TriggerEvent> postEvent(
    TriggerSample sample, {
    required String idempotencyKey,
    bool classifyNormal = false,
  }) async {
    const path = '/v1/events';
    final base = {
      ...sample.toJson(),
      if (classifyNormal) 'classify_normal': true,
    };
    final body = classifyNormal ? await _signed('POST', path, base) : base;
    final json = _object(
      await _send('POST', path, body: body, idempotencyKey: idempotencyKey),
    );
    return _read(json['event'], TriggerEvent.fromJson);
  }

  @override
  Future<RuleTestResult> testDraft(
    RuleDefinition draft,
    TriggerSample sample,
  ) async => _read(
    await _send(
      'POST',
      '/v1/rules/test',
      body: {'rule': draft.toJson(), 'sample': sample.toJson()},
    ),
    RuleTestResult.fromJson,
  );

  @override
  Future<FactsBookCapabilities> capabilities() async => _read(
    await _send('GET', '/v1/capabilities'),
    FactsBookCapabilities.fromJson,
  );

  @override
  Future<MutationResult> editReminderProposal(
    ReminderProposal proposal,
    ReminderPreview preview,
  ) async {
    final path =
        '/v1/reminder-proposals/${Uri.encodeComponent(proposal.id)}/decision';
    final body = await _signed('POST', path, {
      'decision': 'edit',
      'rev': proposal.revision,
      'digest': proposal.digest,
      'preview': preview.raw,
      'preview_digest': preview.digest,
    });
    return _read(
      await _send('POST', path, body: body, idempotencyKey: _key()),
      MutationResult.fromJson,
    );
  }

  @override
  Future<List<TriggerEvent>> events() =>
      _all('/v1/events', TriggerEvent.fromJson);

  @override
  Future<TriggerEvent> event(String id) async => _read(
    await _send('GET', '/v1/events/${Uri.encodeComponent(id)}'),
    TriggerEvent.fromJson,
  );

  @override
  Future<List<TriggerFiring>> firings() =>
      _all('/v1/trigger-firings', TriggerFiring.fromJson);

  @override
  Future<List<ReminderProposal>> reminderProposals() async => [
    for (final p in await _all(
      '/v1/reminder-proposals',
      ReminderProposal.fromJson,
    ))
      if (p.state == ProposalState.proposed) p,
  ];

  @override
  Future<MutationResult> decideReminderProposal(
    ReminderProposal proposal,
    ProposalDecision decision,
  ) async {
    final path =
        '/v1/reminder-proposals/${Uri.encodeComponent(proposal.id)}/decision';
    final body = await _signed('POST', path, {
      'decision': decision.name,
      'rev': proposal.revision,
      'digest': proposal.digest,
    });
    return _read(
      await _send('POST', path, body: body, idempotencyKey: _key()),
      MutationResult.fromJson,
    );
  }

  @override
  Future<List<ConversationOffer>> offers() =>
      _all('/v1/offers', ConversationOffer.fromJson);

  @override
  Future<StartReceipt> acceptOffer(
    ConversationOffer offer, {
    required String receiptKey,
  }) async => _read(
    await _send(
      'POST',
      '/v1/offers/${Uri.encodeComponent(offer.id)}/accept',
      body: {
        'rev': offer.revision,
        'digest': offer.digest,
        'receipt_key': receiptKey,
        // This phone opens the chat itself and reports what became of it.
        'adapter': 'client_report',
      },
      idempotencyKey: _key(),
    ),
    StartReceipt.fromJson,
  );

  @override
  Future<StartReceipt> reportOffer(
    ConversationOffer offer,
    StartReceipt receipt,
    OfferReport report,
  ) async => _read(
    await _send(
      'POST',
      '/v1/offers/${Uri.encodeComponent(offer.id)}/receipt',
      body: {
        'start_id': receipt.id,
        'receipt_key': receipt.receiptKey,
        'status': switch (report) {
          OfferReport.firstMessageSent => 'started',
          OfferReport.cancelled => 'cancelled',
          OfferReport.unknown => 'unknown',
        },
        if (report == OfferReport.firstMessageSent) 'first_message_sent': true,
      },
      idempotencyKey: _key(),
    ),
    StartReceipt.fromJson,
  );

  @override
  Future<ConversationOffer> cancelOffer(ConversationOffer offer) async => _read(
    await _send(
      'POST',
      '/v1/offers/${Uri.encodeComponent(offer.id)}/cancel',
      body: {'rev': offer.revision, 'digest': offer.digest},
      idempotencyKey: _key(),
    ),
    ConversationOffer.fromJson,
  );
}

/// One request, one decoded answer, or a [FactsBookException].
///
/// A response with a status of 400 or more is read as the node's error
/// envelope; one the app cannot read still becomes a plain failure. A call
/// that never got an answer is `node_unreachable`, which is what the capture
/// path keeps text on the phone for.
Future<Object?> sendRequest(
  Dio dio,
  Uri baseUrl,
  String method,
  String path, {
  String? token,
  Map<String, String>? query,
  Object? body,
  String? idempotencyKey,
}) async {
  final uri = baseUrl.replace(
    path: path,
    queryParameters: query == null || query.isEmpty ? null : query,
  );
  // The node refuses a write that does not say it is JSON, even with nothing
  // to send (a retry has no body): send an empty object.
  final sends = body ?? (method == 'GET' || method == 'DELETE' ? null : {});
  final Response<Object?> response;
  try {
    response = await dio.requestUri<Object?>(
      uri,
      data: sends == null ? null : jsonEncode(sends),
      options: Options(
        method: method,
        // Bytes, decoded here: a body that is not JSON (a proxy's page) is a
        // plain failure, not a transport error.
        responseType: ResponseType.bytes,
        headers: {
          'Accept': 'application/json',
          if (sends != null) 'Content-Type': 'application/json',
          'Authorization': ?(token == null ? null : 'Bearer $token'),
          'Idempotency-Key': ?idempotencyKey,
        },
      ),
    );
  } on DioException catch (error) {
    final status = error.response?.statusCode;
    if (status == null) throw const FactsBookException('node_unreachable');
    throw FactsBookException('bad_response', status: status);
  }
  final status = response.statusCode ?? 0;
  Object? decoded;
  final raw = response.data;
  try {
    if (raw is List<int> && raw.isNotEmpty) {
      decoded = jsonDecode(utf8.decode(raw));
    } else if (raw is String && raw.isNotEmpty) {
      decoded = jsonDecode(raw);
    }
  } on FormatException {
    decoded = null;
  }
  if (status >= 400) {
    if (decoded is Map && decoded['error'] is Map) {
      throw FactsBookException.fromJson(
        (decoded['error'] as Map).cast<String, Object?>(),
        status: status,
      );
    }
    throw FactsBookException(_codeFor(status), status: status);
  }
  return decoded;
}

String _codeFor(int status) => switch (status) {
  401 => 'unauthorized',
  403 => 'forbidden_scope',
  404 => 'not_found',
  409 => 'conflict',
  412 => 'precondition_failed',
  423 => 'locked_no_key',
  429 => 'slow_down',
  501 => 'not_enabled',
  503 => 'starting',
  _ => 'internal',
};

/// Pairing: one-time code to a bearer token (`POST /v1/pair`), after a
/// look at `GET /v1/info` to confirm this is a FactsBook node.
abstract final class FactsBookPairing {
  static Dio _dio() => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 20),
      responseType: ResponseType.plain,
      validateStatus: (_) => true,
    ),
  );

  /// `{node_id, node_version, api_versions, name}`; no vault data.
  static Future<Map<String, Object?>> info(Uri baseUrl, {Dio? dio}) async {
    final json = await sendRequest(dio ?? _dio(), baseUrl, 'GET', '/v1/info');
    if (json is! Map) throw const FactsBookException('bad_response');
    return json.cast<String, Object?>();
  }

  /// Sends the code with the name and powers this client asks for. Only the
  /// intersection with what the node's console approved is granted.
  static Future<PairResult> pair(
    Uri baseUrl, {
    required String code,
    required String clientName,
    List<String> scopes = const ['read', 'write'],
    Dio? dio,
  }) async {
    final json = await sendRequest(
      dio ?? _dio(),
      baseUrl,
      'POST',
      '/v1/pair',
      body: {
        'code': code.trim(),
        'client_name': clientName,
        'scopes_requested': scopes,
      },
    );
    if (json is! Map) throw const FactsBookException('bad_response');
    try {
      return PairResult.fromJson(json.cast<String, Object?>());
    } on Object {
      throw const FactsBookException('bad_response');
    }
  }
}
