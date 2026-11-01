/// Usage snapshot for the host: counts and spend as far as the provider
/// reports them. Every figure is optional; absent means "not reported".
class OrchestrationUsage {
  const OrchestrationUsage({
    this.capturedAt,
    this.activeAgents,
    this.runsInProgress,
    this.workOpen,
    this.workReady,
    this.workInProgress,
    this.inputTokens,
    this.outputTokens,
    this.costUsd,
    this.evidence,
    this.raw = const {},
  });

  final DateTime? capturedAt;
  final int? activeAgents;
  final int? runsInProgress;

  /// Gas City `/status` `work.open`.
  final int? workOpen;

  /// Gas City `/status` `work.ready`.
  final int? workReady;

  /// Gas City `/status` `work.in_progress`.
  final int? workInProgress;
  final int? inputTokens;
  final int? outputTokens;
  final double? costUsd;

  /// Typed source and window information. Null means no usage evidence was
  /// supplied (for example, this snapshot contains only status counts).
  final OrchestrationUsageEvidence? evidence;

  /// Untouched provider payload.
  final Map<String, Object?> raw;

  /// True when no figure at all was reported.
  bool get isEmpty =>
      activeAgents == null &&
      runsInProgress == null &&
      workOpen == null &&
      workReady == null &&
      workInProgress == null &&
      inputTokens == null &&
      outputTokens == null &&
      costUsd == null;

  @override
  String toString() =>
      'OrchestrationUsage(open: $workOpen, ready: $workReady, '
      'inProgress: $workInProgress)';
}

/// A replacement snapshot, never a delta to accumulate across refreshes.
///
/// These figures describe host-wide windows, not task lifetime accounting.
/// Missing figures, availability, pricing or session attribution remain
/// unknown; the UI must not turn them into zero or authoritative charges.
class OrchestrationUsageEvidence {
  const OrchestrationUsageEvidence({
    required this.available,
    required this.recording,
    required this.isEstimated,
    required this.partial,
    this.partialReasons = const [],
    this.observedFrom,
    this.updatedAt,
    this.today,
    this.recent,
    this.recentWindow,
    this.recentBySession,
  });

  final bool available;
  final bool recording;
  final bool isEstimated;
  final bool partial;
  final List<String> partialReasons;

  /// Oldest fact in the bounded read, not the start of the host's day.
  final DateTime? observedFrom;
  final DateTime? updatedAt;

  /// Since midnight in the supervisor host's timezone, not device-local time.
  final OrchestrationUsageTotals? today;
  final OrchestrationUsageTotals? recent;
  final Duration? recentWindow;

  /// Null means the server omitted the breakdown; [] means it returned none.
  /// Values share [recentWindow] and [updatedAt]. Never add them to [recent]
  /// or [today], or accumulate them across overlapping refresh windows.
  final List<OrchestrationSessionUsage>? recentBySession;
}

/// Optional figures for exactly one source window. Unpriced facts are
/// excluded from [costUsdEstimate]; a zero estimate can still omit spend.
class OrchestrationUsageTotals {
  const OrchestrationUsageTotals({
    this.inputTokens,
    this.outputTokens,
    this.cacheReadTokens,
    this.cacheCreationTokens,
    this.costUsdEstimate,
    this.unpriced,
  });

  final int? inputTokens;
  final int? outputTokens;
  final int? cacheReadTokens;
  final int? cacheCreationTokens;
  final double? costUsdEstimate;

  /// Count of facts with unknown pricing. Null means not reported.
  final int? unpriced;
}

/// Model usage for one worker in the trailing window only. A session bead
/// is not an OpenCode session ID and has no authoritative task association.
class OrchestrationSessionUsage {
  const OrchestrationSessionUsage({
    required this.workerName,
    required this.totals,
    this.sessionId,
  });

  final String workerName;
  final String? sessionId;
  final OrchestrationUsageTotals totals;
}
