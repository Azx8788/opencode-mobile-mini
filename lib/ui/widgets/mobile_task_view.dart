import 'package:flutter/widgets.dart';

import '../../domain/mobile_tool_view.dart';
import '../../l10n/app_localizations.dart';
import '../kit/kit_buttons.dart';
import '../kit/kit_chip.dart';
import '../kit/kit_icon_button.dart';
import '../kit/kit_progress.dart';
import '../kit/kit_row.dart';
import '../kit/kit_task_mark.dart';
import '../kit/kit_text.dart';
import '../kit/kit_tokens.dart';

/// The agent's plan inside the opened Work step of a reply
/// (embedded-mobile-task-list): one readout ("2 of 4 done" and its bar),
/// then one list in the plan's own order, each task with the team's step
/// mark ([KitTaskMark]) and its state in words. "High priority" is a small
/// chip, never a colour; the other priorities are words in the supporting
/// line.
///
/// A long plan (more than [collapsedCount] tasks) shows a window that starts
/// just before the first unfinished task, with "Show all N tasks" to unfold
/// the rest in place (never a nested scroll inside the transcript).
///
/// Bundled presentation only. Filtering changes the local view, never tasks.
/// Copying writes the parsed list to the local clipboard (through the kit's
/// one copy service) and nothing else. There is deliberately no transport,
/// URL, callback or credential form API.
class MobileTaskList extends StatefulWidget {
  const MobileTaskList({super.key, required this.view});
  final MobileTaskView view;

  /// How many tasks a long plan shows before "Show all N tasks".
  static const int collapsedCount = 8;

  @override
  State<MobileTaskList> createState() => _MobileTaskListState();
}

class _MobileTaskListState extends State<MobileTaskList> {
  bool _unfinishedOnly = false;
  bool _showAll = false;

  static bool _unfinished(MobileTaskItem task) =>
      task.status == MobileTaskStatus.pending ||
      task.status == MobileTaskStatus.inProgress;

  @override
  Widget build(BuildContext context) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final tokens = KitTokens.of(context);
    final view = widget.view;
    final tasks = [
      for (final task in view.tasks)
        if (!_unfinishedOnly || _unfinished(task)) task,
    ];
    final tracked = view.trackedCount;
    final done = view.completedCount;

    // A long plan folds to a window around where the work is.
    var shown = tasks;
    final folded = !_showAll && tasks.length > MobileTaskList.collapsedCount;
    if (folded) {
      final firstOpen = tasks.indexWhere(_unfinished);
      final start = firstOpen <= 0
          ? 0
          : (firstOpen - 1).clamp(
              0,
              tasks.length - MobileTaskList.collapsedCount,
            );
      shown = tasks.sublist(start, start + MobileTaskList.collapsedCount);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // One readout: completed out of tracked (cancelled tasks are not
        // tracked), whatever the local filter shows.
        if (tracked > 0) ...[
          KitProgressView(
            progress: KitProgress.known(
              done / tracked,
              caption: l10n.mobileTasksProgress(done, tracked),
              key: const Key('mobile-tasks-progress-bar'),
            ),
          ),
          SizedBox(height: tokens.space2),
        ],
        Row(
          children: [
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: KitChip.action(
                  key: const Key('mobile-tasks-filter'),
                  label: l10n.mobileTasksUnfinished,
                  selected: _unfinishedOnly,
                  onPressed: () => setState(() {
                    _unfinishedOnly = !_unfinishedOnly;
                    _showAll = false;
                  }),
                ),
              ),
            ),
            SizedBox(width: tokens.space2),
            // Copies the FULL server-reported list, regardless of the local
            // filter: the filter is a viewing aid and the label says "all".
            KitIconButton.copy(
              key: const Key('mobile-tasks-copy-all'),
              text: view.toPlainText,
              tooltip: l10n.mobileTasksCopyAll,
            ),
          ],
        ),
        SizedBox(height: tokens.space2),
        if (tasks.isEmpty)
          KitText(
            l10n.mobileTasksNoUnfinished,
            key: const Key('mobile-tasks-empty'),
            role: KitTextRole.secondary,
            tone: KitTextTone.secondary,
          )
        else
          KitRowGroup(
            margin: EdgeInsets.zero,
            leadingIcons: false,
            children: [for (final task in shown) _TaskRow(task: task)],
          ),
        if (folded)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: KitButton.tertiary(
              key: const Key('mobile-tasks-show-all'),
              label: l10n.mobileTasksShowAll(tasks.length),
              onPressed: () => setState(() => _showAll = true),
            ),
          ),
      ],
    );
  }
}

/// One task: the team's step mark, the task's words (up to three lines),
/// its state in words, and "High priority" as a chip at the end.
class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task});

  final MobileTaskItem task;

  @override
  Widget build(BuildContext context) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final status = switch (task.status) {
      MobileTaskStatus.pending => l10n.mobileTaskPending,
      MobileTaskStatus.inProgress => l10n.mobileTaskInProgress,
      MobileTaskStatus.completed => l10n.mobileTaskCompleted,
      MobileTaskStatus.cancelled => l10n.mobileTaskCancelled,
    };
    final mark = switch (task.status) {
      MobileTaskStatus.pending => KitTaskState.waiting,
      MobileTaskStatus.inProgress => KitTaskState.working,
      MobileTaskStatus.completed => KitTaskState.done,
      MobileTaskStatus.cancelled => KitTaskState.stopped,
    };
    final high = task.priority == MobileTaskPriority.high;
    final priority = switch (task.priority) {
      null || MobileTaskPriority.high => null,
      MobileTaskPriority.medium => l10n.mobileTaskPriorityMedium,
      MobileTaskPriority.low => l10n.mobileTaskPriorityLow,
    };
    // At the end of the row; under the words at large text, so the badge
    // never squeezes the task's own words (A11Y-8).
    final badge = high ? KitChip(label: l10n.mobileTaskPriorityHigh) : null;
    final large = MediaQuery.textScalerOf(context).scale(1) >= 1.3;
    return KitRow(
      leading: KitTaskMark(state: mark, label: status),
      title: task.text,
      titleMaxLines: 3,
      supporting: TextSpan(
        text: priority == null ? status : '$status · $priority',
      ),
      trailing: large ? null : badge,
      below: large ? badge : null,
    );
  }
}
