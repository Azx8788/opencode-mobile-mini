import 'server_gateway.dart';

/// Read-only worktree capabilities, derived from existing gateway contracts.
///
/// Kept outside the single-owner gateway declaration so UI builders can import
/// this API without changing it. These flags describe the connected server;
/// individual reads can still fail and must never be presented as clean/empty.
extension WorktreeInspectionCapabilities on ServerCapabilities {
  /// Per-directory uncommitted file status is implemented by project gateways.
  bool get worktreeUncommittedChanges => projectManagement;

  /// Root conversations can be associated with copies from paged session data.
  bool get worktreeConversations => projectManagement && globalSessionSearch;

  /// Neither supported server contract offers a merge-copy-back operation.
  bool get worktreeMerge => false;
}

/// On-demand reads for one copy, using the existing domain gateway only.
///
/// Create a new instance after switching server/profile. This service does not
/// mutate the gateway's active location, cache data, persist paths or log errors.
/// UI callers own loading/error states and discard results after switching scope.
class WorktreeInspection {
  const WorktreeInspection({
    required HostGateway gateway,
    required this.capabilities,
  }) : _gateway = gateway;

  final HostGateway _gateway;

  /// Gate each action on the corresponding extension flag before displaying it.
  final ServerCapabilities capabilities;

  /// Fetch uncommitted changes in exactly [directory], without changing the
  /// currently selected copy. An empty successful response means clean at the
  /// time of the read; a thrown error means unknown, never clean.
  ///
  /// This inherits the gateway's current workspace. The selected copy must be
  /// in that workspace; this API cannot inspect a different workspace per row.
  Future<List<VersionControlFile>> loadChanges(String directory) async {
    if (!capabilities.worktreeUncommittedChanges) {
      throw UnsupportedError('Worktree changes are unavailable');
    }
    _requireNonEmpty(directory, 'directory');
    return List.unmodifiable(
      await _gateway.listWorktreeFileStatuses(directory),
    );
  }

  /// Read one server-wide page and retain root conversations whose server-owned
  /// directory, project and workspace exactly match this copy's scope.
  ///
  /// A null [workspaceID] means the host-local scope. Paths are never normalized
  /// or prefix-matched: `/copy` must not match `/copy-old`, nested directories,
  /// or another workspace with an identical path. Unknown metadata is excluded.
  /// Archived roots are included by default. The current gateways list roots,
  /// not every subagent, and association does not imply a conversation is active.
  ///
  /// The opaque continuation is preserved even if this page has no matches.
  /// Callers must offer/load subsequent pages before claiming there are no
  /// conversations or showing an exhaustive count. Pass [cursor] back unchanged
  /// with the same scope and [includeArchived]; do not sort or derive it.
  Future<ServerPage<Session>> conversationPage({
    required String directory,
    required String projectID,
    String? workspaceID,
    String? cursor,
    int limit = 50,
    bool includeArchived = true,
  }) async {
    if (!capabilities.worktreeConversations) {
      throw UnsupportedError('Worktree conversations are unavailable');
    }
    _requireNonEmpty(directory, 'directory');
    _requireNonEmpty(projectID, 'projectID');
    if (workspaceID != null) {
      _requireNonEmpty(workspaceID, 'workspaceID');
    }
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit', 'Must be positive');
    }
    final page = await _gateway.listGlobalSessions(
      includeArchived: includeArchived,
      cursor: cursor,
      limit: limit,
    );
    return ServerPage(
      items: List.unmodifiable([
        for (final result in page.items)
          if (result.session.directory == directory &&
              result.session.projectID == projectID &&
              result.session.workspaceID == workspaceID &&
              result.session.parentID == null)
            result.session,
      ]),
      nextCursor: page.nextCursor,
    );
  }

  static void _requireNonEmpty(String value, String name) {
    if (value.trim().isEmpty) {
      throw ArgumentError('$name must not be empty');
    }
  }
}
