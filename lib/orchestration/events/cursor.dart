/// Resume position in the orchestration event stream.
///
/// Gas City stamps SSE frames with `id: <seq>` and accepts both
/// `Last-Event-ID` and `?after_seq=N` on reconnect; the cursor carries the
/// numeric [seq] and the last raw id so either form can be replayed.
class EventCursor {
  const EventCursor({this.seq, this.lastEventId});

  /// Nothing consumed yet; a fresh subscription starts at the head.
  static const none = EventCursor();

  /// Highest sequence number seen, when the provider numbers events.
  final int? seq;

  /// Raw `id:` of the last frame, when it is not a plain integer.
  final String? lastEventId;

  /// True when there is nothing to resume from.
  bool get isEmpty => seq == null && (lastEventId?.isEmpty ?? true);

  /// The `Last-Event-ID` value to send, or null when [isEmpty].
  String? get lastEventIdHeader {
    final id = lastEventId;
    if (id != null && id.isNotEmpty) return id;
    final s = seq;
    return s == null ? null : '$s';
  }

  /// Headers to add to a resume request; empty when [isEmpty].
  Map<String, String> resumeHeaders() {
    final value = lastEventIdHeader;
    return value == null ? const {} : {'Last-Event-ID': value};
  }

  /// Query parameters for providers that resume by `after_seq`; empty when
  /// no numeric sequence is known.
  Map<String, String> resumeQuery() =>
      seq == null ? const {} : {'after_seq': '$seq'};

  /// Cursor moved to [seq], or unchanged when [seq] is null or behind.
  EventCursor advance(int? seq, {String? eventId}) {
    if (seq == null) {
      return eventId == null
          ? this
          : EventCursor(seq: this.seq, lastEventId: eventId);
    }
    final current = this.seq;
    if (current != null && seq < current) return this;
    return EventCursor(seq: seq, lastEventId: eventId ?? '$seq');
  }

  @override
  bool operator ==(Object other) =>
      other is EventCursor &&
      other.seq == seq &&
      other.lastEventId == lastEventId;

  @override
  int get hashCode => Object.hash(seq, lastEventId);

  @override
  String toString() => 'EventCursor(seq: $seq, id: $lastEventId)';
}
