/// The AI Team board's words for a card and the mapping from the app's
/// [TeamBoardCard] to the kit's `KitTaskCard` (kit-KitTaskCard): the kit
/// reads no app model, so the words and the mapping stay here.
library;

import 'package:flutter/material.dart';

import '../../domain/relative_age.dart';
import '../../l10n/app_localizations.dart';
import '../../state/team_board.dart';
import '../app_theme.dart';
import '../kit/kit_buttons.dart';
import '../kit/kit_receipt.dart';
import '../kit/kit_task_card.dart';
import '../kit/kit_task_mark.dart';

AppLocalizations _copy(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

/// The column's one word.
String teamBoardColumnWord(AppLocalizations l10n, TeamBoardColumn column) =>
    switch (column) {
      TeamBoardColumn.backlog => l10n.teamBoardColumnBacklog,
      TeamBoardColumn.ready => l10n.teamBoardColumnReady,
      TeamBoardColumn.working => l10n.teamBoardColumnWorking,
      TeamBoardColumn.review => l10n.teamBoardColumnReview,
      TeamBoardColumn.done => l10n.teamBoardColumnDone,
    };

/// How long since a card last changed, coarsely: "Just now", "12 min ago",
/// "3h ago", "Yesterday".
String teamBoardAgeLabel(AppLocalizations l10n, Duration elapsed) =>
    relativeAgeLabel(elapsed, l10n: l10n);

/// The priority's one word.
String teamBoardPriorityWord(AppLocalizations l10n, WorkPriority priority) =>
    switch (priority) {
      WorkPriority.urgent => l10n.teamBoardPriorityUrgent,
      WorkPriority.high => l10n.teamBoardPriorityHigh,
      WorkPriority.normal => l10n.teamBoardPriorityNormal,
      WorkPriority.low => l10n.teamBoardPriorityLow,
      WorkPriority.someday => l10n.teamBoardPrioritySomeday,
    };

/// The type's one word, null for a plain task or a type the app does not
/// name (it is on the task's details).
String? teamBoardTypeWord(AppLocalizations l10n, String? type) =>
    switch (type) {
      'bug' => l10n.teamBoardTypeBug,
      'feature' => l10n.teamBoardTypeFeature,
      'epic' => l10n.teamBoardTypeEpic,
      'chore' => l10n.teamBoardTypeChore,
      _ => null,
    };

/// The card's leading mark.
KitTaskState teamBoardMark(TeamBoardCard card) {
  if (card.needsYou) return KitTaskState.needsYou;
  if (card.failed) return KitTaskState.failed;
  if (card.cancelled) return KitTaskState.stopped;
  return switch (card.column) {
    TeamBoardColumn.done => KitTaskState.done,
    TeamBoardColumn.working || TeamBoardColumn.review => KitTaskState.working,
    TeamBoardColumn.backlog || TeamBoardColumn.ready => KitTaskState.waiting,
  };
}

/// The card's one flag line and its glyph; null when there is none. How
/// it looks is the kit's: [KitTaskFlag] gives the needs-you flag the
/// needs-you word and no other kind amber (amber means "needs you" only,
/// LOOK-4), so the line carries no tone of its own.
(IconData, String)? teamBoardFlag(
  AppLocalizations l10n,
  TeamBoardCard card, {
  TeamBoardColumn? movingTo,
}) {
  if (card.moving) {
    return (
      AppIconography.forward,
      l10n.teamBoardFlagMoving(teamBoardColumnWord(l10n, card.column)),
    );
  }
  if (card.needsYou) {
    return (AppIconography.question, l10n.teamBoardFlagNeedsYou);
  }
  if (card.failed) {
    return (AppIconography.error, l10n.teamBoardFlagFailed);
  }
  if (card.isBlocked && card.column != TeamBoardColumn.done) {
    final blockers = card.blockers;
    return (
      AppIconography.blocked,
      blockers.isEmpty
          ? l10n.teamBoardFlagBlocked
          : blockers.length == 1
          ? l10n.teamBoardFlagBlockedBy(blockers.first.title)
          : l10n.teamBoardFlagBlockedByMore(
              blockers.first.title,
              blockers.length - 1,
            ),
    );
  }
  if (card.cancelled) {
    return (AppIconography.stopCircle, l10n.teamBoardFlagCancelled);
  }
  if (card.epic case final epic?) {
    return (AppIconography.layers, l10n.teamBoardFlagInEpic(epic.title));
  }
  return null;
}

/// The card's flag as the kit's [KitTaskFlag], in [teamBoardFlag]'s order;
/// null when there is none or the card is moving (a receipt then).
KitTaskFlag? _teamBoardKitFlag(AppLocalizations l10n, TeamBoardCard card) {
  if (card.moving) return null;
  final flag = teamBoardFlag(l10n, card);
  if (flag == null) return null;
  if (card.needsYou) {
    // The needs-you word is the kit's own ("Needs you"); the board's flag
    // says nothing more, so the line is the word alone.
    return const KitTaskFlag(kind: KitTaskFlagKind.needsYou, label: '');
  }
  if (card.failed) {
    return KitTaskFlag(kind: KitTaskFlagKind.failed, label: flag.$2);
  }
  if (card.isBlocked && card.column != TeamBoardColumn.done) {
    return KitTaskFlag(kind: KitTaskFlagKind.blocked, label: flag.$2);
  }
  if (card.cancelled) {
    return KitTaskFlag(kind: KitTaskFlagKind.stopped, label: flag.$2);
  }
  return KitTaskFlag(kind: KitTaskFlagKind.info, label: flag.$2, icon: flag.$1);
}

/// The kit's priority level for the app's [WorkPriority]: what a
/// `KitPriorityGlyph` draws for a card.
KitPriority teamBoardKitPriority(WorkPriority priority) => switch (priority) {
  WorkPriority.urgent => KitPriority.urgent,
  WorkPriority.high => KitPriority.high,
  WorkPriority.normal => KitPriority.normal,
  WorkPriority.low => KitPriority.low,
  WorkPriority.someday => KitPriority.someday,
};

IconData _typeIcon(String? type) => switch (type) {
  'bug' => AppIconography.bug,
  'feature' => AppIconography.sparkle,
  'epic' => AppIconography.layers,
  _ => AppIconography.checklist,
};

/// One card of the AI Team's board, as a `KitTaskCard`.
///
/// Retired by kit-KitTaskCard: use KitTaskCard.
class TeamBoardCardView extends StatelessWidget {
  const TeamBoardCardView({
    super.key,
    required this.card,
    required this.now,
    required this.onOpen,
    this.onMoves,
    this.onLongPress,
  });

  final TeamBoardCard card;
  final DateTime now;
  final VoidCallback onOpen;

  /// Opens the move sheet from the trailing "Move or change" action; null
  /// when the person may change nothing here (no action).
  final VoidCallback? onMoves;

  /// The same sheet from a long press (moves, or why there are none).
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final l10n = _copy(context);
    final id = card.id;
    final typeWord = teamBoardTypeWord(l10n, card.type);
    final at = card.item.updatedAt ?? card.item.createdAt;

    final meta = <KitTaskMeta>[
      if (card.priority != WorkPriority.normal)
        KitTaskMeta(
          teamBoardPriorityWord(l10n, card.priority),
          priority: teamBoardKitPriority(card.priority),
          strong: card.priority.value <= WorkPriority.high.value,
        ),
      if (typeWord != null)
        KitTaskMeta(
          card.isEpic && card.epicTotal > 0
              ? '$typeWord · '
                    '${l10n.teamBoardEpicProgress(card.epicDone, card.epicTotal)}'
              : typeWord,
          icon: _typeIcon(card.type),
        ),
      if (card.agentName case final name?) KitTaskMeta(name),
      if (at != null) KitTaskMeta(teamBoardAgeLabel(l10n, now.difference(at))),
    ];

    final moving = card.moving
        ? l10n.teamBoardFlagMoving(teamBoardColumnWord(l10n, card.column))
        : null;

    return KitTaskCard(
      cardKey: ValueKey('team-board-card-$id'),
      titleKey: ValueKey('team-board-card-title-$id'),
      metaKey: ValueKey('team-board-card-meta-$id'),
      flagKey: ValueKey('team-board-card-flag-$id'),
      actionKey: ValueKey('team-board-card-more-$id'),
      title: card.item.title,
      mark: teamBoardMark(card),
      onOpen: onOpen,
      meta: meta,
      flag: _teamBoardKitFlag(l10n, card),
      // A move in flight is a sending receipt in the move's own words
      // ("Moving to Review…"). The board knows no send time for a move, so
      // it does not escalate on its own; a refused move keeps the board's
      // screen-level notice.
      receipt: moving == null
          ? null
          : KitReceipt(state: KitReceiptState.sending, sendingLabel: moving),
      action: onMoves == null
          ? null
          : KitAction(
              label: l10n.teamBoardMoveMenuTooltip,
              icon: AppIconography.swap,
              onPressed: onMoves,
              disabledReason: moving,
            ),
      onLongPress: onLongPress,
    );
  }
}
