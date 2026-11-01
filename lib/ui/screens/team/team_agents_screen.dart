/// The AI Team's Agents page: the team's **roles** (Product, Frontend,
/// Backend, Tester, General and the person's own), one list ordered by
/// urgency: a role working now first ("Working on “Sync engine” · 4 min"),
/// then the rest ("Uses Claude Sonnet · 3 tasks"). Live Gas City workers
/// (generated names like "furiosa") are not rows of their own: a live
/// worker shows as the role its current task was given to, or as "Worker"
/// when that is unknown, and its generated name waits under Details on the
/// role page. Nothing is shown twice.
///
/// A row opens the role page ([RoleScreen]); the pinned "New role" opens
/// it in create mode. The standing helpers below ([teamAgentStanding],
/// [teamAgentTitles], ...) stay for the pages that still name an agent.
///
/// Kit only (KIT-1): [KitScreen] with [KitTopBar], the shared status line
/// of `team_states.dart`, rows on one [KitRowGroup], pull to refresh
/// through [KitRefresh], and a pinned [KitActionBlock].
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../builtin/team/builtin_team.dart' show BuiltinTeam;
import '../../../domain/orchestration_gateway.dart';
import '../../../domain/server_gateway.dart' show CatalogModel;
import '../../../l10n/app_localizations.dart';
import '../../../state/connection.dart';
import '../../../state/orchestration.dart';
import '../../../state/profiles.dart' show OrchestrationConfig;
import '../../../state/team_conversation.dart' show teamSessionState;
import '../../../state/team_model.dart' show teamModelSpec;
import '../../../state/team_roles.dart';
import '../../app_iconography.dart';
import '../../kit/kit.dart';
import '../../widgets/team_now.dart'
    show teamAgentKeptOff, teamAgentKind, teamAgentPaused;
import '../../widgets/team_role_copy.dart';
import '../../widgets/team_vocabulary.dart';
import '../team_conversation/team_conversation.dart'
    show openTeamAgentConversation;
import 'role_screen.dart';
import 'team_states.dart';

AppLocalizations _copy(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

/// Where an agent stands on this list, most urgent first.
enum TeamAgentStanding {
  /// Waiting for the person, or blocked.
  needsYou,
  crashed,
  working,
  idle,
  unknown,

  /// Stopped on the host; it wakes when there is work.
  asleep,

  /// Switched off on purpose (suspended): nothing wakes it until someone
  /// does.
  paused,

  /// Kept off by the app on its own phone team, to save the phone
  /// ([teamAgentKeptOff]): not the person's pause, never woken from here.
  keptOff,
}

/// [agent]'s place on the list, from its session first
/// ([teamSessionState], ledger row 21): an agent the list calls working
/// whose session the host reports stopped is asleep, never "Working"; one
/// the list calls stopped whose session runs is at work.
TeamAgentStanding teamAgentStanding(
  OrchestrationAgent agent, {
  OrchestrationConfig? config,
}) {
  if (config != null && teamAgentKeptOff(config, agent)) {
    return TeamAgentStanding.keptOff;
  }
  if (!teamAgentIsLive(agent)) {
    return teamAgentPaused(agent)
        ? TeamAgentStanding.paused
        : TeamAgentStanding.asleep;
  }
  return switch (teamSessionState(agent)) {
    AgentState.waiting || AgentState.blocked => TeamAgentStanding.needsYou,
    AgentState.crashed => TeamAgentStanding.crashed,
    AgentState.working => TeamAgentStanding.working,
    AgentState.idle => TeamAgentStanding.idle,
    AgentState.stopped => TeamAgentStanding.asleep,
    AgentState.unknown => TeamAgentStanding.unknown,
  };
}

/// Urgency first (needs you, crashed, working, idle, asleep, paused), then
/// the newest activity, then the name so the order is stable.
int teamCompareAgentsByUrgency(
  OrchestrationAgent a,
  OrchestrationAgent b, {
  OrchestrationConfig? config,
}) {
  final rank = teamAgentStanding(
    a,
    config: config,
  ).index.compareTo(teamAgentStanding(b, config: config).index);
  if (rank != 0) return rank;
  final at = a.lastActivity, bt = b.lastActivity;
  if (at != null && bt != null && at != bt) return bt.compareTo(at);
  if (at != null && bt == null) return -1;
  if (at == null && bt != null) return 1;
  return a.name.compareTo(b.name);
}

/// The agent's own name when the host gives it one besides its role:
/// "furiosa" for `ocproof/gastown.furiosa` in the `gastown.polecat` pool.
/// Null when the name only repeats the role (`gastown.mayor`) or there is
/// no pool to tell them apart.
String? teamAgentNickname(OrchestrationAgent agent) {
  final pool = agent.pool;
  if (pool == null || pool.trim().isEmpty) return null;
  String tail(String value) => value.split('/').last.split('.').last.trim();
  final name = tail(agent.name);
  final role = tail(pool).replaceFirst(RegExp(r'-\d+$'), '').toLowerCase();
  if (name.isEmpty || name.toLowerCase().startsWith(role)) return null;
  return name;
}

/// "furiosa · Worker", or the role alone.
String teamAgentTitle(AppLocalizations l10n, OrchestrationAgent agent) {
  final role = teamAgentRoleWord(l10n, teamAgentRole(agent));
  final nickname = teamAgentNickname(agent);
  return nickname == null ? role : '$nickname$teamUsageSeparator$role';
}

/// The title of each of [agents] by id, none twice (owner, build 2055:
/// three rows all called "Supervisor"). [teamAgentTitle] first; a title
/// shared by several agents takes, where it tells them apart, the agent's
/// project ("Supervisor · demo-app"), then what it looks after
/// ("Supervisor · whole team", "Supervisor · watchdog"), and any title
/// still shared ends with the agent's number in the list ("Worker 2").
Map<String, String> teamAgentTitles(
  AppLocalizations l10n,
  List<OrchestrationAgent> agents,
) {
  final titles = {
    for (final agent in agents) agent.id: teamAgentTitle(l10n, agent),
  };
  List<List<OrchestrationAgent>> shared() {
    final groups = <String, List<OrchestrationAgent>>{};
    for (final agent in agents) {
      groups.putIfAbsent(titles[agent.id]!, () => []).add(agent);
    }
    return [
      for (final group in groups.values)
        if (group.length > 1) group,
    ];
  }

  void qualify(String? Function(OrchestrationAgent) by) {
    for (final group in shared()) {
      for (final agent in group) {
        final word = by(agent);
        if (word == null || word.isEmpty) continue;
        titles[agent.id] = '${titles[agent.id]}$teamUsageSeparator$word';
      }
    }
  }

  qualify((agent) {
    final name = agent.name;
    final slash = name.lastIndexOf('/');
    return slash <= 0 ? null : name.substring(0, slash);
  });
  qualify(
    (agent) => switch (teamAgentKind(agent)) {
      'deacon' => l10n.teamAgentLooksAfterTeam,
      'boot' => l10n.teamAgentLooksAfterWatchdog,
      'witness' => l10n.teamAgentLooksAfterWorkers,
      _ => null,
    },
  );
  for (final group in shared()) {
    for (final (index, agent) in group.indexed) {
      titles[agent.id] = '${titles[agent.id]} ${index + 1}';
    }
  }
  return titles;
}

/// The name a role's model is shown by: the catalog's name where the phone
/// lists it, else the saved `provider/model`.
String teamRoleModelName(ConnectionController? connection, String spec) {
  for (final model in connection?.catalog?.models ?? const <CatalogModel>[]) {
    if (teamModelSpec(model.providerID, model.id) == spec) return model.name;
  }
  return spec;
}

/// Opens a role's page over the current one; [roleId] null is a new role.
Future<void> openTeamRole(
  BuildContext context, {
  required OrchestrationController controller,
  required TeamRolesController roles,
  String? roleId,
  ConnectionController? connection,
  ValueChanged<OrchestrationAgent>? onOpenAgent,
  DateTime Function()? now,
}) => Navigator.of(context).push(
  KitPageRoute<void>(
    builder: (_) => RoleScreen(
      controller: controller,
      roles: roles,
      roleId: roleId,
      connection: connection,
      onOpenAgent: onOpenAgent,
      now: now,
    ),
  ),
);

class TeamAgentsScreen extends StatefulWidget {
  const TeamAgentsScreen({
    super.key,
    required this.controller,
    this.roles,
    this.connection,
    this.onOpenAgent,
    this.now,
  });

  final OrchestrationController controller;

  /// The team's roles; loaded for the team's profile when null.
  final TeamRolesController? roles;

  /// The connection whose catalog names the models; optional.
  final ConnectionController? connection;

  /// Opens a live worker; its conversation ([openTeamAgentConversation])
  /// when null.
  final ValueChanged<OrchestrationAgent>? onOpenAgent;

  /// Clock for relative ages; tests pin it.
  final DateTime Function()? now;

  @override
  State<TeamAgentsScreen> createState() => _TeamAgentsScreenState();
}

/// One line of the list: a role, or a live worker whose role is unknown.
class _Entry {
  const _Entry({this.role, this.worker, this.task, this.since});

  final TeamRole? role;

  /// The live worker working now (the role's, or the unknown one).
  final OrchestrationAgent? worker;
  final String? task;
  final DateTime? since;

  bool get working => worker != null;
}

class _TeamAgentsScreenState extends State<TeamAgentsScreen> {
  bool _refreshing = false;
  TeamRolesController? _roles;

  @override
  void initState() {
    super.initState();
    _roles = widget.roles;
    if (_roles == null) unawaited(_loadRoles());
  }

  Future<void> _loadRoles() async {
    try {
      final roles = await loadTeamRoles(widget.controller.profileId);
      if (mounted) setState(() => _roles = roles);
    } catch (_) {
      // No roles yet: the page keeps its loading bar.
    }
  }

  DateTime get _now => (widget.now ?? DateTime.now)();

  bool get _remote => !BuiltinTeam.isBuiltinConfig(widget.controller.config);

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final controller = widget.controller;
      if (controller.phase == OrchestrationPhase.failed) {
        await controller.retry();
      } else {
        await controller.refresh();
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _openWorker(OrchestrationAgent agent) {
    final open = widget.onOpenAgent;
    if (open != null) return open(agent);
    unawaited(
      openTeamAgentConversation(context, agent, team: widget.controller),
    );
  }

  void _openRole(String? id) {
    final roles = _roles;
    if (roles == null) return;
    unawaited(
      openTeamRole(
        context,
        controller: widget.controller,
        roles: roles,
        roleId: id,
        connection: widget.connection,
        onOpenAgent: widget.onOpenAgent,
        now: widget.now,
      ),
    );
  }

  /// The list, most urgent first: a role with a live worker on a task now
  /// (a worker whose role is unknown is "Worker"), then every other role in
  /// the team's order.
  List<_Entry> _entries(TeamRolesController roles) {
    final controller = widget.controller;
    final snapshot = controller.snapshot;
    final workById = {for (final item in snapshot.work) item.id: item};
    final runById = {for (final run in snapshot.runs) run.id: run};
    final working = <String, _Entry>{};
    final unknown = <_Entry>[];
    final agents = [...snapshot.agents]
      ..sort((a, b) {
        final at = a.lastActivity, bt = b.lastActivity;
        if (at == null || bt == null) {
          return at == null ? (bt == null ? 0 : 1) : -1;
        }
        return bt.compareTo(at);
      });
    for (final agent in agents) {
      if (!teamAgentIsLive(agent) ||
          teamSessionState(agent) != AgentState.working ||
          agent.currentWorkId == null) {
        continue;
      }
      final item = workById[agent.currentWorkId];
      final run = item?.runId == null ? null : runById[item!.runId];
      final task = (run?.title ?? item?.title)?.trim();
      final since = agent.sessionStartedAt ?? agent.lastActivity;
      final id = teamRoleIdOfWorker(roles, controller, agent);
      final role = id == null ? null : roles.byId(id);
      if (role == null) {
        unknown.add(_Entry(worker: agent, task: task, since: since));
      } else {
        working.putIfAbsent(
          role.id,
          () => _Entry(role: role, worker: agent, task: task, since: since),
        );
      }
    }
    return [
      ...unknown,
      for (final role in roles.roles) ?working[role.id],
      for (final role in roles.roles)
        if (!working.containsKey(role.id)) _Entry(role: role),
    ];
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.controller,
      ?_roles,
      ?widget.connection,
    ]),
    builder: (context, _) {
      final controller = widget.controller;
      // Rebuilds once the check is 8 s old and then every minute, so the
      // "checked …" words keep up without a timer of our own.
      return KitSince(
        since: controller.lastRefreshedAt,
        ticks: KitSinceTicks.minutes,
        builder: (context, _) => _screen(context),
      );
    },
  );

  Widget _screen(BuildContext context) {
    final l10n = _copy(context);
    final controller = widget.controller;
    final ready =
        controller.phase == OrchestrationPhase.ready &&
        controller.snapshot.hasData;
    final line = ready
        ? teamStatusLine(
            context,
            controller: controller,
            keyPrefix: 'team-agents',
            onRetry: _refreshing ? null : _refresh,
          )
        : null;
    final checkedAt = controller.lastRefreshedAt;
    final age = checkedAt == null ? null : _now.difference(checkedAt);
    final subtitle = [
      teamHostPhrase(l10n, controller),
      if (ready && age != null)
        l10n.teamAgentsChecked(
          KitSince.ageLabel(context, age.isNegative ? Duration.zero : age),
        ),
    ].join(teamUsageSeparator);
    final roles = _roles;
    return KitScreen(
      key: const ValueKey('team-agents'),
      topBar: KitTopBar(title: l10n.teamRolesTitle, subtitle: subtitle),
      width: KitScreenWidth.list,
      status: line,
      loading: roles == null || _refreshing,
      loadingLabel: l10n.teamUiCardLoading,
      body: roles == null ? const SizedBox.shrink() : _body(context, roles),
      bottom: KitActionBlock(
        primary: KitAction(
          key: const ValueKey('team-roles-new'),
          label: l10n.teamRolesNew,
          icon: AppIconography.add,
          onPressed: roles == null ? null : () => _openRole(null),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, TeamRolesController roles) {
    final tokens = KitTokens.of(context);
    final entries = _entries(roles);
    return KitRefresh(
      key: const ValueKey('team-agents-pull'),
      onRefresh: _refresh,
      child: ListView(
        key: const ValueKey('team-home-agents'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsetsDirectional.only(
          top: tokens.space3,
          bottom: KitScreen.endPadding(context),
        ),
        children: [
          KitRowGroup(
            children: [
              for (final entry in entries) _row(context, roles, entry),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, TeamRolesController roles, _Entry entry) {
    final l10n = _copy(context);
    final role = entry.role;
    final title = role == null
        ? l10n.teamUiAgentRoleWorker
        : teamRoleName(l10n, role);
    final String line;
    if (entry.working) {
      final since = entry.since;
      final age = since == null ? null : _now.difference(since);
      final task = entry.task;
      line = [
        if (task != null && task.isNotEmpty)
          l10n
              .teamRoleWorkingOn(
                task,
                age == null
                    ? ''
                    : KitSince.ageLabel(
                        context,
                        age.isNegative ? Duration.zero : age,
                      ),
              )
              .replaceFirst(RegExp(r' · $'), '')
        else
          teamAgentStateWord(l10n, AgentState.working),
      ].join(teamUsageSeparator);
    } else {
      final model = _remote
          ? l10n.teamRoleUsesComputerModel
          : role!.model == null
          ? l10n.teamRoleUsesTeamModel
          : l10n.teamRoleUses(
              teamRoleModelName(widget.connection, role.model!),
            );
      line = [
        model,
        l10n.teamRoleTaskCount(
          teamRunsOfRole(roles, widget.controller, role!.id).length,
        ),
      ].join(teamUsageSeparator);
    }
    return KitRow(
      key: ValueKey(
        role == null
            ? 'team-role-worker-${entry.worker!.id}'
            : 'team-role-${role.id}',
      ),
      leading: entry.working
          ? KitTaskMark(
              state: KitTaskState.working,
              label: teamAgentStateWord(l10n, AgentState.working),
            )
          : KitRow.icon(context, AppIconography.agent),
      title: title,
      supporting: TextSpan(text: line),
      supportingMaxLines: 2,
      trailing: const KitChevron(),
      onTap: role == null
          ? () => _openWorker(entry.worker!)
          : () => _openRole(role.id),
    );
  }
}
