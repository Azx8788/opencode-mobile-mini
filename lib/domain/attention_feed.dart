import 'dart:convert';

import 'work_row_status.dart';

/// Reasons to visit work, rather than an activity history or a busy reminder.
enum AttentionKind { permission, question, form, failedRun, teamGate }

/// One observation from an existing transport. Routing identifiers are opaque:
/// do not redact or display them. Titles are redacted at the feed boundary.
/// This model carries no request body, answer, exception or credential payload.
class AttentionObservation {
  const AttentionObservation({
    required this.id,
    required this.kind,
    required this.facts,
    required this.observedAt,
    this.sessionID,
    this.requestID,
    this.taskID,
    this.runID,
    this.title,
    this.directory,
    this.workspace,
    this.isFresh = true,
  });

  final String id;
  final AttentionKind kind;
  final WorkRowFacts facts;
  final DateTime observedAt;

  /// False for retained evidence after its source failed or was not sampled.
  final bool isFresh;
  final String? sessionID,
      requestID,
      taskID,
      runID,
      title,
      directory,
      workspace;

  AttentionObservation copyWith({bool? isFresh}) => AttentionObservation(
    id: id,
    kind: kind,
    facts: facts,
    observedAt: observedAt,
    sessionID: sessionID,
    requestID: requestID,
    taskID: taskID,
    runID: runID,
    title: title,
    directory: directory,
    workspace: workspace,
    isFresh: isFresh ?? this.isFresh,
  );

  /// Structured encoding avoids collisions when opaque ids contain separators.
  /// The profile is deliberately added only by the all-server projection.
  String get identity =>
      jsonEncode([kind.name, sessionID, requestID ?? id, directory, workspace]);
}

/// Resolve the profile/location first, then open the conversation and focus
/// its request card. A team gate without a worker session opens its task;
/// a missing session must never be replaced with a guessed conversation.
class AttentionTarget {
  const AttentionTarget({
    required this.profileID,
    required this.kind,
    this.sessionID,
    this.requestID,
    this.taskID,
    this.runID,
    this.directory,
    this.workspace,
  });

  final String profileID;
  final AttentionKind kind;
  final String? sessionID, requestID, taskID, runID, directory, workspace;
  bool get hasConversation => sessionID != null && sessionID!.isNotEmpty;
}

/// Rendering uses the same status words and stale-row behavior as Work rows.
/// Names/titles are display-safe; [target] is navigation metadata, not copy.
class AttentionFeedItem {
  const AttentionFeedItem({
    required this.identity,
    required this.profileID,
    required this.serverName,
    required this.kind,
    required this.target,
    required this.status,
    this.title,
  });

  final String identity, profileID, serverName;
  final String? title;
  final AttentionKind kind;
  final AttentionTarget target;
  final WorkRowStatus status;
}

/// Coverage belongs to a server independently of its last observed rows.
/// Unavailable/partial/stale never means an empty server has no pending work.
enum AttentionCheckState {
  disabled,
  waiting,
  checking,
  current,
  partial,
  unavailable,
  wifiRequired,
  paused,
  stale,
}

class AttentionServerCheck {
  const AttentionServerCheck({
    required this.profileID,
    required this.serverName,
    required this.state,
    required this.isFresh,
    required this.coverageComplete,
    this.checkedAt,
    this.nextCheckAt,
  });

  final String profileID, serverName;
  final AttentionCheckState state;
  final DateTime? checkedAt, nextCheckAt;
  final bool isFresh, coverageComplete;
  bool get isCurrent => state == AttentionCheckState.current;
}
