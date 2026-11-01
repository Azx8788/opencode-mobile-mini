import '../../domain/termux_migration.dart';

/// Per-item bounds shared by migration review and start. The archive bound
/// includes conservative tar headers; the disk budget also allows allocation
/// overhead and three simultaneously retained copies across both sandboxes.
const migrationMaxArchiveBytes = 512 * 1024 * 1024;
const migrationMaxEntries = 20000;
const migrationReserveBytes = 64 * 1024 * 1024;

class TermuxMigrationSpace {
  const TermuxMigrationSpace({
    required this.requiredBytes,
    required this.availableBytes,
    required this.appAvailableBytes,
    required this.sourceAvailableBytes,
    required this.sufficient,
  });

  final int? requiredBytes;

  /// The lower of the two free-space readings, or null if either is unknown.
  final int? availableBytes;
  final int? appAvailableBytes;
  final int? sourceAvailableBytes;

  /// Null means the capacity could not be established, never permission to
  /// start. An empty selection requires zero bytes but is not a valid start.
  final bool? sufficient;
}

/// Computes the exact selected-item preflight used by both review and start.
/// A refused selected item keeps its typed refusal; it is never counted as a
/// zero-byte success. Malformed or missing selections fail with a fixed code.
/// Negative free-space readings are unknown, not measured zero bytes.
TermuxMigrationSpace migrationSpaceFor(
  TermuxMigrationSource source,
  Set<TermuxMigrationItem> selected,
  int? appAvailableBytes,
) {
  final byItem = <TermuxMigrationItem, TermuxMigrationSize>{};
  for (final item in source.items) {
    if (byItem.containsKey(item.item) || item.bytes < 0 || item.files < 0) {
      throw const TermuxMigrationException(
        TermuxMigrationFailure.invalidSelection,
      );
    }
    byItem[item.item] = item;
  }
  var total = 0;
  for (final item in selected) {
    final size = byItem[item];
    if (size == null) {
      throw const TermuxMigrationException(
        TermuxMigrationFailure.invalidSelection,
      );
    }
    if (size.problem != null) throw TermuxMigrationException(size.problem!);
    if (size.bytes > migrationMaxArchiveBytes ||
        size.files > migrationMaxEntries ||
        size.bytes + size.files * 1024 + 10240 > migrationMaxArchiveBytes) {
      throw const TermuxMigrationException(TermuxMigrationFailure.tooLarge);
    }
    total += size.bytes + size.files * 4096 + 10240;
  }
  final requiredBytes = selected.isEmpty
      ? 0
      : 3 * total + migrationReserveBytes;
  final appFree = appAvailableBytes != null && appAvailableBytes >= 0
      ? appAvailableBytes
      : null;
  final sourceFree = source.freeBytes >= 0 ? source.freeBytes : null;
  final available = appFree == null || sourceFree == null
      ? null
      : (appFree < sourceFree ? appFree : sourceFree);
  return TermuxMigrationSpace(
    requiredBytes: requiredBytes,
    availableBytes: available,
    appAvailableBytes: appFree,
    sourceAvailableBytes: sourceFree,
    sufficient: available == null ? null : available >= requiredBytes,
  );
}
