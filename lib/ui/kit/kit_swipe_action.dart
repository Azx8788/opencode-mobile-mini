// A row's one swipe (docs/ux-system/kit-api/KitSwipeAction.md; kit-v2.md
// §2.5, §4.1): an accelerator for an act whose treatment is "act, then
// Undo". It never confirms, carries no destructive tint, and always has a
// twin in the row's menu that runs the identical path.
import 'dart:async';

import 'package:flutter/material.dart';

import 'kit_menu.dart';
import 'kit_undo.dart';

/// A row's swipe (kit-v2.md §2.5). Only for an act whose DATA-11
/// treatment is Undo: there is no confirm variant and no destructive tint.
/// The act itself runs in [onAct]; the kit then shows the one undo
/// snackbar. KitRow adds the same act to its menu (the gesture's twin).
///
/// States: idle, revealing, acted (undo showing), failed (KIT-12).
@immutable
class KitSwipeAction {
  const KitSwipeAction({
    required this.id,
    required this.label,
    required this.icon,
    required this.onAct,
    required this.undoMessage,
    required this.onUndo,
    this.onCommit,
    this.group,
  });

  /// Unique per row in its list: becomes the Dismissible key
  /// (`session-dismiss-<id>` today; keep existing test keys, TEST-5).
  final Key id;

  /// The verb, as on the menu item: "Archive". Also the revealed word
  /// behind the row and the semantic custom action's name.
  final String label;

  /// One glyph per verb (COPY-18), e.g. AppIconography.archive.
  final IconData icon;

  /// Does the act, or, for a deferred local act, hides the item and returns
  /// (the real write happens in [onCommit]). Completes true when done; false
  /// when it failed and the caller has already shown a KitNotice where the
  /// thing is (§4.8). Throwing counts as false.
  final Future<bool> Function() onAct;

  /// The undo line, naming the thing: "Archived 'Fix login'" (KitUndo).
  final String undoMessage;

  /// Runs the inverse, or cancels a deferred commit. Same type as
  /// showKitUndo's (KitUndo.md). A failing undo is handled by KitUndo: the
  /// bar turns into its "Couldn't undo · Try again" form, never silent.
  final FutureOr<void> Function() onUndo;

  /// Deferred commits (DATA-11 b): runs when the undo window closes unused,
  /// when a new undo arrives, when the route pops, or on
  /// AppLifecycleState.paused (KitUndo runs it exactly once or never).
  /// Null: [onAct] already did the write and [onUndo] is the server's
  /// inverse call (DATA-11 a).
  final FutureOr<void> Function()? onCommit;

  /// The menu group the twin item joins (KitMenuItem.group).
  final Object? group;

  /// The row menu's twin item: same label, icon and group.
  ///
  /// A `KitMenuItem.onSelected` receives no `BuildContext`, and the undo
  /// line needs one, so this bare item cannot finish the path by itself:
  /// `KitRow(swipe:)` puts this twin in its menu with `onSelected` bound to
  /// [run] in the row's context (one treatment from every door). Selecting
  /// the bare item asserts in debug builds and does nothing in release; use
  /// the swipe through `KitRow.swipe` (reported to the coordinator, QA
  /// record of kit-KitRow-v2).
  KitMenuItem get menuItem => KitMenuItem(
    label: label,
    icon: icon,
    group: group,
    onSelected: () {
      assert(
        false,
        'KitSwipeAction.menuItem has no BuildContext for the undo line; '
        'pass the swipe to KitRow(swipe:), which binds the twin to run().',
      );
    },
  );

  /// The one path from every door (the swipe, the menu twin, the semantic
  /// custom action): runs [onAct]; when it completes true, shows the undo
  /// line with [showKitUndo]. Completes with [onAct]'s outcome. A false or
  /// throwing [onAct] ends here: the caller's KitNotice is the failure and
  /// no undo line is shown for an act that did not happen.
  ///
  /// The list owner may remove the row while [onAct] runs; the undo line
  /// then shows from the row's route. With no host left at all, a deferred
  /// act commits at once rather than being lost.
  Future<bool> run(BuildContext context) async {
    final route = ModalRoute.of(context);
    bool done;
    try {
      done = await onAct();
    } on Object {
      done = false;
    }
    if (!done) return false;
    if (context.mounted) {
      showKitUndo(
        context,
        message: undoMessage,
        onUndo: onUndo,
        onCommit: onCommit,
      );
      return true;
    }
    final routeContext = route?.subtreeContext;
    if (routeContext != null && routeContext.mounted) {
      showKitUndo(
        routeContext,
        message: undoMessage,
        onUndo: onUndo,
        onCommit: onCommit,
      );
      return true;
    }
    await onCommit?.call();
    return true;
  }
}
