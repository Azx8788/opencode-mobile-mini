import '../domain/models.dart';
import 'server_gateway.dart';

/// A point-in-time count for the exact reviewed staged boundary.
/// Not a commit authorization or a server-atomic deletion preview.
class StagedRevertMessageCount {
  const StagedRevertMessageCount._(this.messagesAfterPrompt);

  /// N in "The hidden prompt and N messages after it are deleted".
  /// Counts every projected message kind, including synthetic/system rows.
  final int messagesAfterPrompt;

  /// Includes the hidden user prompt itself.
  int get totalMessages => messagesAfterPrompt + 1;
}

/// Safe failure categories; never retain remote error bodies or message text.
enum StagedRevertCountFailure { unavailable, stale, incomplete, failed }

/// A failed count is unknown, never zero. Map [kind] to localized UI copy.
class StagedRevertCountException implements Exception {
  const StagedRevertCountException(this.kind);
  final StagedRevertCountFailure kind;
}

/// SV1 additive read API; keeps the single-owner ServerGateway untouched.
extension StagedRevertMessageCountGateway on ServerGateway {
  /// Whether this connection can review staged history, without flavor checks.
  bool canCountStagedRevertMessages(Object? operations) =>
      capabilities.sessionRevert && operations is StagedRevertGateway;

  /// Reads newest-to-oldest pages until [expected]'s user prompt is found.
  /// [isCurrent] must cover the review's profile/location/history revision AND
  /// the caller's lifetime. Checked before and after each asynchronous read.
  /// Cursor loops, missing boundaries and bounded-read exhaustion fail closed.
  /// The result is memory-only; invalidate it on history changes/reconnect and
  /// retain the existing controller's commit preflight and confirmation flow.
  Future<StagedRevertMessageCount> countStagedRevertMessages(
    String sessionID, {
    required SessionRevert expected,
    required Object? operations,
    required bool Function() isCurrent,
    int maxPages = 100,
  }) async {
    if (!canCountStagedRevertMessages(operations)) {
      throw const StagedRevertCountException(
        StagedRevertCountFailure.unavailable,
      );
    }
    if (maxPages < 1) throw ArgumentError.value(maxPages, 'maxPages');
    void checkCurrent() {
      if (isClosed || !isCurrent()) {
        throw const StagedRevertCountException(StagedRevertCountFailure.stale);
      }
    }

    Future<void> checkBoundary() async {
      checkCurrent();
      final current = await session(sessionID);
      checkCurrent();
      if (current.id != sessionID ||
          current.stagedRevert?.fingerprint != expected.fingerprint) {
        throw const StagedRevertCountException(StagedRevertCountFailure.stale);
      }
    }

    try {
      if (expected.partID != null || expected.messageID.isEmpty) {
        throw const StagedRevertCountException(
          StagedRevertCountFailure.incomplete,
        );
      }
      await checkBoundary();
      // Some protocols project synthetic/system rows as role 'user'. Verify
      // the raw boundary kind through the existing staged-revert operation.
      final prompt = await (operations as StagedRevertGateway)
          .sessionRevertPrompt(sessionID, expected.messageID);
      checkCurrent();
      if (prompt == null) {
        throw const StagedRevertCountException(
          StagedRevertCountFailure.incomplete,
        );
      }
      final seen = <String>{};
      final cursors = <String>{};
      String? cursor;
      var after = 0;
      for (var pageIndex = 0; pageIndex < maxPages; pageIndex++) {
        checkCurrent();
        final page = await messagePage(sessionID, cursor: cursor);
        checkCurrent();
        // Each gateway page is chronological; continuation requests older rows.
        for (final row in page.items.reversed) {
          final info = row.info;
          if (info.sessionID != sessionID || info.id.isEmpty) {
            throw const StagedRevertCountException(
              StagedRevertCountFailure.incomplete,
            );
          }
          if (!seen.add(info.id)) continue;
          if (info.id == expected.messageID) {
            if (info.role != 'user') {
              throw const StagedRevertCountException(
                StagedRevertCountFailure.incomplete,
              );
            }
            await checkBoundary();
            return StagedRevertMessageCount._(after);
          }
          after++;
        }
        if (!page.hasMore || !cursors.add(page.nextCursor!)) break;
        cursor = page.nextCursor;
      }
      throw const StagedRevertCountException(
        StagedRevertCountFailure.incomplete,
      );
    } on StagedRevertCountException {
      rethrow;
    } catch (_) {
      // Transport exceptions may contain credentials or transcript content.
      throw const StagedRevertCountException(StagedRevertCountFailure.failed);
    }
  }
}
