/// The AI Team as a conversation (docs/design/team-conversation-2026-09-26.md):
/// the doors into it. The page itself is part of the chat library
/// ([TeamConversationScreen]) so it draws with the chat's own parts.
///
/// Frozen for callers (New conversation's "Solo · Team", the Work tab):
/// - [TeamConversation.open]: an existing task's conversation;
/// - [TeamConversation.openPlanning]: a task the planner has not listed
///   yet, from the team page's row for it;
/// - [TeamConversation.start]: give the team a new task (the existing
///   Start-a-task sheet), then open its conversation, which binds to the
///   task's run as soon as the team lists it.
library;

import 'package:flutter/material.dart';

import '../../../state/orchestration.dart';
import '../../../state/team_planning.dart' show TeamPlanningRequest;
import '../../kit/kit.dart';
import '../../navigation/chat_route.dart' show chatRequestArrivalId;
import '../chat_screen.dart';
import '../team/start_run_sheet.dart' show showStartRunSheet;

export '../chat_screen.dart'
    show
        TeamAgentConversationLookup,
        TeamAgentConversationMiss,
        TeamAgentTranscript,
        TeamConversationScreen,
        TeamControllerScope,
        TeamOpenConversationRow,
        TeamPendingTask,
        TeamWatchLiveScreen,
        lookupTeamAgentConversation,
        openTeamAgentConversation,
        openTeamAgentConversationById,
        teamAgentConversationMissNote,
        teamAgentWatch;

abstract final class TeamConversation {
  /// Opens the conversation of the task [runId].
  static Future<void> open(
    BuildContext context,
    OrchestrationController team, {
    required String runId,
  }) => Navigator.of(context).push(route(team, runId: runId));

  /// The route [open] pushes, for a door that holds a [NavigatorState]
  /// rather than a context (the team notification). With [landOnGateId]
  /// (an Inbox row or a notification for one gate, P4.2a) the page lands on
  /// that gate's card and marks it once.
  static Route<void> route(
    OrchestrationController team, {
    required String runId,
    String? landOnGateId,
  }) {
    final Widget page = TeamControllerScope(
      team: team,
      child: TeamConversationScreen(team: team, runId: runId),
    );
    // Built once for the page, so a rebuild never lands a second time.
    final landing = landOnGateId == null
        ? page
        : KitArrivalScope(
            rowId: chatRequestArrivalId(landOnGateId),
            child: page,
          );
    return KitPageRoute<void>(builder: (_) => landing);
  }

  /// Opens the conversation of a task the planner has not listed yet
  /// ([request], a Start-a-task message): its Now line says where it
  /// stands, and it binds to the task once the team lists it. The team
  /// page's row for a task being planned opens this.
  static Future<void> openPlanning(
    BuildContext context,
    OrchestrationController team,
    TeamPlanningRequest request, {
    DateTime Function()? now,
  }) => Navigator.of(context).push(
    KitPageRoute<void>(
      builder: (_) => TeamControllerScope(
        team: team,
        child: TeamConversationScreen(
          team: team,
          now: now,
          pending: TeamPendingTask(
            title: request.objective,
            sentAt: request.sentAt,
            record: request.record,
          ),
        ),
      ),
    ),
  );

  /// Asks for a new task (the team's Start-a-task sheet: the planner, or a
  /// direct task when the planner is off), then opens its conversation.
  /// Nothing opens when the person backs out or the host refused the task;
  /// the sheet's record comes back so a caller can say a refusal the sheet
  /// did not (a work item made but refused by its worker pool).
  ///
  /// [offerBacklog] (the board) adds Keep in backlog to the sheet: the
  /// task is made and waits, given to no one, so no conversation opens and
  /// [onKeptInBacklog] hears of it. [projectId] is the project chosen at
  /// first. [roleId] is the role the task is given to at first (its page's
  /// Give a task).
  static Future<MutationRecord?> start(
    BuildContext context,
    OrchestrationController team, {
    bool offerBacklog = false,
    String? projectId,
    String? roleId,
    ValueChanged<MutationRecord>? onKeptInBacklog,
  }) async {
    final result = await showStartRunSheet(
      context,
      team,
      offerBacklog: offerBacklog,
      projectId: projectId,
      roleId: roleId,
    );
    final record = result?.record;
    if (result != null && result.backlog) {
      onKeptInBacklog?.call(result.record);
      return record;
    }
    if (record == null ||
        record.status == MutationStatus.rejected ||
        !context.mounted) {
      return record;
    }
    final TeamPendingTask pending;
    switch (record.kind) {
      // Whether the task was made is unknown (no ID): there is no task to
      // open yet. The team page's Now line says so (P6.3).
      case MutationKind.createWork when record.receipt?.createdId == null:
        return record;
      case MutationKind.createWork:
        pending = TeamPendingTask(
          title: record.request.targetId,
          details: record.request.text,
          sentAt: record.createdAt,
          workId: record.receipt?.createdId,
        );
      case MutationKind.message:
        final parsed = TeamPlanningRequest.parse(record);
        pending = TeamPendingTask(
          title: parsed?.objective ?? record.request.text ?? '',
          sentAt: record.createdAt,
          record: record,
        );
      default:
        return record;
    }
    await Navigator.of(context).push(
      KitPageRoute<void>(
        builder: (_) => TeamControllerScope(
          team: team,
          child: TeamConversationScreen(team: team, pending: pending),
        ),
      ),
    );
    return record;
  }
}
