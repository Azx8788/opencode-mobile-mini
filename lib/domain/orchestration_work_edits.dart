/// Edits to one work item (a Gas City bead) that the AI Team's board offers
/// the person (docs/design/team-board-2026-09-26.md §3): its priority, taking
/// it back from the team, cancelling it, and putting a cancelled one back.
///
/// A separate, additive interface beside [OrchestrationGateway], like
/// [OrchestrationMergeGateway]: adapters that can edit beads implement it (or
/// an edit adapter wraps them), and the board checks for it at runtime, so a
/// host that cannot edit shows the board read-only. Every call takes the
/// client-generated [requestId] and resolves to a [MutationReceipt]; nothing
/// is retried.
///
/// Follow-up for the owner of `lib/orchestration/**`: fold these verbs into
/// [OrchestrationControlGateway] and `MutationKind` so they persist as
/// mutation records like the other writes, behind a `controlEditWork`
/// capability.
library;

import 'orchestration_gateway.dart';

/// Where a bead's priority sits. Gas City's `bd` counts 0 (most urgent) to
/// 4 (someday); 2 is what a new bead gets.
enum WorkPriority {
  urgent(0),
  high(1),
  normal(2),
  low(3),
  someday(4);

  const WorkPriority(this.value);

  /// The host's number.
  final int value;

  /// The priority for the host's number; [normal] when absent or unknown.
  static WorkPriority fromValue(Object? value) {
    final n = switch (value) {
      final int i => i,
      final num d => d.toInt(),
      final String s => int.tryParse(s.trim().replaceFirst('P', '')),
      _ => null,
    };
    for (final p in values) {
      if (p.value == n) return p;
    }
    return normal;
  }
}

abstract interface class OrchestrationWorkEditGateway {
  /// Sets [workId]'s priority.
  Future<MutationReceipt> setWorkPriority(
    String workId,
    WorkPriority priority, {
    required String requestId,
  });

  /// Takes [workId] back from the team before anyone started it: it is no
  /// longer routed to an agent pool, so it waits in the backlog.
  Future<MutationReceipt> unassignWork(
    String workId, {
    required String requestId,
  });

  /// Closes [workId] as cancelled.
  Future<MutationReceipt> cancelWork(
    String workId, {
    required String requestId,
  });

  /// Opens a closed [workId] again.
  Future<MutationReceipt> reopenWork(
    String workId, {
    required String requestId,
  });
}
