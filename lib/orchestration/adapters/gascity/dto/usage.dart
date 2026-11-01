import 'json_read.dart';

/// Token and cost totals (`UsageTotals`) for one usage window.
class GcUsageTotals {
  const GcUsageTotals({
    this.invocations,
    this.computeFacts,
    this.inputTokens,
    this.outputTokens,
    this.cacheReadTokens,
    this.cacheCreationTokens,
    this.wallSeconds,
    this.costUsdEstimate,
    this.unpriced,
    this.raw = const {},
  });

  factory GcUsageTotals.fromJson(Map<String, Object?> json) => GcUsageTotals(
    invocations: readInt(json, 'invocations'),
    computeFacts: readInt(json, 'compute_facts'),
    inputTokens: readInt(json, 'input_tokens'),
    outputTokens: readInt(json, 'output_tokens'),
    cacheReadTokens: readInt(json, 'cache_read_tokens'),
    cacheCreationTokens: readInt(json, 'cache_creation_tokens'),
    wallSeconds: readDouble(json, 'wall_seconds'),
    costUsdEstimate: readDouble(json, 'cost_usd_estimate'),
    unpriced: readInt(json, 'unpriced'),
    raw: json,
  );

  final int? invocations;
  final int? computeFacts;
  final int? inputTokens;
  final int? outputTokens;
  final int? cacheReadTokens;
  final int? cacheCreationTokens;
  final double? wallSeconds;
  final double? costUsdEstimate;
  final int? unpriced;
  final Map<String, Object?> raw;
}

/// `UsageSessionRecent`: worker-attributed model usage in the recent window.
class GcUsageSessionRecent {
  const GcUsageSessionRecent({
    required this.session,
    required this.totals,
    this.sessionId,
  });

  factory GcUsageSessionRecent.fromJson(Map<String, Object?> json) =>
      GcUsageSessionRecent(
        session: readText(json, 'session') ?? '',
        sessionId: readText(json, 'session_id'),
        totals: GcUsageTotals.fromJson(json),
      );

  final String session;
  final String? sessionId;
  final GcUsageTotals totals;
}

/// `GET /usage` (`UsageBody`): `{available, recording, source, today,
/// recent, recent_window_secs, observed_from, updated_at}`. `source` is
/// `local_estimate` or `unavailable`; every figure is an estimate.
class GcUsage {
  const GcUsage({
    this.available = false,
    this.recording = false,
    this.source,
    this.today,
    this.recent,
    this.recentBySession,
    this.recentWindowSecs,
    this.observedFrom,
    this.updatedAt,
    this.partial = false,
    this.partialReasons = const [],
    this.raw = const {},
  });

  factory GcUsage.fromJson(Map<String, Object?> json) => GcUsage(
    available: readBool(json, 'available') ?? false,
    recording: readBool(json, 'recording') ?? false,
    source: readText(json, 'source'),
    today: hasMap(json, 'today')
        ? GcUsageTotals.fromJson(readMapField(json, 'today'))
        : null,
    recent: hasMap(json, 'recent')
        ? GcUsageTotals.fromJson(readMapField(json, 'recent'))
        : null,
    recentBySession: json['recent_by_session'] is List
        ? List.unmodifiable(
            readList(json, 'recent_by_session', GcUsageSessionRecent.fromJson),
          )
        : null,
    recentWindowSecs: readInt(json, 'recent_window_secs'),
    observedFrom: readDateTime(json, 'observed_from'),
    updatedAt: readDateTime(json, 'updated_at'),
    partial: readBool(json, 'partial') ?? false,
    partialReasons: readStringList(json, 'partial_reasons'),
    raw: json,
  );

  final bool available;
  final bool recording;
  final String? source;
  final GcUsageTotals? today;
  final GcUsageTotals? recent;
  final List<GcUsageSessionRecent>? recentBySession;
  final int? recentWindowSecs;
  final DateTime? observedFrom;
  final DateTime? updatedAt;
  final bool partial;
  final List<String> partialReasons;
  final Map<String, Object?> raw;

  /// True when figures are the host's local estimate rather than billing.
  bool get isEstimate => source == null || source == 'local_estimate';
}
