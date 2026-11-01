/// What the AI Team is doing now and what happens next, in the person's
/// words (the owner, build 2054: "I have no idea to know when is next cycle
/// and whats happening?"; docs/qa/team-discover-2026-09-25).
///
/// - [teamRest]: a team whose agents are all asleep (on-demand agents
///   that wake when there is work) is not "Paused"; only agents switched
///   off on purpose (suspended) make a paused team.
/// - [teamCheckInterval]: how often the team looks for work to start, when
///   the app knows it (the team inside the app: its own tuning's patrol
///   interval). Elsewhere the app says what starts a worker instead.
/// - [teamWaitLine]: a task waiting for a worker says for how long and
///   when one starts; past two checks (three minutes when the interval is
///   unknown), or when the host saw the start stall, it says no worker
///   has started.
/// - [teamNowStatus]: the team page's one status for the whole team, with the
///   one action that helps (wake a worker, resume the team, or Why?
///   opening the Technical details).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../builtin/team/builtin_team.dart' show BuiltinTeam;
import '../../domain/orchestration_gateway.dart';
import '../../l10n/app_localizations.dart';
import '../../state/orchestration.dart';
import '../../state/profiles.dart' show OrchestrationConfig;
import '../../state/team_conversation.dart' show teamSessionState;
import '../app_theme.dart';
import '../kit/kit.dart';
import 'team_controls.dart' show teamControlReceiptWord, teamControlWord;
import 'team_technical_details.dart' show showTeamHostDetailsSheet;
import 'team_vocabulary.dart';

/// The patrol interval of the team inside the app, read from the tuning it
/// writes into the team's config, so the two cannot disagree.
final Duration _builtinCheck = () {
  final match = RegExp(
    r'patrol_interval\s*=\s*"(\d+)(s|m)"',
  ).firstMatch(BuiltinTeam.phoneTuning);
  if (match == null) return const Duration(minutes: 1);
  final value = int.parse(match.group(1)!);
  return match.group(2) == 'm'
      ? Duration(minutes: value)
      : Duration(seconds: value);
}();

/// How often the team looks for work to start, or null when the app cannot
/// know (a team on a computer, or in Termux, runs with its own settings).
Duration? teamCheckInterval(OrchestrationController controller) =>
    BuiltinTeam.isBuiltinConfig(controller.config) ? _builtinCheck : null;

/// How a team with no live agent rests.
enum TeamRest {
  /// At least one agent is live, or none is known.
  awake,

  /// Every agent is asleep: they wake when there is work.
  asleep,

  /// Agents were switched off on purpose (suspended): nothing wakes them.
  paused,
}

/// Whether [agent] was switched off on purpose.
bool teamAgentPaused(OrchestrationAgent agent) =>
    agent.suspended ||
    const {
      'suspended',
      'paused',
    }.contains(agent.rawState?.trim().toLowerCase());

/// The agent's kind: the last part of its pool (or name) without an
/// instance number (`witness` for `demo-app/gastown.witness`).
String teamAgentKind(OrchestrationAgent agent) => (agent.pool ?? agent.name)
    .toLowerCase()
    .split('/')
    .last
    .split('.')
    .last
    .replaceFirst(RegExp(r'-\d+$'), '');

/// Whether the app itself keeps [agent] off on its own phone team
/// ([BuiltinTeam.keptOffKinds]): switched off, but never by the person,
/// so it is neither the team's pause nor offered a Wake.
bool teamAgentKeptOff(OrchestrationConfig config, OrchestrationAgent agent) =>
    BuiltinTeam.isBuiltinConfig(config) &&
    !teamAgentIsLive(agent) &&
    BuiltinTeam.keptOffKinds.contains(teamAgentKind(agent));

/// How the team rests. With [config], the agents the app keeps off on its
/// phone team ([teamAgentKeptOff]) are left out: a lean phone team whose
/// worker sleeps is asleep, never "Paused" (ledger row 20).
TeamRest teamRest(
  Iterable<OrchestrationAgent> all, {
  OrchestrationConfig? config,
}) {
  final agents = config == null
      ? all
      : [
          for (final agent in all)
            if (!teamAgentKeptOff(config, agent)) agent,
        ];
  if (agents.isEmpty) return TeamRest.awake;
  if (agents.any(teamAgentIsLive)) return TeamRest.awake;
  // The session is the live truth: an agent the list calls stopped or
  // suspended while its session runs is at work, not paused.
  if (agents.any((agent) => teamSessionState(agent) == AgentState.working)) {
    return TeamRest.awake;
  }
  return agents.any(teamAgentPaused) ? TeamRest.paused : TeamRest.asleep;
}

/// "the team checks every minute", or what starts a worker when the
/// interval is unknown.
String teamCheckPhrase(AppLocalizations l10n, Duration? every) {
  if (every == null) return l10n.teamNowNextCheck;
  if (every <= const Duration(minutes: 1)) return l10n.teamNowChecksEveryMinute;
  return l10n.teamNowChecksEvery('${every.inMinutes}');
}

/// After this long without a worker, a waiting task is stuck: two of the
/// team's checks, or the host's own "no agent started" window (three
/// minutes) when the checks are unknown.
Duration teamStuckAfter(Duration? every) =>
    every == null ? const Duration(minutes: 3) : every * 2;

/// The open task waits for a worker (not for the person, not for the
/// merge).
bool teamRunWaitsForWorker(
  OrchestrationRun run,
  List<WorkItem> work, {
  DispatchCycle? Function(String workId)? cycleOf,
}) =>
    run.state == RunState.waiting &&
    !teamRunAwaitsMerge(run, work, cycleOf: cycleOf);

Iterable<DispatchCycle> _cycles(
  OrchestrationRun run,
  List<WorkItem> work,
  DispatchCycle? Function(String workId)? cycleOf,
) sync* {
  if (cycleOf == null) return;
  for (final item in work) {
    if (item.runId != run.id) continue;
    final cycle = cycleOf(item.id);
    if (cycle != null) yield cycle;
  }
}

/// Since when [run] has waited: the earliest wait its work reports, else
/// when the task started.
DateTime? teamWaitingSince(
  OrchestrationRun run,
  List<WorkItem> work, {
  DispatchCycle? Function(String workId)? cycleOf,
}) {
  DateTime? since;
  for (final cycle in _cycles(run, work, cycleOf)) {
    final at = cycle.since;
    if (at != null && (since == null || at.isBefore(since))) since = at;
  }
  return since ?? run.startedAt ?? run.updatedAt;
}

/// How long [run] has waited, or null when unknown.
Duration? teamWaitingFor(
  OrchestrationRun run,
  List<WorkItem> work, {
  required DateTime now,
  DispatchCycle? Function(String workId)? cycleOf,
}) {
  final since = teamWaitingSince(run, work, cycleOf: cycleOf);
  if (since == null) return null;
  final age = now.difference(since);
  return age.isNegative ? Duration.zero : age;
}

/// The waiting task has waited longer than the team's checks allow, the
/// host saw no agent start, or the team is paused.
bool teamRunStuck(
  OrchestrationRun run,
  List<WorkItem> work, {
  required DateTime now,
  Duration? every,
  bool paused = false,
  DispatchCycle? Function(String workId)? cycleOf,
}) {
  if (!teamRunWaitsForWorker(run, work, cycleOf: cycleOf)) return false;
  if (paused) return true;
  for (final cycle in _cycles(run, work, cycleOf)) {
    if (cycle.stallReason == DispatchStall.hostNotStarted ||
        cycle.stallReason == DispatchStall.agentCannotStart) {
      return true;
    }
  }
  final age = teamWaitingFor(run, work, now: now, cycleOf: cycleOf);
  return age != null && age >= teamStuckAfter(every);
}

/// The waiting task's line: "Waiting for a worker · 1 min · the team
/// checks every minute", or "Waiting for a worker · 6 min · no worker has
/// started" once it is stuck. Null when [run] does not wait for a worker.
String? teamWaitLine(
  AppLocalizations l10n,
  OrchestrationRun run,
  List<WorkItem> work, {
  required DateTime now,
  Duration? every,
  bool paused = false,
  bool showAge = true,
  DispatchCycle? Function(String workId)? cycleOf,
}) {
  if (!teamRunWaitsForWorker(run, work, cycleOf: cycleOf)) return null;
  final age = teamWaitingFor(run, work, now: now, cycleOf: cycleOf);
  final stuck = teamRunStuck(
    run,
    work,
    now: now,
    every: every,
    paused: paused,
    cycleOf: cycleOf,
  );
  return [
    l10n.teamUiCardRunStateWaiting,
    if (showAge && age != null && age >= const Duration(minutes: 1))
      teamElapsedLabel(l10n, age),
    stuck ? l10n.teamNowNoWorkerStarted : teamCheckPhrase(l10n, every),
  ].join(teamUsageSeparator);
}

/// The agent's own short name: `furiosa` for `demo-app/gastown.furiosa`.
String teamAgentShortName(OrchestrationAgent agent) {
  final tail = agent.name.split('/').last.split('.').last.trim();
  return tail.isEmpty ? agent.name : tail;
}

/// "Worker · furiosa": the role in plain words and the short name. The
/// engine's full name, pool and pack stay under Technical details.
String teamAgentTitle(AppLocalizations l10n, OrchestrationAgent agent) {
  final role = teamAgentRoleWord(l10n, teamAgentRole(agent));
  final name = teamAgentShortName(agent);
  return name.toLowerCase() == role.toLowerCase()
      ? role
      : l10n.teamAgentTitle(role, name);
}

/// A worker that is not running and could take the waiting work: the
/// agent to wake, or null.
OrchestrationAgent? teamSleepingWorker(Iterable<OrchestrationAgent> agents) {
  OrchestrationAgent? found;
  for (final agent in agents) {
    if (teamAgentIsLive(agent)) continue;
    if (teamAgentRole(agent) != TeamAgentRole.worker) continue;
    // One asleep beats one paused on purpose.
    if (found == null || (teamAgentPaused(found) && !teamAgentPaused(agent))) {
      found = agent;
    }
  }
  return found;
}

/// Wakes [agents] (resume). Waking is harmless, so it neither asks nor
/// offers Undo (DATA-11): the Now line itself changes once an agent is up.
/// Only a refusal is said, with the host's own words, in the kit's
/// technical-details sheet (no snackbar: KIT-34 keeps those for Undo).
/// Returns the host's last answer, or null when there was nothing to wake.
Future<MutationRecord?> teamWake(
  BuildContext context,
  OrchestrationController controller,
  Iterable<OrchestrationAgent> agents,
) async {
  final l10n = lookupAppLocalizations(Localizations.localeOf(context));
  final records = [
    for (final agent in agents)
      await controller.controlAgent(agent.id, AgentControlAction.resume),
  ];
  if (records.isEmpty) return null;
  final record = records.last;
  final reason = record.receipt?.message?.trim();
  if (record.status == MutationStatus.rejected && context.mounted) {
    await showKitTechnicalDetails(
      context,
      sheetKey: const ValueKey('team-now-wake-refused'),
      title: l10n.teamUiControlReceiptLine(
        teamControlWord(l10n, record.request),
        teamControlReceiptWord(l10n, record.status),
      ),
      text: reason == null || reason.isEmpty
          ? l10n.teamNowWakeRefusedNoReason
          : reason,
    );
  }
  return record;
}

/// The one action for a team that cannot go on by itself: wake what is
/// asleep when the host takes controls, else Why? (the Technical details).
KitAction teamUnstickAction(
  BuildContext context,
  OrchestrationController controller, {
  required String keyPrefix,
  required List<OrchestrationAgent> wake,
  required String wakeLabel,
}) {
  final l10n = lookupAppLocalizations(Localizations.localeOf(context));
  if (controller.capabilities.controlAgent && wake.isNotEmpty) {
    return KitAction(
      key: ValueKey('$keyPrefix-wake'),
      label: wakeLabel,
      onPressed: () => unawaited(teamWake(context, controller, wake)),
    );
  }
  return KitAction(
    key: ValueKey('$keyPrefix-why'),
    label: l10n.teamNowWhy,
    onPressed: () => showTeamHostDetailsSheet(context, controller),
  );
}

/// The team page's one line for the whole team (slice-P5.1): one sentence
/// on what the team as a whole is doing that the task rows below cannot
/// say — it is paused, or it is not starting a worker for a waiting task —
/// with the one action that helps. Never a task's title or its wait: the
/// task's own row says those (nothing shown twice). Null otherwise.
///
/// A [KitStatus] of kind `work` for the page's status slot
/// (`KitScreen.status`), so a connection line and this one never show at
/// once: the slot draws the more urgent (P4.4 hand-off, P6.3). Keys:
/// `<prefix>-paused`, `<prefix>-stuck`, and the action's.
KitStatus? teamNowStatus(
  BuildContext context, {
  required OrchestrationController controller,
  required DateTime now,
  String keyPrefix = 'team-now',
}) {
  final l10n = lookupAppLocalizations(Localizations.localeOf(context));
  final snapshot = controller.snapshot;
  final agents = snapshot.agents;
  final rest = teamRest(agents, config: controller.config);
  final every = teamCheckInterval(controller);
  final cycleOf = controller.cycleFor;
  final open = [
    for (final run in teamVisibleRuns(snapshot.runs))
      if (run.state != RunState.completed &&
          run.state != RunState.cancelled &&
          run.state != RunState.failed)
        run,
  ];
  if (rest == TeamRest.paused && open.isNotEmpty) {
    return KitStatus(
      kind: KitStatusKind.work,
      id: '$keyPrefix:paused',
      key: ValueKey('$keyPrefix-paused'),
      icon: AppIconography.pause,
      tone: AppStatusTone.neutral,
      message: l10n.teamNowPausedLine,
      action: teamUnstickAction(
        context,
        controller,
        keyPrefix: keyPrefix,
        wake: [
          for (final agent in agents)
            if (teamAgentPaused(agent) &&
                !teamAgentKeptOff(controller.config, agent))
              agent,
        ],
        wakeLabel: l10n.teamUiControlResume,
      ),
    );
  }
  final stuck = open.any(
    (run) => teamRunStuck(
      run,
      snapshot.work,
      now: now,
      every: every,
      cycleOf: cycleOf,
    ),
  );
  if (stuck) {
    final worker = teamSleepingWorker(agents);
    return KitStatus(
      kind: KitStatusKind.work,
      id: '$keyPrefix:stuck',
      key: ValueKey('$keyPrefix-stuck'),
      icon: AppIconography.warning,
      tone: AppStatusTone.neutral,
      message: l10n.teamNowNotStartingLine,
      action: teamUnstickAction(
        context,
        controller,
        keyPrefix: keyPrefix,
        wake: [?worker],
        wakeLabel: l10n.teamNowStartWorker,
      ),
    );
  }
  return null;
}
