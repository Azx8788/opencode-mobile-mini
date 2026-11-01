/// The dispatch cycle of one work item (TEAM-116): which step of the
/// host's chain it is on and why it waits. Derived by
/// `deriveDispatchCycle` from the item's fields, the timeline events that
/// name it and the agent's transcript; never fetched from the host.
library;

/// The steps a routed work item goes through, in order. [merged] is the
/// terminal seventh: the strip shows the first six as dots and the merge
/// as its end mark.
enum DispatchStep {
  /// `gc.routed_to` set: the host chose an agent pool for the item.
  routed,

  /// A session of the routed pool woke (or appeared) in the rig.
  agentStarting,

  /// Status `in_progress` with an assignee: the agent took the item.
  claimed,

  /// The agent has a worktree (`gc.work_dir`) or its output is growing.
  working,

  /// `metadata.branch` set: the change is on a branch.
  pushed,

  /// The rig's refinery owns it, or the polecat drained after pushing.
  handedToMerge,

  /// The bead closed (not cancelled) or the run completed.
  merged;

  /// True for the six steps the strip shows as dots (everything but the
  /// terminal [merged]).
  bool get isDot => this != merged;

  /// The steps the strip shows as dots, in order.
  static const dots = [
    routed,
    agentStarting,
    claimed,
    working,
    pushed,
    handedToMerge,
  ];
}

/// Why a cycle waits longer than its step usually takes.
enum DispatchStall {
  /// Routed for over three minutes and no agent started.
  hostNotStarted,

  /// The agent's session woke and stopped again twice or more within a
  /// minute: it cannot stay up on the host.
  agentCannotStart,

  /// The agent's transcript says the model provider hit a usage limit,
  /// quota or rate limit.
  providerLimit,

  /// Working for over thirty minutes with nothing pushed.
  workingLong,

  /// Handed to merge over fifteen minutes ago and not merged.
  mergeWaiting,
}

/// A short note the strip shows under the current step.
enum DispatchHint {
  /// Agent starting is the slow step: "usually 1–5 min".
  usualWait,
}

/// Where one work item is in the dispatch chain.
class DispatchCycle {
  const DispatchCycle({
    required this.step,
    required this.reachedAt,
    this.stalled = false,
    this.stallReason,
    this.hint,
  });

  /// Nothing known: routed pending, nothing reached.
  static const none = DispatchCycle(step: DispatchStep.routed, reachedAt: {});

  /// The step in progress: the first one not reached yet, or [DispatchStep.merged]
  /// once everything is (see [isTerminal]).
  final DispatchStep step;

  /// When each reached step was reached, host time. Steps are reached in
  /// order; a step missing here is pending. A step present with a null
  /// time was reached at an unknown time: the item's fields carry the
  /// evidence but neither the events nor the bead's `updated_at` say
  /// when (TEAM-117), so the strip shows its check without a time.
  final Map<DispatchStep, DateTime?> reachedAt;

  /// True when the current step has waited past its usual window (or the
  /// transcript names a provider limit); [stallReason] says why.
  final bool stalled;
  final DispatchStall? stallReason;
  final DispatchHint? hint;

  /// True once the item is merged: nothing pulses, nothing stalls.
  bool get isTerminal => reachedAt.containsKey(DispatchStep.merged);

  /// True when [step] was reached.
  bool isDone(DispatchStep step) => reachedAt.containsKey(step);

  /// The last reached step, or null when nothing was reached.
  DispatchStep? get lastReached {
    DispatchStep? last;
    for (final step in DispatchStep.values) {
      if (reachedAt.containsKey(step)) last = step;
    }
    return last;
  }

  /// When the current wait began: the time the last step was reached,
  /// or null when nothing was reached or that time is unknown.
  DateTime? get since {
    final last = lastReached;
    return last == null ? null : reachedAt[last];
  }

  /// One-based position of [step] among the six dots, for "Step 2 of 6";
  /// the merge counts as the sixth step's end.
  int get position {
    final index = DispatchStep.dots.indexOf(step);
    return index < 0 ? DispatchStep.dots.length : index + 1;
  }

  @override
  String toString() =>
      'DispatchCycle(${step.name}'
      '${stalled ? ', stalled: ${stallReason?.name}' : ''})';
}
