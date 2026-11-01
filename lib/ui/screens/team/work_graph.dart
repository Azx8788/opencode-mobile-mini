/// The one mapping from the app's work item to a `KitWorkGraphNode` (the
/// kit reads no app model): Task details draws a task's steps through
/// [WorkGraphNode.of] and `toKit`. The retired Graph view widget, layout,
/// edge and painter are gone (kit-hygiene, after slice-P3.5 retired the run
/// page): the graph is `KitWorkGraph`, its geometry
/// `KitWorkGraphGeometry.layers`.
library;

import '../../../l10n/app_localizations.dart';
import '../../../orchestration/models/work.dart';
import '../../kit/kit_task_mark.dart';
import '../../kit/kit_work_graph.dart';
import '../../widgets/team_vocabulary.dart';

/// One node of the graph: an item, its state and what it needs.
class WorkGraphNode {
  const WorkGraphNode({
    required this.id,
    required this.title,
    required this.state,
    this.dependsOn = const [],
  });

  WorkGraphNode.of(WorkItem item)
    : id = item.id,
      title = item.title,
      state = item.state,
      dependsOn = item.dependsOn;

  final String id;
  final String title;
  final WorkState state;

  /// Ids this node needs; ids outside the graph are ignored.
  final List<String> dependsOn;

  /// The graph's one WorkState → KitTaskState mapping: a real "needs you"
  /// mark only for a state that truly needs the person, never for
  /// "blocked" alone (LOOK-4). The word always comes from
  /// [teamWorkStateWord], so the chip and row say the true state.
  ///
  /// Contract problem (this unit's QA record): KitWorkGraph.md asks for
  /// "the blocked glyph" and for the host to map each state once through
  /// `teamWork*` (ARCH-8), but [KitTaskState] has no blocked (or queued,
  /// ready, review) value and `teamWorkMark` returns a glyph and tone (or
  /// the needs-you mark), not a [KitTaskState]. Until the coordinator
  /// decides (a `KitTaskState` value, or a `KitTaskState` mapping beside
  /// `teamWorkMark` in `widgets/team_vocabulary.dart`), this is the
  /// only copy of the mapping, and KitWorkGraph shows a stuck item's word
  /// visibly on its layers chip and rows line so it never reads as waiting.
  KitTaskState get _mark => switch (state) {
    WorkState.needsInput => KitTaskState.needsYou,
    WorkState.completed => KitTaskState.done,
    WorkState.failed => KitTaskState.failed,
    WorkState.cancelled => KitTaskState.stopped,
    WorkState.working || WorkState.review => KitTaskState.working,
    WorkState.queued ||
    WorkState.ready ||
    WorkState.waiting ||
    WorkState.blocked ||
    WorkState.unknown => KitTaskState.waiting,
  };

  KitWorkGraphNode toKit(AppLocalizations l10n) => KitWorkGraphNode(
    id: id,
    title: title,
    mark: _mark,
    word: teamWorkStateWord(l10n, state),
    dependsOn: dependsOn,
    stuck: teamWorkIsStuck(state),
    open: teamWorkIsOpen(state),
  );
}
