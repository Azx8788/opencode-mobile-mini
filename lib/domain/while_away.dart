import '../domain/models.dart';
import 'return_brief.dart';

/// Completed automatic actions, never requests for the person to answer.
enum AutomaticActKind {
  reconnect,
  restart,
  heatPause,
  heatStop,
  heatResume,
  update,
  permissionApproval,
  queuedSend,
  other,
}

/// One observed automatic action within a profile's location.
///
/// [summary] is presentation copy, not a diagnostic payload. The recording
/// service sanitizes it before persistence. An undo callback belongs to that
/// service, not this serializable value; [undone] reports a confirmed outcome.
class AutomaticAct {
  const AutomaticAct({
    required this.id,
    required this.locationKey,
    required this.kind,
    required this.summary,
    required this.occurredAt,
    this.sessionId,
    this.acknowledged = false,
    this.undoAttempted = false,
    this.undone = false,
  });

  final String id;
  final String locationKey;
  final AutomaticActKind kind;
  final String summary;
  final DateTime occurredAt;
  final String? sessionId;
  final bool acknowledged;
  final bool undoAttempted;
  final bool undone;

  AutomaticAct copyWith({
    bool? acknowledged,
    bool? undoAttempted,
    bool? undone,
  }) => AutomaticAct(
    id: id,
    locationKey: locationKey,
    kind: kind,
    summary: summary,
    occurredAt: occurredAt,
    sessionId: sessionId,
    acknowledged: acknowledged ?? this.acknowledged,
    undoAttempted: undoAttempted ?? this.undoAttempted,
    undone: undone ?? this.undone,
  );
}

/// Inbox data for one profile and location, built without mutating read state.
///
/// The caller scopes both input collections to the active location. Automatic
/// actions remain available when server read state is unknown. Finished work
/// uses the existing exact session/idle acknowledgements, with no row limit.
/// Blocked sessions are excluded: pending requests belong to their own surface.
class WhileAwaySnapshot {
  const WhileAwaySnapshot._({
    required this.automaticActs,
    required this.finishedWork,
    required this.readStateKnown,
    required this.inventoryPartial,
  });

  final List<AutomaticAct> automaticActs;
  final List<ReturnBriefRun> finishedWork;
  final bool readStateKnown;
  final bool inventoryPartial;

  bool get isEmpty => automaticActs.isEmpty && finishedWork.isEmpty;

  factory WhileAwaySnapshot.build({
    required Iterable<AutomaticAct> automaticActs,
    required Iterable<Session> sessions,
    required bool readStateKnown,
    required bool inventoryPartial,
    required bool Function(Session) isUnread,
    required bool Function(String) isBusy,
    required (ReturnBriefBlocker, String)? Function(String) blockerOf,
    ReturnBriefAck? acknowledgement,
  }) {
    final acts = automaticActs.where((act) => !act.acknowledged).toList()
      ..sort((a, b) {
        final byTime = b.occurredAt.compareTo(a.occurredAt);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
    final runs = <ReturnBriefRun>[];
    for (final session in sessions) {
      if (session.parentID != null || session.archived) continue;
      if (blockerOf(session.id) != null) continue;
      final run = ReturnBrief.unreviewedRun(
        session,
        readStateKnown: readStateKnown,
        isUnread: isUnread,
        isBusy: isBusy,
        ack: acknowledgement,
      );
      if (run != null) runs.add(run);
    }
    runs.sort((a, b) {
      final byTime = b.idleAt.compareTo(a.idleAt);
      return byTime != 0 ? byTime : a.session.id.compareTo(b.session.id);
    });
    return WhileAwaySnapshot._(
      automaticActs: List.unmodifiable(acts),
      finishedWork: List.unmodifiable(runs),
      readStateKnown: readStateKnown,
      inventoryPartial: inventoryPartial,
    );
  }
}
