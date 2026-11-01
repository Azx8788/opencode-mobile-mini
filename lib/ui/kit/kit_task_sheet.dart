import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'kit_divider.dart';
import 'kit_sheet.dart';
import 'kit_task_mark.dart';
import 'kit_text.dart';
import 'kit_tokens.dart';

/// Where one task of the agent's list stands.
enum KitTaskItemState { todo, inProgress, done, cancelled }

/// One task of the list [showKitTaskSheet] shows: its words and its state.
class KitTaskItem {
  const KitTaskItem(this.text, this.state);
  final String text;
  final KitTaskItemState state;
}

/// The agent's whole task list in a sheet titled "Tasks", with "5 of 6
/// done" under it: a done task is a check in muted words, the task in
/// progress a spinner ring in bold, a task still to do an empty ring.
/// Opened from [KitTaskChip].
///
/// [done] and [total] are the tracked counts (cancelled tasks are in
/// neither).
///
/// [running] is whether the agent is working now. When it is not, the task
/// marked in progress keeps its words and its bold but shows a still ring:
/// a spinner that never stops would say work is going on when it is not.
///
/// [sheetKey] is the sheet's key, `task-sheet` when none is given.
Future<void> showKitTaskSheet(
  BuildContext context, {
  required List<KitTaskItem> items,
  required int done,
  required int total,
  bool running = true,
  Key? sheetKey,
}) {
  final l10n = lookupAppLocalizations(Localizations.localeOf(context));
  return showKitSheet<void>(
    context,
    sheetKey: sheetKey ?? const Key('task-sheet'),
    title: l10n.workTitle,
    subtitle: l10n.mobileTasksProgress(done, total),
    body: (context) => _TaskLines(items: items, running: running),
  );
}

class _TaskLines extends StatelessWidget {
  const _TaskLines({required this.items, required this.running});

  final List<KitTaskItem> items;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final tokens = KitTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < items.length; i += 1) ...[
          if (i > 0) const KitDivider(),
          MergeSemantics(
            child: Padding(
              padding: EdgeInsetsDirectional.symmetric(vertical: tokens.space1),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  KitTaskMark(
                    state: switch (items[i].state) {
                      KitTaskItemState.todo => KitTaskState.waiting,
                      KitTaskItemState.inProgress =>
                        running ? KitTaskState.working : KitTaskState.waiting,
                      KitTaskItemState.done => KitTaskState.done,
                      KitTaskItemState.cancelled => KitTaskState.stopped,
                    },
                    label: switch (items[i].state) {
                      KitTaskItemState.todo => l10n.mobileTaskPending,
                      KitTaskItemState.inProgress => l10n.mobileTaskInProgress,
                      KitTaskItemState.done => l10n.mobileTaskCompleted,
                      KitTaskItemState.cancelled => l10n.mobileTaskCancelled,
                    },
                  ),
                  SizedBox(width: tokens.space2),
                  Expanded(
                    child: KitText(
                      items[i].text,
                      role: items[i].state == KitTaskItemState.inProgress
                          ? KitTextRole.button
                          : KitTextRole.body,
                      tone:
                          items[i].state == KitTaskItemState.done ||
                              items[i].state == KitTaskItemState.cancelled
                          ? KitTextTone.secondary
                          : KitTextTone.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
