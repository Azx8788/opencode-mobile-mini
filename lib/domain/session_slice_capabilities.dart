import 'server_gateway.dart';

/// SV1 session capabilities, separate from the single-owner gateway library.
/// Import this extension wherever these unavailable actions are presented.
extension SessionSliceCapabilities on ServerCapabilities {
  /// Neither pinned server exposes a contract-proven archive clear operation.
  bool get sessionUnarchive => false;

  /// Server primitives exist, but the gateway has no summary-seed operation.
  bool get sessionSummarySeed => false;

  /// Fork and move are separate writes, not a transactional copy to a location.
  bool get sessionCopyToDestination => false;

  /// No move response exposes destination file conflicts.
  bool get sessionMoveConflictDetails => false;
}
