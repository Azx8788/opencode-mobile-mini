/// Where OpenCode 2's own import of OpenCode 1 chats stands.
///
/// OpenCode 2 runs that import itself in the background on every start; the
/// app only reads its status (`GET /api/experimental/migration/v1`).
enum HistoryMigrationPhase {
  /// Old chats exist and the import has not started yet.
  required,

  /// The import is under way: see [HistoryMigrationStatus.done] and `total`.
  running,

  /// Nothing to bring over, or everything is across.
  completed,

  /// The import stopped; the old chats are still in OpenCode 1.
  error,
}

class HistoryMigrationStatus {
  const HistoryMigrationStatus(
    this.phase, {
    this.label,
    this.done,
    this.total,
    this.error,
  });

  final HistoryMigrationPhase phase;

  /// The server's name for the step ("Migrating sessions"); technical.
  final String? label;

  /// Sessions finished and sessions to do, when the server counts them.
  final int? done;
  final int? total;

  /// The server's own error text. Technical: shown only under Details.
  final String? error;

  /// True while there is something to tell the person: not finished.
  bool get pending =>
      phase == HistoryMigrationPhase.required ||
      phase == HistoryMigrationPhase.running;

  /// Reads the server's union. Anything unrecognised is null, so a changed
  /// contract says nothing rather than something wrong.
  static HistoryMigrationStatus? fromJson(Object? json) {
    final map = json is Map && json['data'] is Map
        ? json['data'] as Map
        : json is Map
        ? json
        : null;
    if (map == null) return null;
    switch (map['status']) {
      case 'required':
        return const HistoryMigrationStatus(HistoryMigrationPhase.required);
      case 'completed':
        return const HistoryMigrationStatus(HistoryMigrationPhase.completed);
      case 'running':
        final progress = map['progress'];
        int? number(Object? value) => value is num ? value.toInt() : null;
        return HistoryMigrationStatus(
          HistoryMigrationPhase.running,
          label: progress is Map ? progress['label']?.toString() : null,
          done: progress is Map ? number(progress['numerator']) : null,
          total: progress is Map ? number(progress['denominator']) : null,
        );
      case 'error':
        final error = map['error'];
        return HistoryMigrationStatus(
          HistoryMigrationPhase.error,
          error: error == null
              ? null
              : error is String
              ? error
              : error.toString(),
        );
    }
    return null;
  }
}

/// A server that can report [HistoryMigrationStatus] (OpenCode 2 only).
abstract interface class HistoryMigrationGateway {
  Future<HistoryMigrationStatus?> historyMigrationStatus();
}
