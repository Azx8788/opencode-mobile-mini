/// One append-only activity line (Gas City `/events` item:
/// `{seq, type, ts, actor, subject, payload}`).
class ActivityEvent {
  const ActivityEvent({
    required this.type,
    this.seq,
    this.id,
    this.timestamp,
    this.actor,
    this.subject,
    this.summary,
    this.payload = const {},
    this.raw = const {},
  });

  /// Provider event type, e.g. `bead.updated`, `session.woke`.
  final String type;

  /// Monotonic provider sequence; also the stream cursor.
  final int? seq;
  final String? id;
  final DateTime? timestamp;

  /// Who caused it (agent, person, controller).
  final String? actor;

  /// What it is about (bead id, session name, run id).
  final String? subject;

  /// Short human line derived by the adapter; null when nothing better than
  /// [type] is known.
  final String? summary;

  /// Provider event payload.
  final Map<String, Object?> payload;

  /// Untouched provider payload.
  final Map<String, Object?> raw;

  @override
  String toString() => 'ActivityEvent(${seq ?? '-'}, $type)';
}
