/// The AI Team's board (docs/design/team-board-2026-09-26.md): which of a
/// project's tasks (Gas City beads) sit in which column, what the person may
/// change on each, and the edits that change them.
///
/// Pure derivation from [OrchestrationSnapshot]: nothing here reads the host
/// except [TeamBoardEdits], which sends a move and refreshes the controller.
library;

import '../domain/orchestration_gateway.dart';
import '../domain/orchestration_work_edits.dart';
import '../orchestration/adapters/gascity/gascity_gateway.dart';
import '../orchestration/adapters/gascity/gascity_work_edits.dart';
import 'orchestration.dart';
import 'team_planning.dart' show teamWorkerPoolId;

export '../domain/orchestration_work_edits.dart' show WorkPriority;

/// The board's columns, left to right.
enum TeamBoardColumn { backlog, ready, working, review, done }

/// Finished tasks older than this leave the Done column.
const teamBoardDoneWindow = Duration(days: 7);

/// Bead types the host makes for its own bookkeeping: never a card.
const _bookkeepingTypes = {
  'session',
  'convoy',
  'message',
  'molecule',
  'gate',
  'agent',
  'role',
  'rig',
  'event',
  'merge-request',
  'merge_request',
  'slot',
  'wisp',
};

final _chorePrefix = RegExp(r'^(order|nudge)[:\-]', caseSensitive: false);

String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

Map<String, Object?> _metadata(WorkItem item) {
  final raw = item.raw['metadata'];
  return raw is Map ? raw.cast<String, Object?>() : const {};
}

/// The bead's type (`task`, `bug`, `feature`, `epic`, …), lower case.
String? teamBoardType(WorkItem item) =>
    _text(item.raw['issue_type'] ?? item.raw['type'])?.toLowerCase();

/// True for the host's own bookkeeping beads, which are never on the board:
/// sessions, convoys, mail, molecules, gates, agent/role/rig records, merge
/// requests, ephemeral wisps, and order / nudge chores (a title such as
/// `order:phone-upkeep`, a label `order-run:*`, `gc:session`, `gc:nudge`, or
/// the metadata `gc.kind` of a wisp).
bool teamBoardIsBookkeeping(WorkItem item) {
  final type = teamBoardType(item);
  if (type != null && _bookkeepingTypes.contains(type)) return true;
  if (item.raw['ephemeral'] == true) return true;
  final kind = _text(_metadata(item)['gc.kind'])?.toLowerCase();
  if (kind == 'wisp' || kind == 'gate' || kind == 'session') return true;
  if (_chorePrefix.hasMatch(item.title.trim())) return true;
  for (final label in item.labels) {
    final l = label.toLowerCase();
    if (l == 'gc:session' ||
        l == 'gc:nudge' ||
        l.startsWith('order-run:') ||
        l.startsWith('order:') ||
        l == 'gc:order') {
      return true;
    }
  }
  return false;
}

/// The pool or agent the bead was given to (`gc.routed_to`), if any.
String? teamBoardRoutedTo(WorkItem item) =>
    _text(_metadata(item)['gc.routed_to']);

/// The bead's own assignee: an agent that took it (not the pool).
String? teamBoardAssignee(WorkItem item) => _text(item.raw['assignee']);

/// The column [item] sits in, from its state, who has it and its session.
/// [agentOnIt] is true when an agent reports it as its current work.
TeamBoardColumn teamBoardColumnOf(WorkItem item, {bool agentOnIt = false}) {
  switch (item.state) {
    case WorkState.completed:
    case WorkState.cancelled:
      return TeamBoardColumn.done;
    case WorkState.review:
      return TeamBoardColumn.review;
    case WorkState.working:
    case WorkState.waiting:
    case WorkState.needsInput:
    case WorkState.failed:
      return TeamBoardColumn.working;
    case WorkState.queued:
    case WorkState.ready:
    case WorkState.blocked:
    case WorkState.unknown:
      break;
  }
  if (workHandedToMerge(item)) return TeamBoardColumn.review;
  final session = _text(item.sessionId);
  if (session != null || agentOnIt || teamBoardAssignee(item) != null) {
    // A worker took it (its own assignee or a live session): working,
    // even while the bead still says open.
    return TeamBoardColumn.working;
  }
  if (teamBoardRoutedTo(item) != null) return TeamBoardColumn.ready;
  return TeamBoardColumn.backlog;
}

/// One card: a task and what the board shows about it.
class TeamBoardCard {
  const TeamBoardCard({
    required this.item,
    required this.column,
    required this.priority,
    this.type,
    this.epic,
    this.epicDone = 0,
    this.epicTotal = 0,
    this.blockers = const [],
    this.needsYou = false,
    this.moving = false,
    this.agentName,
  });

  final WorkItem item;
  final TeamBoardColumn column;
  final WorkPriority priority;

  /// `bug`, `feature`, `epic`, … (null for a plain task).
  final String? type;

  /// The epic this task belongs to, when it has one on the board.
  final WorkItem? epic;

  /// For an epic: its children done and in all.
  final int epicDone;
  final int epicTotal;

  /// Open tasks this one waits on.
  final List<WorkItem> blockers;

  /// A question from the team waits on the person for this task.
  final bool needsYou;

  /// The person moved it here and the host has not shown it yet.
  final bool moving;

  /// The agent working it, when one says so.
  final String? agentName;

  String get id => item.id;
  bool get isEpic => type == 'epic';
  bool get isBlocked =>
      item.state == WorkState.blocked || item.isBlocked || blockers.isNotEmpty;
  bool get failed => item.state == WorkState.failed;
  bool get cancelled => item.state == WorkState.cancelled;

  /// The team conversation (task) this card belongs to, when there is one.
  String? get runId => item.runId;
}

/// A project's board: the cards of each column, in the order shown.
class TeamBoard {
  const TeamBoard(this.columns);

  final Map<TeamBoardColumn, List<TeamBoardCard>> columns;

  List<TeamBoardCard> cards(TeamBoardColumn column) =>
      columns[column] ?? const [];

  int count(TeamBoardColumn column) => cards(column).length;

  int get total => columns.values.fold(0, (sum, c) => sum + c.length);

  bool get isEmpty => total == 0;

  /// Some card in [column] waits on the person.
  bool needsYou(TeamBoardColumn column) =>
      cards(column).any((card) => card.needsYou);

  TeamBoardCard? find(String id) {
    for (final list in columns.values) {
      for (final card in list) {
        if (card.id == id) return card;
      }
    }
    return null;
  }
}

/// The projects the board can show, in the host's order; an empty list when
/// the host reports none (the board then shows every task).
List<OrchestrationProject> teamBoardProjects(OrchestrationSnapshot snapshot) =>
    snapshot.projects;

/// The board for [projectId] (every task when null). [pending] places the
/// cards the person just moved in their new column until the host shows
/// them there; [now] bounds the Done column to [teamBoardDoneWindow].
TeamBoard buildTeamBoard(
  OrchestrationSnapshot snapshot, {
  String? projectId,
  required DateTime now,
  Map<String, TeamBoardColumn> pending = const {},
}) {
  // The work of the host's own upkeep runs (patrols, chores) is its
  // bookkeeping too.
  final upkeep = {
    for (final run in snapshot.runs)
      if (run.isUpkeep) run.id,
  };
  final visible = [
    for (final item in snapshot.work)
      if (!teamBoardIsBookkeeping(item) &&
          !upkeep.contains(item.runId) &&
          (projectId == null ||
              item.projectId == null ||
              item.projectId == projectId))
        item,
  ];
  final byId = {for (final item in visible) item.id: item};
  final agentOn = <String, String>{
    for (final agent in snapshot.agents) ?agent.currentWorkId: agent.name,
  };
  final gated = <String>{for (final gate in snapshot.gates) ?gate.workId};
  final children = <String, List<WorkItem>>{};
  for (final item in visible) {
    final parent = item.parentId;
    if (parent != null && byId.containsKey(parent)) {
      (children[parent] ??= []).add(item);
    }
  }
  final since = now.subtract(teamBoardDoneWindow);
  final columns = {
    for (final c in TeamBoardColumn.values) c: <TeamBoardCard>[],
  };
  for (final item in visible) {
    final hosted = teamBoardColumnOf(
      item,
      agentOnIt: agentOn.containsKey(item.id),
    );
    final moved = pending[item.id];
    final column = moved ?? hosted;
    if (column == TeamBoardColumn.done && moved == null) {
      final at = item.updatedAt ?? item.createdAt;
      if (at != null && at.isBefore(since)) continue;
    }
    final type = teamBoardType(item);
    final kids = children[item.id] ?? const [];
    final parent = item.parentId == null ? null : byId[item.parentId];
    columns[column]!.add(
      TeamBoardCard(
        item: item,
        column: column,
        priority: WorkPriority.fromValue(item.raw['priority']),
        type: type == 'task' ? null : type,
        epic: parent != null && teamBoardType(parent) == 'epic' ? parent : null,
        epicDone: kids.where((k) => k.state == WorkState.completed).length,
        epicTotal: kids.length,
        blockers: [
          for (final id in item.dependsOn)
            if (byId[id] case final dep?
                when dep.state != WorkState.completed &&
                    dep.state != WorkState.cancelled &&
                    teamBoardType(dep) != 'epic')
              dep,
        ],
        needsYou: item.state == WorkState.needsInput || gated.contains(item.id),
        moving: moved != null && moved != hosted,
        agentName: agentOn[item.id],
      ),
    );
  }
  for (final entry in columns.entries) {
    entry.value.sort(
      entry.key == TeamBoardColumn.done ? _byRecent : _byUrgency,
    );
  }
  return TeamBoard(columns);
}

int _byRecent(TeamBoardCard a, TeamBoardCard b) {
  final at = a.item.updatedAt ?? a.item.createdAt;
  final bt = b.item.updatedAt ?? b.item.createdAt;
  if (at == null || bt == null) {
    return (at == null ? 1 : 0) - (bt == null ? 1 : 0);
  }
  return bt.compareTo(at);
}

/// What needs the person first, then what is stuck, then by priority, then
/// the most recently touched.
int _byUrgency(TeamBoardCard a, TeamBoardCard b) {
  int rank(TeamBoardCard c) => c.needsYou
      ? 0
      : c.failed
      ? 1
      : c.isBlocked
      ? 3
      : 2;
  final r = rank(a).compareTo(rank(b));
  if (r != 0) return r;
  final p = a.priority.value.compareTo(b.priority.value);
  if (p != 0) return p;
  return _byRecent(a, b);
}

/// What the person may do to a card from the board.
enum TeamBoardMove {
  /// Backlog → Ready: give it to the project's workers.
  startNow,

  /// Ready → Backlog: take it back before anyone started it.
  backToBacklog,

  /// Change its priority (Backlog, Ready).
  priority,

  /// Close it as cancelled (Backlog, Ready); always confirmed.
  cancel,

  /// A cancelled task back to the Backlog.
  reopen,
}

/// The column a move sends a card to; null when it stays (priority).
TeamBoardColumn? teamBoardMoveTarget(TeamBoardMove move) => switch (move) {
  TeamBoardMove.startNow => TeamBoardColumn.ready,
  TeamBoardMove.backToBacklog ||
  TeamBoardMove.reopen => TeamBoardColumn.backlog,
  TeamBoardMove.cancel => TeamBoardColumn.done,
  TeamBoardMove.priority => null,
};

/// The outcome of one board edit.
class TeamBoardEditResult {
  const TeamBoardEditResult({required this.ok, this.message});

  final bool ok;

  /// Why the host refused, in its words; null when it accepted.
  final String? message;
}

/// Sends the board's moves: Start now through the controller's proven
/// assign (a persisted mutation record), the rest through the additive
/// [OrchestrationWorkEditGateway]; the controller refreshes afterwards so the
/// host's answer is what the board shows.
class TeamBoardEdits {
  TeamBoardEdits(this.controller, {OrchestrationWorkEditGateway? edits})
    : _edits = edits;

  final OrchestrationController controller;
  final OrchestrationWorkEditGateway? _edits;
  var _seq = 0;

  /// The bead edits for [gateway] when it can make them; null otherwise.
  static OrchestrationWorkEditGateway? editsFor(OrchestrationGateway? gateway) {
    if (gateway is OrchestrationWorkEditGateway) {
      return gateway as OrchestrationWorkEditGateway;
    }
    if (gateway is GasCityGateway) return GasCityWorkEdits.of(gateway);
    return null;
  }

  OrchestrationWorkEditGateway? get edits =>
      _edits ?? editsFor(controller.gateway);

  bool get canStart => controller.capabilities.controlAssign;
  bool get canEdit => edits != null;
  bool get canCreate => controller.capabilities.controlCreateWork;

  /// Nothing on the board can be changed from this phone.
  bool get readOnly => !canStart && !canEdit && !canCreate;

  /// The moves the person may make on [card] here.
  List<TeamBoardMove> movesFor(TeamBoardCard card) {
    if (card.moving) return const [];
    return switch (card.column) {
      TeamBoardColumn.backlog => [
        if (canStart && card.item.projectId != null && !card.isEpic)
          TeamBoardMove.startNow,
        if (canEdit) TeamBoardMove.priority,
        if (canEdit) TeamBoardMove.cancel,
      ],
      TeamBoardColumn.ready => [
        if (canEdit) TeamBoardMove.backToBacklog,
        if (canEdit) TeamBoardMove.priority,
        if (canEdit) TeamBoardMove.cancel,
      ],
      TeamBoardColumn.done => [
        if (canEdit && card.cancelled) TeamBoardMove.reopen,
      ],
      TeamBoardColumn.working || TeamBoardColumn.review => const [],
    };
  }

  String _key(TeamBoardMove move, String id) =>
      'board-${move.name}-$id-${DateTime.now().microsecondsSinceEpoch}-${_seq++}';

  /// Sends [move] for [card] ([priority] for [TeamBoardMove.priority]).
  /// Never throws.
  Future<TeamBoardEditResult> run(
    TeamBoardMove move,
    TeamBoardCard card, {
    WorkPriority? priority,
  }) async {
    final id = card.id;
    MutationReceipt? receipt;
    try {
      if (move == TeamBoardMove.startNow) {
        final project = card.item.projectId;
        if (project == null) {
          return const TeamBoardEditResult(ok: false);
        }
        final record = await controller.assignWork(
          id,
          agentId: teamWorkerPoolId(project),
        );
        if (record.status == MutationStatus.rejected) {
          return TeamBoardEditResult(
            ok: false,
            message: record.receipt?.message,
          );
        }
      } else {
        final edits = this.edits;
        if (edits == null) return const TeamBoardEditResult(ok: false);
        final key = _key(move, id);
        receipt = switch (move) {
          TeamBoardMove.priority => await edits.setWorkPriority(
            id,
            priority ?? WorkPriority.normal,
            requestId: key,
          ),
          TeamBoardMove.backToBacklog => await edits.unassignWork(
            id,
            requestId: key,
          ),
          TeamBoardMove.cancel => await edits.cancelWork(id, requestId: key),
          TeamBoardMove.reopen => await edits.reopenWork(id, requestId: key),
          TeamBoardMove.startNow => throw StateError('unreachable'),
        };
        if (receipt.status == MutationReceiptStatus.rejected) {
          return TeamBoardEditResult(ok: false, message: receipt.message);
        }
      }
    } on Object catch (error) {
      return TeamBoardEditResult(ok: false, message: '$error');
    }
    try {
      await controller.refresh();
    } on Object {
      // The move went; a failed refresh shows as the screen's status line.
    }
    return const TeamBoardEditResult(ok: true);
  }
}
