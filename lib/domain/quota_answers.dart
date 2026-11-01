import 'usage_statistics.dart';

/// The authority that measured remaining provider quota.
enum QuotaAnswerSource { codexAccount, collector }

/// Availability of a fresh quota answer, independent of a retained snapshot.
enum QuotaAnswerStatus {
  ready,
  unavailable,
  needsSignIn,
  needsCollector,
  collectorAuth,
  unsupported,
  invalidResponse,
}

/// Numeric facts for one provider quota window; presentation localizes them.
class QuotaAnswerWindow {
  final String id;
  final double usedPercent;
  final int? durationMinutes;
  final DateTime? resetsAt;

  const QuotaAnswerWindow({
    required this.id,
    required this.usedPercent,
    this.durationMinutes,
    this.resetsAt,
  });

  double get remainingPercent => (100 - usedPercent).clamp(0, 100).toDouble();

  bool get isWeekly => durationMinutes == 10080;
}

/// A measurement whose observation time must survive offline reads unchanged.
///
/// [observedAt] is when the source measured the value, not when the UI read it.
/// An expired snapshot is historical evidence, never a fresh quota promise.
class QuotaAnswerSnapshot {
  final QuotaAnswerSource source;
  final DateTime observedAt;
  final List<QuotaAnswerWindow> windows;

  QuotaAnswerSnapshot({
    required this.source,
    required this.observedAt,
    required List<QuotaAnswerWindow> windows,
  }) : windows = List.unmodifiable(windows);

  /// Clamps clock skew to zero without changing the stored observation time.
  Duration age(DateTime now) {
    final elapsed = now.difference(observedAt);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  /// True as soon as any known window reset has been reached.
  ///
  /// A missing reset time does not imply freshness; callers still expose age.
  bool isExpired(DateTime now) => windows.any(
    (window) => window.resetsAt != null && !now.isBefore(window.resetsAt!),
  );
}

/// The actual interval covered by a Spent answer, independent of its selector.
///
/// [from] is inclusive and [to] exclusive, both in UTC. Convert them to the
/// query's display timezone before formatting; for date-only labels, the last
/// included instant is one millisecond before [to] for a non-empty interval.
/// When [matchesRequestedRange] is false, label the returned interval rather
/// than presenting [requestedRange] as the measured period (for example, a
/// thirty-day request that returned only September 2–6).
class SpentPeriod {
  final DateTime from;
  final DateTime to;
  final UsageRange requestedRange;
  final bool matchesRequestedRange;

  const SpentPeriod._({
    required this.from,
    required this.to,
    required this.requestedRange,
    required this.matchesRequestedRange,
  });

  /// Uses the response's interval, never inferred bounds from its activity.
  ///
  /// An all-time query has no requested lower bound: its returned start is
  /// allowed to be the first available record. The upper bound must still
  /// match. Other ranges require both bounds to match the submitted query.
  factory SpentPeriod.fromUsage({
    required UsageQuery query,
    required UsageStatistics statistics,
    required UsageRange requestedRange,
  }) => SpentPeriod._(
    from: DateTime.fromMillisecondsSinceEpoch(statistics.from, isUtc: true),
    to: DateTime.fromMillisecondsSinceEpoch(statistics.to, isUtc: true),
    requestedRange: requestedRange,
    matchesRequestedRange:
        statistics.to == query.to &&
        (statistics.from == query.from ||
            (requestedRange == UsageRange.allTime && query.from == null)),
  );
}
