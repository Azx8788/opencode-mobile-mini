import 'json_read.dart';

/// One city event (`EventStreamEnvelope`): `{seq, type, ts, actor,
/// subject, payload}` plus the optional `run_id`, `session_id`, `step_id`
/// and `message` the host adds for some types. The same shape is the
/// `/events` page item and the `data:` of an `event: event` SSE frame.
class GcEvent {
  const GcEvent({
    required this.type,
    this.seq,
    this.ts,
    this.actor,
    this.subject,
    this.payload = const {},
    this.runId,
    this.sessionId,
    this.stepId,
    this.message,
    this.city,
    this.raw = const {},
  });

  factory GcEvent.fromJson(Map<String, Object?> json) => GcEvent(
    type: readText(json, 'type') ?? 'unknown',
    seq: readInt(json, 'seq'),
    ts: readDateTime(json, 'ts') ?? readDateTime(json, 'timestamp'),
    actor: readText(json, 'actor'),
    subject: readText(json, 'subject'),
    payload: readMapField(json, 'payload'),
    runId: readText(json, 'run_id'),
    sessionId: readText(json, 'session_id'),
    stepId: readText(json, 'step_id'),
    message: readText(json, 'message'),
    city: readText(json, 'city'),
    raw: json,
  );

  /// Dotted type (`bead.updated`, `session.woke`, `order.fired`).
  final String type;
  final int? seq;
  final DateTime? ts;
  final String? actor;
  final String? subject;
  final Map<String, Object?> payload;
  final String? runId;
  final String? sessionId;
  final String? stepId;
  final String? message;

  /// Present on `tagged_event` frames from the supervisor-wide stream.
  final String? city;
  final Map<String, Object?> raw;

  /// The `bead` object inside `bead.*` payloads, or null.
  Map<String, Object?>? get payloadBead =>
      hasMap(payload, 'bead') ? readMapField(payload, 'bead') : null;

  /// Family before the first dot (`bead`, `session`, `order`).
  String get family {
    final dot = type.indexOf('.');
    return dot < 0 ? type : type.substring(0, dot);
  }
}

/// `GET /events` page: `{items[], total, next_cursor, event_cursor}`,
/// newest first.
class GcEventsPage {
  const GcEventsPage({
    this.items = const [],
    this.total,
    this.nextCursor,
    this.eventCursor,
    this.partial = false,
    this.partialErrors = const [],
    this.raw = const {},
  });

  factory GcEventsPage.fromJson(Map<String, Object?> json) => GcEventsPage(
    items: readList(json, 'items', GcEvent.fromJson),
    total: readInt(json, 'total'),
    nextCursor: readText(json, 'next_cursor'),
    eventCursor: readText(json, 'event_cursor'),
    partial: readBool(json, 'partial') ?? false,
    partialErrors: readStringList(json, 'partial_errors'),
    raw: json,
  );

  final List<GcEvent> items;
  final int? total;
  final String? nextCursor;
  final String? eventCursor;
  final bool partial;
  final List<String> partialErrors;
  final Map<String, Object?> raw;

  /// Highest `seq` on the page, for the resume cursor.
  int? get maxSeq {
    int? max;
    for (final item in items) {
      final seq = item.seq;
      if (seq != null && (max == null || seq > max)) max = seq;
    }
    return max;
  }
}

/// `data:` of an `event: heartbeat` frame (`HeartbeatEvent`):
/// `{timestamp}`.
class GcHeartbeat {
  const GcHeartbeat({this.timestamp, this.raw = const {}});

  factory GcHeartbeat.fromJson(Map<String, Object?> json) => GcHeartbeat(
    timestamp: readDateTime(json, 'timestamp') ?? readDateTime(json, 'ts'),
    raw: json,
  );

  final DateTime? timestamp;
  final Map<String, Object?> raw;
}

/// One decoded SSE frame as the fixture logs record it: `{id, event,
/// data}`. `event` is `event` / `tagged_event` (city events), `heartbeat`,
/// or `turn` / `pending` / `activity` on a session stream. A frame with no
/// `event` name and a `data` carrying only `timestamp` is a heartbeat.
class GcStreamFrame {
  const GcStreamFrame({
    required this.event,
    this.id,
    this.data = const {},
    this.raw = const {},
  });

  factory GcStreamFrame.fromJson(Map<String, Object?> json) {
    // A bare event envelope (no `event`/`data` wrapper) is accepted too so
    // `/events` items and stream frames go through the same decoder.
    if (!json.containsKey('data') && json.containsKey('type')) {
      return GcStreamFrame(
        event: 'event',
        id: readText(json, 'seq'),
        data: json,
        raw: json,
      );
    }
    final data = readMapField(json, 'data');
    final event =
        readText(json, 'event') ??
        (data.keys.length == 1 && data.containsKey('timestamp')
            ? 'heartbeat'
            : data.containsKey('type')
            ? 'event'
            : 'message');
    return GcStreamFrame(
      event: event,
      id: readText(json, 'id'),
      data: data,
      raw: json,
    );
  }

  /// SSE event name.
  final String event;

  /// SSE `id:` (the `seq` on city streams, a cursor string on session
  /// streams).
  final String? id;
  final Map<String, Object?> data;
  final Map<String, Object?> raw;

  bool get isHeartbeat => event == 'heartbeat';
  bool get isCityEvent => event == 'event' || event == 'tagged_event';
  bool get isTurn => event == 'turn';
  bool get isPending => event == 'pending';

  /// The frame's `id:` as an integer, else the `seq` inside [data].
  int? get seq => toInt(id) ?? toInt(data['seq']);

  /// Decodes [data] as a city event; only meaningful when [isCityEvent].
  GcEvent toEvent() => GcEvent.fromJson(data);

  GcHeartbeat toHeartbeat() => GcHeartbeat.fromJson(data);
}
