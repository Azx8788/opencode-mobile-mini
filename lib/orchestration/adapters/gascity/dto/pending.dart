import 'json_read.dart';

/// A question an agent session is waiting on. Covers both the `/pending`
/// list entry (`CityPendingEntry`: `{kind, request_id, session_id}`) and
/// the fuller `PendingInteraction` (`{kind, request_id, prompt, options[],
/// metadata}`) from a session's `/pending` and its stream.
class GcPendingInteraction {
  const GcPendingInteraction({
    required this.requestId,
    this.kind,
    this.sessionId,
    this.prompt,
    this.options = const [],
    this.metadata = const {},
    this.createdAt,
    this.raw = const {},
  });

  factory GcPendingInteraction.fromJson(Map<String, Object?> json) {
    final options = <String>[];
    final rawOptions = json['options'];
    if (rawOptions is List) {
      for (final option in rawOptions) {
        if (option is String) {
          options.add(option);
        } else if (option is Map) {
          final map = readMap(option);
          final label =
              readText(map, 'label') ??
              readText(map, 'title') ??
              readText(map, 'value') ??
              readText(map, 'id');
          if (label != null) options.add(label);
        }
      }
    }
    return GcPendingInteraction(
      requestId: readText(json, 'request_id') ?? readText(json, 'id') ?? '',
      kind: readText(json, 'kind'),
      sessionId: readText(json, 'session_id'),
      prompt: readText(json, 'prompt') ?? readText(json, 'question'),
      options: options,
      metadata: readStringMap(json, 'metadata'),
      createdAt: readDateTime(json, 'created_at'),
      raw: json,
    );
  }

  final String requestId;

  /// Raw kind (`choice`, `confirm`, `text`, ...).
  final String? kind;
  final String? sessionId;
  final String? prompt;

  /// Option labels for choice interactions; empty otherwise.
  final List<String> options;
  final Map<String, String> metadata;
  final DateTime? createdAt;
  final Map<String, Object?> raw;
}

/// One entry of `GET /waits` `waits[]` (`WaitView`): a session parked on
/// a dependency, nudge or timer.
class GcWait {
  const GcWait({
    required this.id,
    this.kind,
    this.sessionId,
    this.sessionName,
    this.state,
    this.status,
    this.note,
    this.depIds = const [],
    this.depMode,
    this.labels = const [],
    this.nudgeId,
    this.createdAt,
    this.expiresAt,
    this.raw = const {},
  });

  factory GcWait.fromJson(Map<String, Object?> json) => GcWait(
    id: readText(json, 'id') ?? '',
    kind: readText(json, 'kind'),
    sessionId: readText(json, 'session_id'),
    sessionName: readText(json, 'session_name'),
    state: readText(json, 'state'),
    status: readText(json, 'status'),
    note: readText(json, 'note'),
    depIds: readStringList(json, 'dep_ids'),
    depMode: readText(json, 'dep_mode'),
    labels: readStringList(json, 'labels'),
    nudgeId: readText(json, 'nudge_id'),
    createdAt: readDateTime(json, 'created_at'),
    expiresAt: readDateTime(json, 'expires_at'),
    raw: json,
  );

  final String id;
  final String? kind;
  final String? sessionId;
  final String? sessionName;
  final String? state;
  final String? status;
  final String? note;
  final List<String> depIds;
  final String? depMode;
  final List<String> labels;
  final String? nudgeId;
  final DateTime? createdAt;
  final DateTime? expiresAt;
  final Map<String, Object?> raw;

  /// True while the wait is still parked (not resolved or expired).
  bool get isActive {
    final s = (state ?? status ?? '').toLowerCase();
    return s.isEmpty || s == 'waiting' || s == 'active' || s == 'pending';
  }
}
