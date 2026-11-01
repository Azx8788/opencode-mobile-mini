import 'server_gateway.dart';

export 'server_gateway.dart' show WorkspaceProject;

/// Additive environment/project gates for the SV2 backend slice.
///
/// Import this library alongside the gateway to use these getters. No getter
/// infers support from the protocol flavor or substitutes destructive removal
/// for stopping an environment.
extension EnvironmentProjectCapabilities on ServerCapabilities {
  /// Project lists expose server `time.updated`, allowing an explicit
  /// "Recently updated" order. This does not mean recently opened or used.
  bool get projectsByLatestUpdate => projectManagement;

  /// Neither supported contract provides a last-opened timestamp or an
  /// authoritative recent-use order for projects.
  bool get projectsByRecentUse => false;

  /// Workspace status has no attributable, refetchable error reason.
  /// A `workspace.failed` message alone cannot identify an environment row.
  bool get environmentErrorReason => false;

  /// Workspace deletion destroys/removes the workspace; it is not a stop call.
  bool get environmentStop => false;

  /// Neither supported project API offers repository cloning.
  bool get repositoryClone => false;
}

/// Project reads that use the existing authenticated operations gateway.
extension EnvironmentProjectOperations on ServerOperationsGateway {
  /// Loads projects ordered by their server-reported update time, newest first.
  ///
  /// Pass the capabilities of the same connected server as this gateway. An
  /// unsupported call fails before requesting projects. Unknown timestamps
  /// (zero or negative) appear last; ties preserve the server's input order.
  /// The returned list is unmodifiable and the gateway's list is not mutated.
  ///
  /// Use "Recently updated" in presentation copy. This cannot support a
  /// "Recently opened" label: neither current contract provides that truth.
  /// Fetch errors propagate to the caller; no old or fabricated list replaces
  /// a failed request. Nothing is persisted or logged.
  Future<List<WorkspaceProject>> loadProjectsByLatestUpdate({
    required ServerCapabilities capabilities,
  }) async {
    if (!capabilities.projectsByLatestUpdate) {
      throw UnsupportedError('Project update ordering is unavailable');
    }
    final projects = await listProjects();
    final indexed = projects.indexed.toList();
    indexed.sort((left, right) {
      final leftTime = left.$2.updatedAt > 0 ? left.$2.updatedAt : 0;
      final rightTime = right.$2.updatedAt > 0 ? right.$2.updatedAt : 0;
      final byTime = rightTime.compareTo(leftTime);
      return byTime != 0 ? byTime : left.$1.compareTo(right.$1);
    });
    return List<WorkspaceProject>.unmodifiable(
      indexed.map((entry) => entry.$2),
    );
  }
}
