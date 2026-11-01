/// Backend contract for a foreground, owner-started Termux migration.
/// Values exposed to UI contain no command output, file content or credentials.
enum TermuxMigrationPhase {
  checking,
  ready,
  needsSpace,
  needsBuiltin,
  termuxUnreachable,
  packing,
  copying,
  unpacking,
  verifying,
  switching,
  done,
  failed,
  cancelled,
}

enum TermuxMigrationFailure {
  unavailable,
  sourceChanged,
  sourceBusy,
  unsupportedEntry,
  linkedFileUnreadable,
  tooLarge,
  invalidArchive,
  checksumMismatch,
  destinationConflict,
  storage,
  timedOut,
  invalidSelection,
  profileSwitch,
  cancelled,
}

enum TermuxMigrationItem {
  projects,
  config,
  sessions,
  gitConfig,
  shellFiles,
  aiTeam,
}

enum TermuxMigrationDisposition { migrate, privateExport }

class TermuxMigrationSize {
  const TermuxMigrationSize(this.item, this.bytes, this.files, {this.problem});
  final TermuxMigrationItem item;
  final int bytes;
  final int files;

  /// A refused item has unknown size; never present its placeholder zero as measured.
  final TermuxMigrationFailure? problem;
  TermuxMigrationDisposition get disposition =>
      item == TermuxMigrationItem.projects
      ? TermuxMigrationDisposition.migrate
      : TermuxMigrationDisposition.privateExport;
}

class TermuxMigrationSource {
  const TermuxMigrationSource({
    required this.items,
    required this.freeBytes,
    this.oc1Version,
    this.oc2Version,
    this.oc2Isolated = false,
  });
  final List<TermuxMigrationSize> items;
  final int freeBytes;
  final String? oc1Version;
  final String? oc2Version;
  final bool oc2Isolated;
}

class TermuxMigrationArchive {
  const TermuxMigrationArchive({required this.bytes, required this.sha256});
  final int bytes;
  final String sha256;
}

class TermuxMigrationException implements Exception {
  const TermuxMigrationException(this.code);
  final TermuxMigrationFailure code;
  @override
  String toString() => 'TermuxMigrationException(${code.name})';
}

class TermuxMigrationSnapshot {
  const TermuxMigrationSnapshot({
    required this.phase,
    this.failure,
    this.jobId,
    this.item,
    this.source,
    this.requiredBytes,
    this.availableBytes,
    this.destinationProfileId,
  });
  final TermuxMigrationPhase phase;
  final TermuxMigrationFailure? failure;
  final String? jobId;
  final TermuxMigrationItem? item;
  final TermuxMigrationSource? source;
  final int? requiredBytes;
  final int? availableBytes;
  final String? destinationProfileId;
}

/// A durable successful copy receipt; not evidence of current server health.
class TermuxMigrationCompletedJob {
  const TermuxMigrationCompletedJob({
    required this.jobId,
    required this.destinationProfileId,
  });
  final String jobId;
  final String destinationProfileId;
}

enum TermuxMigrationDiscardResult { discarded, nothingSaved, alreadyCompleted }
