import 'team_project.dart';
export 'team_project.dart';

enum TeamProjectAction {
  simulatePlanFailure,
  usePlanAsTask,
  retryPlan,
  simulateManualCommit,
  simulateConflict,
  requestSpecChange,
  updateDefaults,
  createProject,
  createQuickTask,
  saveSpecDraft,
  approveSpec,
  approvePlan,
  replan,
  answerRequest,
  messageTask,
  pauseProject,
  resumeProject,
  stopProject,
  pauseTask,
  resumeTask,
  restartTask,
  stopTask,
  moveTask,
  verifyTask,
  fixFindings,
  recheckTask,
  ignoreFinding,
  updateSettings,
  processMergeQueue,
  resolveConflict,
  promote,
  acknowledgeDigest,
  acceptPhase,
  acceptMilestone,
  saveRole,
  deleteRole,
  updateServer,
  deleteProject,
  advance,
  undoMerge,
}

/// Commands carry a unique request ID and the revision the person reviewed.
/// `spec`, `settings`, `tasks` and `phases` are full typed edited values.
class TeamProjectCommand {
  const TeamProjectCommand({
    required this.requestId,
    required this.action,
    this.projectId = '',
    this.expectedRevision,
    this.targetId = '',
    this.text = '',
    this.name = '',
    this.serverId = '',
    this.roleId = '',
    this.expectedDevCommit = '',
    this.expectedMainCommit = '',
    this.confirmed = false,
    this.settings,
    this.spec,
    this.repos = const [],
    this.tasks,
    this.phases,
    this.findingIds = const [],
    this.role,
    this.server,
  });
  final String requestId, projectId, targetId, text, name, serverId, roleId;
  final String expectedDevCommit, expectedMainCommit;
  final TeamProjectAction action;
  final int? expectedRevision;
  final bool confirmed;
  final TeamProjectSettings? settings;
  final TeamSpec? spec;
  final List<TeamRepo> repos;
  final List<TeamTask>? tasks;
  final List<TeamPhase>? phases;
  final List<String> findingIds;
  final TeamProjectRole? role;
  final TeamServer? server;
  Map<String, Object?> toJson() => {
    'findingIds': findingIds,
    'requestId': requestId,
    'action': action.name,
    'projectId': projectId,
    'expectedRevision': expectedRevision,
    'targetId': targetId,
    'text': text,
    'name': name,
    'serverId': serverId,
    'roleId': roleId,
    'expectedDevCommit': expectedDevCommit,
    'expectedMainCommit': expectedMainCommit,
    'confirmed': confirmed,
    'settings': settings?.toJson(),
    'spec': spec?.toJson(),
    'repos': repos.map((v) => v.toJson()).toList(),
    'tasks': tasks?.map((v) => v.toJson()).toList(),
    'phases': phases?.map((v) => v.toJson()).toList(),
    'role': role?.toJson(),
    'server': server?.toJson(),
  };
}

class TeamCommandResult {
  const TeamCommandResult({
    required this.accepted,
    this.code = '',
    this.projectId = '',
    this.revision = 0,
    this.replayed = false,
  });
  final bool accepted, replayed;
  final String code, projectId;
  final int revision;
}

/// Optional extension, independent of older task-only orchestration adapters.
abstract interface class OrchestrationProjectGateway {
  Future<TeamWorkspace> teamWorkspace();
  Stream<TeamWorkspace> watchTeamWorkspace();
  Future<TeamCommandResult> executeProject(TeamProjectCommand command);
  Future<void> close();

  /// Drains writes and permanently disables this instance before deleting data.
  Future<void> deleteLocalData();
}

abstract interface class TeamProjectPersistence {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}
