/// Words and lookups for AI Team roles (personas) shared by the Agents
/// page, the role page, the start-task sheet and the team conversation.
///
/// A built-in role stores an empty name and purpose until the person edits
/// them, so the shown text comes from l10n by role id; the person's own
/// roles show what they typed.
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/orchestration_gateway.dart';
import '../../l10n/app_localizations.dart';
import '../../state/orchestration.dart';
import '../../state/team_roles.dart';

/// The name to show for [role].
String teamRoleName(AppLocalizations l10n, TeamRole role) {
  final name = role.name.trim();
  if (name.isNotEmpty) return name;
  return switch (role.id) {
    TeamRoleIds.general => l10n.teamRoleNameGeneral,
    TeamRoleIds.product => l10n.teamRoleNameProduct,
    TeamRoleIds.frontend => l10n.teamRoleNameFrontend,
    TeamRoleIds.backend => l10n.teamRoleNameBackend,
    TeamRoleIds.tester => l10n.teamRoleNameTester,
    _ => l10n.teamUiAgentRoleWorker,
  };
}

/// The one-line purpose to show for [role].
String teamRolePurpose(AppLocalizations l10n, TeamRole role) {
  final purpose = role.purpose.trim();
  if (purpose.isNotEmpty) return purpose;
  return switch (role.id) {
    TeamRoleIds.general => l10n.teamRolePurposeGeneral,
    TeamRoleIds.product => l10n.teamRolePurposeProduct,
    TeamRoleIds.frontend => l10n.teamRolePurposeFrontend,
    TeamRoleIds.backend => l10n.teamRolePurposeBackend,
    TeamRoleIds.tester => l10n.teamRolePurposeTester,
    _ => '',
  };
}

/// The team's roles for [profileId], one controller per profile.
Future<TeamRolesController> loadTeamRoles(String profileId) async =>
    teamRolesFor(await SharedPreferences.getInstance(), profileId);

/// The role name a task shows for its worker ("Frontend"), or null when
/// the task's role is unknown (tasks from before roles).
String? teamRoleNameOfRun(
  AppLocalizations l10n,
  TeamRolesController? roles,
  OrchestrationController team,
  OrchestrationRun run,
) {
  if (roles == null) return null;
  final id = roles.roleOfRun(run, team);
  final role = id == null ? null : roles.byId(id);
  return role == null ? null : teamRoleName(l10n, role);
}

/// The role a live worker is wearing: the role of its current task, or
/// null when it has none or the task's role is unknown.
String? teamRoleIdOfWorker(
  TeamRolesController roles,
  OrchestrationController team,
  OrchestrationAgent agent,
) {
  final workId = agent.currentWorkId;
  if (workId == null) return null;
  final direct = roles.roleOfTask(workId);
  if (direct != null) return direct;
  for (final item in team.snapshot.work) {
    if (item.id == workId && item.runId != null) {
      return roles.roleOfTask(item.runId!);
    }
  }
  return null;
}

/// The runs given to [roleId], newest first (upkeep never counts).
List<OrchestrationRun> teamRunsOfRole(
  TeamRolesController roles,
  OrchestrationController team,
  String roleId,
) {
  final runs = [
    for (final run in team.snapshot.runs)
      if (!run.isUpkeep && roles.roleOfRun(run, team) == roleId) run,
  ];
  DateTime stamp(OrchestrationRun run) =>
      run.updatedAt ??
      run.startedAt ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  runs.sort((a, b) => stamp(b).compareTo(stamp(a)));
  return runs;
}
