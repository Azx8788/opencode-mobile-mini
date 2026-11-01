import 'package:flutter/widgets.dart';

import '../../../state/orchestration.dart';
import '../../kit/kit.dart';
import 'projects/team_projects_screen.dart';

/// Stable request/task identifiers route back to the same project workspace.
Widget teamProjectDestination(
  OrchestrationController team, {
  String? requestId,
  String? taskId,
}) {
  final controller = team.projectController!;
  String? projectId;
  for (final project in controller.snapshot?.projects ?? []) {
    if ((requestId != null && project.requests.any((r) => r.id == requestId)) ||
        (taskId != null && project.tasks.any((t) => t.id == taskId))) {
      projectId = project.id;
      break;
    }
  }
  return TeamProjectsScreen(
    controller: controller,
    initialProjectId: projectId,
    initialTaskId: taskId,
  );
}

Future<void> openTeamProjectDestination(
  BuildContext context,
  OrchestrationController team, {
  String? requestId,
  String? taskId,
}) => pushKitPage<void>(
  context,
  (_) => teamProjectDestination(team, requestId: requestId, taskId: taskId),
);
