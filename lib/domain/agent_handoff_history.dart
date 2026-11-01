import '../domain/models.dart';
import 'genui/gen_ui_history.dart';
import 'server_gateway/interfaces.dart';

/// A backend with a bounded, complete read-only transcript snapshot endpoint.
/// It must not resume a thread, start work or return a partial history as full.
abstract interface class AgentHandoffHistoryGateway {
  Future<List<MessageWithParts>> agentHandoffHistory(String sessionID);
}

enum AgentHandoffHistoryFailureKind {
  unsupported,
  staleScope,
  invalidSession,
  invalidMessage,
  invalidCursor,
  pageLimit,
  readFailed,
}

/// A content-free history error safe to record in diagnostics. Transport
/// exceptions and message/cursor values must not escape through this boundary.
final class AgentHandoffHistoryFailure implements Exception {
  final AgentHandoffHistoryFailureKind kind;

  const AgentHandoffHistoryFailure(this.kind);

  @override
  String toString() => 'AgentHandoffHistoryFailure(${kind.name})';
}

/// Reads a complete bounded source history or fails without returning a partial
/// result. The gateway's history contract provides oldest-first items within
/// each page and pages walking from the newest page toward older history. A
/// complete snapshot backend instead returns chronological messages in one
/// bounded response; the same `maxPages * 50` message budget applies.
/// Overlapping message IDs keep the copy from the newest page.
///
/// [isCurrent] must track the caller's profile/selection generation, including
/// changes away and back to the same selection. Directory and workspace are
/// additionally pinned here. The caller decides whether the source must be
/// idle; this reader does not interrupt or mutate a running conversation.
Future<List<MessageWithParts>> readAgentHandoffHistory(
  ServerGateway gateway,
  String sessionID, {
  required bool Function() isCurrent,
  int maxPages = 100,
}) async {
  if (maxPages <= 0) throw ArgumentError.value(maxPages, 'maxPages');
  if (sessionID.trim().isEmpty) {
    throw const AgentHandoffHistoryFailure(
      AgentHandoffHistoryFailureKind.invalidSession,
    );
  }
  if (gateway is! GenUiHistoryGateway &&
      gateway is! AgentHandoffHistoryGateway) {
    throw const AgentHandoffHistoryFailure(
      AgentHandoffHistoryFailureKind.unsupported,
    );
  }
  final directory = gateway.directory;
  final workspace = gateway.workspace;
  void checkCurrent() {
    if (!isCurrent() ||
        gateway.isClosed ||
        gateway.directory != directory ||
        gateway.workspace != workspace) {
      throw const AgentHandoffHistoryFailure(
        AgentHandoffHistoryFailureKind.staleScope,
      );
    }
  }

  if (gateway is AgentHandoffHistoryGateway) {
    checkCurrent();
    final List<MessageWithParts> snapshot;
    try {
      snapshot = await (gateway as AgentHandoffHistoryGateway)
          .agentHandoffHistory(sessionID);
    } catch (_) {
      checkCurrent();
      throw const AgentHandoffHistoryFailure(
        AgentHandoffHistoryFailureKind.readFailed,
      );
    }
    checkCurrent();
    if (snapshot.length > maxPages * 50) {
      throw const AgentHandoffHistoryFailure(
        AgentHandoffHistoryFailureKind.pageLimit,
      );
    }
    final ids = <String>{};
    for (final message in snapshot) {
      if (message.info.sessionID != sessionID ||
          message.info.id.trim().isEmpty ||
          !ids.add(message.info.id)) {
        throw const AgentHandoffHistoryFailure(
          AgentHandoffHistoryFailureKind.invalidMessage,
        );
      }
    }
    return List.unmodifiable(
      snapshot.map(
        (message) => MessageWithParts(
          info: message.info,
          parts: List.unmodifiable(message.parts),
        ),
      ),
    );
  }

  final history = gateway as GenUiHistoryGateway;
  final pages = <List<MessageWithParts>>[];
  final seenMessages = <String>{};
  final seenCursors = <String>{};
  String? cursor;
  for (var pageNumber = 0; pageNumber < maxPages; pageNumber++) {
    checkCurrent();
    final GenUiHistoryPage page;
    try {
      page = await history.genUiHistoryPage(
        sessionID,
        cursor: cursor,
        limit: 50,
      );
    } catch (_) {
      // Selection changes still have priority if a request failed in flight.
      checkCurrent();
      throw const AgentHandoffHistoryFailure(
        AgentHandoffHistoryFailureKind.readFailed,
      );
    }
    checkCurrent();

    final unique = <MessageWithParts>[];
    for (final message in page.items.reversed) {
      if (message.info.sessionID != sessionID ||
          message.info.id.trim().isEmpty) {
        throw const AgentHandoffHistoryFailure(
          AgentHandoffHistoryFailureKind.invalidMessage,
        );
      }
      if (seenMessages.add(message.info.id)) {
        // Freeze the mutable parts list so a later stream update cannot change
        // the snapshot while another page is being awaited.
        unique.add(
          MessageWithParts(
            info: message.info,
            parts: List.unmodifiable(message.parts),
          ),
        );
      }
    }
    pages.add(unique.reversed.toList(growable: false));
    if (!page.hasMore) {
      return List.unmodifiable(pages.reversed.expand((items) => items));
    }
    final next = page.olderCursor;
    if (next == null || next.trim().isEmpty || !seenCursors.add(next)) {
      throw const AgentHandoffHistoryFailure(
        AgentHandoffHistoryFailureKind.invalidCursor,
      );
    }
    cursor = next;
  }
  throw const AgentHandoffHistoryFailure(
    AgentHandoffHistoryFailureKind.pageLimit,
  );
}
