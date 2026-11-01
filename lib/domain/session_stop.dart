import '../domain/models.dart' show MessageErrorKind;

/// Whether a `session.error` event's `error` reports the person's own Stop
/// (OpenCode's `MessageAbortedError`, v1 `name` or v2 `type`), not a
/// failure. A stop needs nothing from anyone: it is never a failed run in
/// the attention feed, never "Failed" in Inbox or Work, and never an error
/// alert (F3, emulator QA 2026-09-28).
bool sessionErrorIsStop(Object? error) {
  if (error is! Map) return false;
  final name = (error['name'] ?? error['type'])?.toString();
  return MessageErrorKind.fromName(name) == MessageErrorKind.aborted;
}
