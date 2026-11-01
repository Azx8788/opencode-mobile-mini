import 'package:flutter/material.dart';

/// Presentation state; the caller supplies localized explanation and age.
enum KitTeamState {
  empty,
  loading,
  running,
  needsYou,
  stalled,
  failed,
  done,
  stale,
}

@immutable
class KitTeamItem {
  const KitTeamItem({
    required this.title,
    this.detail,
    this.meta,
    this.trailing,
    this.state = KitTeamState.done,
    this.onPressed,
  });
  final String title;
  final String? detail;
  final String? meta;

  /// A short value at the row's end ("See changes"); the chevron follows it
  /// when the row opens something.
  final String? trailing;
  final KitTeamState state;
  final VoidCallback? onPressed;
}

enum KitFindingSeverity { critical, major, minor }

@immutable
class KitTeamFinding {
  const KitTeamFinding({
    required this.id,
    required this.title,
    required this.severityLabel,
    this.severity = KitFindingSeverity.minor,
    this.detail,
    this.location,
    this.selected = false,
    this.onChanged,
  });
  final String id;
  final String title;
  final String severityLabel;
  final KitFindingSeverity severity;
  final String? detail;
  final String? location;
  final bool selected;
  final ValueChanged<bool>? onChanged;
}

/// One task line of a plan: number, title, a one-line detail, and who does it.
@immutable
class KitPlanTask {
  const KitPlanTask({
    required this.number,
    required this.title,
    this.detail,
    this.who,
    this.onChangeWho,
  });
  final int number;
  final String title;
  final String? detail;
  final String? who;

  /// When given, [who] is drawn as a neutral button that calls this (for
  /// example to choose the task's server); null leaves it plain text.
  final VoidCallback? onChangeWho;
}

/// A named group of plan tasks; [flagged] carries the worded review point.
@immutable
class KitPlanPhase {
  const KitPlanPhase({
    required this.title,
    required this.tasks,
    this.flagLabel,
  });
  final String title;
  final List<KitPlanTask> tasks;
  final String? flagLabel;
}
