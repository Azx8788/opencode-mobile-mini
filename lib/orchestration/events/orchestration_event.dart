import '../models/activity_event.dart';
import '../models/run.dart';

/// One decoded frame from the orchestration event stream. Adapters map
/// provider event types onto these; anything unrecognised becomes an
/// [UnknownOrchestrationEvent] so a new provider type never drops the
/// stream.
sealed class OrchestrationEvent {
  const OrchestrationEvent({this.seq, this.raw = const {}});

  /// Provider sequence number; null when the frame carried none.
  final int? seq;

  /// Untouched provider frame.
  final Map<String, Object?> raw;

  /// Provider event type string (`bead.updated`, `session.woke`, ...).
  String get type;
}

/// How a work item changed.
enum BeadChange { created, updated, closed }

/// A work item (bead) was created, updated or closed.
final class BeadChanged extends OrchestrationEvent {
  const BeadChanged({
    required this.beadId,
    required this.change,
    super.seq,
    super.raw,
  });

  final String beadId;
  final BeadChange change;

  @override
  String get type => 'bead.${change.name}';
}

/// A run's state changed (formula run or batch/convoy).
final class RunChanged extends OrchestrationEvent {
  const RunChanged({
    required this.runId,
    this.state = RunState.unknown,
    this.rawState,
    super.seq,
    super.raw,
  });

  final String runId;
  final RunState state;

  /// Provider status string the [state] was derived from.
  final String? rawState;

  @override
  String get type => 'run.changed';
}

/// How an agent session changed.
enum SessionChange { woke, stopped }

/// An agent session woke or stopped.
final class SessionChanged extends OrchestrationEvent {
  const SessionChanged({
    required this.sessionId,
    required this.change,
    this.agentId,
    super.seq,
    super.raw,
  });

  final String sessionId;
  final SessionChange change;
  final String? agentId;

  @override
  String get type => 'session.${change.name}';
}

/// A gate appeared or was resolved.
final class GateChanged extends OrchestrationEvent {
  const GateChanged({
    required this.gateId,
    this.resolved = false,
    super.seq,
    super.raw,
  });

  final String gateId;

  /// True when the gate no longer needs the person.
  final bool resolved;

  @override
  String get type => resolved ? 'gate.resolved' : 'gate.opened';
}

/// An activity line was appended; the timeline is append-only from these.
final class ActivityAppended extends OrchestrationEvent {
  const ActivityAppended({required this.event, super.seq, super.raw});

  final ActivityEvent event;

  @override
  String get type => event.type;
}

/// The host finished (or failed) an asynchronous write: `request.result.*`
/// with the correlation id a 202 answer carried, or `request.failed` with
/// the same id plus an error. The controller matches [requestId] against
/// the receipt it stored before sending (04-plugin-architecture §6).
final class RequestResult extends OrchestrationEvent {
  const RequestResult({
    required this.requestId,
    required this.ok,
    this.operation,
    this.errorCode,
    this.errorMessage,
    this.payload = const {},
    super.seq,
    super.raw,
  });

  /// The supervisor's correlation id (`payload.request_id`).
  final String requestId;

  /// True for `request.result.*`, false for `request.failed`.
  final bool ok;

  /// What the request did: the type's tail for a result
  /// (`session.message`), `payload.operation` for a failure.
  final String? operation;
  final String? errorCode;
  final String? errorMessage;

  /// The event payload as sent.
  final Map<String, Object?> payload;

  @override
  String get type => ok
      ? 'request.result${operation == null ? '' : '.$operation'}'
      : 'request.failed';
}

/// Keep-alive frame (`data:{"timestamp"}`); resets the stall timer only.
final class StreamHeartbeat extends OrchestrationEvent {
  const StreamHeartbeat({this.timestamp, super.seq, super.raw});

  final DateTime? timestamp;

  @override
  String get type => 'heartbeat';
}

/// The stream resumed from the provider's head instead of the requested
/// cursor (the first id after a (re)connect was not `cursor + 1`), so
/// events may have been missed: the controller marks every scope dirty
/// and refetches. Carries no provider payload.
final class StreamHeadOnlyReplay extends OrchestrationEvent {
  const StreamHeadOnlyReplay({
    required this.requestedSeq,
    required this.firstSeq,
    super.raw,
  }) : super(seq: firstSeq);

  /// The `seq` the client asked to resume after.
  final int requestedSeq;

  /// The `seq` the provider actually sent first.
  final int firstSeq;

  @override
  String get type => 'stream.head_only_replay';
}

/// A provider event type the app does not model yet. Kept, never dropped.
final class UnknownOrchestrationEvent extends OrchestrationEvent {
  const UnknownOrchestrationEvent({required this.type, super.seq, super.raw});

  @override
  final String type;
}
