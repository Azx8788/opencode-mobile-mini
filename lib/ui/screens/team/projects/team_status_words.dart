import '../../../../domain/team_project.dart';
import '../../../../l10n/app_localizations.dart';

/// Tasks line of a running project. Every task finished while the project
/// still reads as running (the run has not caught up yet): say it is
/// complete, never "0 working".
String teamProgressWords(AppLocalizations l, TeamProject p) {
  final done = p.tasks
      .where((t) => t.status == 'merged' || t.status == 'done')
      .length;
  final working = p.tasks.where((t) => t.status == 'running').length;
  if (p.tasks.isNotEmpty && done == p.tasks.length && working == 0) {
    return l.teamProjectAllTasksDone(p.tasks.length);
  }
  return l.teamProjectProgress(done, p.tasks.length, working);
}

/// How long the spec has been shaping, in whole minutes, from the last
/// planner checkpoint (or the project's last change).
int teamPlanningMinutes(TeamProject p, DateTime now) {
  final at =
      DateTime.tryParse(p.planningState?.updatedAt ?? '') ??
      DateTime.tryParse(p.updatedAt);
  if (at == null) return 0;
  final minutes = now.difference(at).inMinutes;
  return minutes < 0 ? 0 : minutes;
}

/// Minutes after which shaping the spec is called slow and offers another go.
const teamPlanningSlowMinutes = 2;

/// "Shaping the spec" with live elapsed time, so a slow model never looks hung.
String teamPlanningWords(AppLocalizations l, TeamProject p, DateTime now) {
  final minutes = teamPlanningMinutes(p, now);
  if (minutes < 1) return l.teamProjectPlanning;
  return minutes >= teamPlanningSlowMinutes
      ? l.teamProjectPlanningSlow(minutes)
      : l.teamProjectPlanningElapsed(minutes);
}
