/// Start a run from the phone (TEAM-204; 02-ux-flows-and-screens §7,
/// 06-decisions decision 3): the objective and its supervision level go to
/// the planner (Gas Town's Mayor) as one message through the control
/// gateway — the supervisor has no "objective" endpoint, so the message
/// *is* the request. Until the planner materialises beads the home shows
/// "Planning… (Mayor)"; this module derives that state from the persisted
/// [MutationRecord] (no second store) and resolves it when a run appears
/// whose title carries the objective or whose metadata carries the
/// request's correlation id.
library;

import '../orchestration/models/agent.dart';
import '../orchestration/models/run.dart';
import 'mutation_store.dart';

/// Supervision levels (02-ux §7). The descriptions live in l10n; the line
/// sent to the planner is [TeamSupervision.line].
enum TeamSupervision {
  high,
  balanced,
  autonomous;

  /// The English line the planner reads; server content is never
  /// translated (02-ux §12).
  String get line => switch (this) {
    high =>
      'High — ask before every decision, before state-changing tests and '
          'before any merge',
    balanced =>
      'Balanced — decide routine matters, ask before merges, on failures '
          'and on design choices',
    autonomous =>
      'Autonomous — work to completion inside the host boundaries; ask '
          'only when unable to continue',
  };

  /// The level from a persisted line; null when the line is not one.
  static TeamSupervision? fromLine(String? line) {
    if (line == null) return null;
    for (final level in values) {
      if (line.trim() == level.line) return level;
    }
    return null;
  }
}

/// The planner every Gas Town city configures (06-decisions §A.1).
const teamPlannerAgentId = 'gastown.mayor';

/// The worker pool every Gas Town rig configures; a task slung at it is
/// picked up by the next free polecat.
const teamWorkerPoolName = 'gastown.polecat';

/// The sling target of the worker pool of the rig [projectId]
/// (`<rig>/gastown.polecat`), where a direct task goes when the planner
/// is off (TEAM-306).
String teamWorkerPoolId(String projectId) => '$projectId/$teamWorkerPoolName';

/// First line of every Start-a-run message; how a record is recognised
/// as a planning request after a restart.
const teamPlanningMarker = '[OpenCode Plus · Start a run]';

/// What the marker was before the rename. Messages written by 0.3.13 and
/// earlier still carry it, and a restart must keep recognising them.
const legacyTeamPlanningMarker = '[OpenCode Mini · Start a run]';

/// Characters of the objective a run title must carry to count as the
/// run the request produced.
const teamPlanningTitleMatch = 40;

/// After this long without a run the card says "Still planning".
const teamPlanningPatience = Duration(minutes: 30);

/// The message sent to the planner: the marker, the objective, the
/// project when chosen and the supervision line, then the ask.
String composeTeamPlanningMessage({
  required String objective,
  required TeamSupervision supervision,
  String? projectName,
}) {
  final lines = <String>[
    teamPlanningMarker,
    'Objective: ${objective.trim()}',
    if (projectName != null && projectName.trim().isNotEmpty)
      'Project: ${projectName.trim()}',
    'Supervision: ${supervision.line}',
    '',
    'Please plan this objective into beads and start a run for it. Keep '
        'the objective text in the run title so the phone can find it.',
  ];
  return lines.join('\n');
}

/// Where a Start-a-run request stands.
enum TeamPlanningStatus {
  /// Sent and confirmed or awaiting the host; no run yet, inside the
  /// patience window.
  planning,

  /// Past [teamPlanningPatience] without a run.
  stillPlanning,

  /// Sent, but nobody knows whether the host stored it.
  unconfirmed,

  /// The host or the front refused the message.
  refused,

  /// A run carrying the objective exists: the card resolves.
  started,
}

/// One Start-a-run request as the home shows it.
class TeamPlanningRequest {
  const TeamPlanningRequest({
    required this.record,
    required this.objective,
    required this.supervision,
    required this.status,
    this.projectName,
    this.run,
  });

  final MutationRecord record;
  final String objective;
  final TeamSupervision supervision;
  final String? projectName;
  final TeamPlanningStatus status;

  /// The run that resolved the request, when [status] is
  /// [TeamPlanningStatus.started].
  final OrchestrationRun? run;

  String get key => record.key;
  DateTime get sentAt => record.createdAt;

  /// The agent the message went to (the planner).
  String get plannerId => record.targetId;

  /// Parses a persisted message record back into its request; null for
  /// any record that is not a Start-a-run message.
  static ({String objective, TeamSupervision supervision, String? projectName})?
  parse(MutationRecord record) {
    if (record.kind != MutationKind.message) return null;
    final text = record.request.text;
    if (text == null) return null;
    final lines = text.split('\n');
    final first = lines.isEmpty ? '' : lines.first.trim();
    if (first != teamPlanningMarker && first != legacyTeamPlanningMarker) {
      return null;
    }
    String? objective;
    String? projectName;
    TeamSupervision? supervision;
    for (final line in lines.skip(1)) {
      if (line.startsWith('Objective: ')) {
        objective = line.substring('Objective: '.length);
      } else if (line.startsWith('Project: ')) {
        projectName = line.substring('Project: '.length);
      } else if (line.startsWith('Supervision: ')) {
        supervision = TeamSupervision.fromLine(
          line.substring('Supervision: '.length),
        );
      }
    }
    if (objective == null || supervision == null) return null;
    return (
      objective: objective,
      supervision: supervision,
      projectName: projectName,
    );
  }
}

/// True when [run] is the run the request produced: its metadata names
/// the request's correlation id or key, or its title carries the first
/// [teamPlanningTitleMatch] characters of the objective, and it did not
/// start long before the request was sent.
bool teamPlanningRunMatches(
  OrchestrationRun run,
  MutationRecord record,
  String objective,
) {
  final started = run.startedAt;
  if (started != null &&
      started.isBefore(record.createdAt.subtract(const Duration(minutes: 5)))) {
    return false;
  }
  final ids = <String>{record.key, ?record.correlationId};
  if (_rawMentions(run.raw, ids)) return true;
  final needle = _fold(objective);
  if (needle.isEmpty) return false;
  final head = needle.length > teamPlanningTitleMatch
      ? needle.substring(0, teamPlanningTitleMatch)
      : needle;
  return _fold(run.title).contains(head);
}

bool _rawMentions(Object? value, Set<String> ids) {
  if (value is String) return ids.contains(value);
  if (value is Map) return value.values.any((v) => _rawMentions(v, ids));
  if (value is List) return value.any((v) => _rawMentions(v, ids));
  return false;
}

String _fold(String text) =>
    text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

/// Every Start-a-run request among [mutations] that is neither superseded
/// by a retry nor in [dismissed], newest first, each with its status
/// against [runs] at [now].
List<TeamPlanningRequest> teamPlanningRequests({
  required Iterable<MutationRecord> mutations,
  required List<OrchestrationRun> runs,
  required Set<String> dismissed,
  required DateTime now,
}) {
  final out = <TeamPlanningRequest>[];
  for (final record in mutations) {
    if (record.retriedBy != null || dismissed.contains(record.key)) continue;
    final parsed = TeamPlanningRequest.parse(record);
    if (parsed == null) continue;
    OrchestrationRun? match;
    for (final run in runs) {
      if (teamPlanningRunMatches(run, record, parsed.objective)) {
        match = run;
        break;
      }
    }
    final status = match != null
        ? TeamPlanningStatus.started
        : switch (record.status) {
            MutationStatus.rejected => TeamPlanningStatus.refused,
            MutationStatus.unconfirmed => TeamPlanningStatus.unconfirmed,
            MutationStatus.sent || MutationStatus.confirmed =>
              now.difference(record.createdAt) >= teamPlanningPatience
                  ? TeamPlanningStatus.stillPlanning
                  : TeamPlanningStatus.planning,
          };
    out.add(
      TeamPlanningRequest(
        record: record,
        objective: parsed.objective,
        supervision: parsed.supervision,
        projectName: parsed.projectName,
        status: status,
        run: match,
      ),
    );
  }
  out.sort((a, b) => b.sentAt.compareTo(a.sentAt));
  return out;
}

/// The planner among [agents], by id, then by name; null when the host
/// lists none.
OrchestrationAgent? teamPlannerAgent(List<OrchestrationAgent> agents) {
  for (final agent in agents) {
    if (agent.id == teamPlannerAgentId) return agent;
  }
  for (final agent in agents) {
    if (agent.name == teamPlannerAgentId ||
        agent.name.endsWith('.mayor') ||
        agent.id.endsWith('.mayor')) {
      return agent;
    }
  }
  return null;
}

/// True when the planner is suspended or stopped on the host (the lean
/// profile keeps the Mayor off): the sheet must not send.
bool teamPlannerIsOff(OrchestrationAgent planner) {
  final raw = planner.rawState?.toLowerCase().trim();
  if (raw == 'suspended' || raw == 'stopped') return true;
  final suspended = planner.raw['suspended'];
  if (suspended == true) return true;
  return planner.state == AgentState.stopped ||
      planner.state == AgentState.crashed;
}
