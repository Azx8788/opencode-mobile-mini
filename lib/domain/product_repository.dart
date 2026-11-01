import 'server_gateway.dart';
import 'models.dart';
import 'mcp_oauth.dart';

export 'server_gateway.dart' hide LiveEventChannel, StreamStatus;

final RegExp _exactSemanticVersion = RegExp(
  r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
  r'(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?'
  r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
);

bool isExactServerVersion(String value) =>
    value.isNotEmpty && _exactSemanticVersion.hasMatch(value);

abstract class ProductRepository implements ServerOperationsGateway {
  @override
  Future<ManagedShell> startManagedShell({
    required String command,
    required String directory,
    required String ownerToken,
  }) => Future.error(const ProductException('Service control is unavailable'));

  @override
  Future<ManagedShellList> loadRunningShells() async =>
      const ManagedShellList(supported: false);

  @override
  Future<ManagedShell?> getManagedShell(String id) async => null;

  @override
  Future<String?> managedShellServerIdentity() async => null;

  @override
  Future<ManagedShellOutput> readManagedShellOutput(
    String id, {
    required int cursor,
    int limit = 65536,
  }) => Future.error(const ProductException('Shell management is unavailable'));

  @override
  Future<void> stopManagedShell(String id) =>
      Future.error(const ProductException('Shell management is unavailable'));

  @override
  Future<ManagedShell> setManagedShellTimeout(String id, Duration? timeout) =>
      Future.error(const ProductException('Shell management is unavailable'));

  @override
  Future<BackgroundWorkSupport> loadBackgroundWorkSupport() async =>
      BackgroundWorkSupport.unavailable;

  @override
  Future<BackgroundWorkResult> backgroundSession(String sessionID) =>
      Future.error(
        const ProductException('Background work is unavailable on this server'),
      );

  @override
  void setLocation({String? directory, String? workspace});
  @override
  Future<String> upgradeServer(String target) => Future.error(
    const ProductException(
      'Remote OpenCode upgrade is unavailable on this server',
    ),
  );
  @override
  Future<void> writeClientLog({
    required String message,
    Map<String, Object?> extra = const {},
  }) => Future.error(
    const ProductException(
      'Sending app diagnostics is unavailable on this server',
    ),
  );
  @override
  Future<List<WorkspaceProject>> listProjects();
  @override
  Future<WorkspaceProject> renameProject({
    required String projectID,
    required String projectDirectory,
    required String name,
  }) => Future.error(
    const ProductException('Project renaming is unavailable on this server'),
  );
  @override
  Future<WorkspaceProject?> loadCurrentProject() async => null;
  @override
  Future<List<WorktreeInfo>> listWorktrees({
    required String projectDirectory,
    String? projectID,
  }) => Future.error(
    const ProductException('Worktree management is unavailable on this server'),
  );
  @override
  Future<WorktreeInfo> createWorktree({
    required String projectDirectory,
    String? name,
  }) => Future.error(
    const ProductException('Worktree management is unavailable on this server'),
  );
  @override
  Future<List<VersionControlFile>> listWorktreeFileStatuses(String directory) =>
      Future.error(
        const ProductException('Worktree status is unavailable on this server'),
      );
  @override
  Future<void> resetWorktree({
    required String projectDirectory,
    required String directory,
  }) => Future.error(
    const ProductException('Worktree management is unavailable on this server'),
  );
  @override
  Future<void> removeWorktree({
    required String projectDirectory,
    required String directory,
  }) => Future.error(
    const ProductException('Worktree management is unavailable on this server'),
  );
  @override
  Future<List<WorkspaceInfo>> listWorkspaces();
  @override
  Future<List<WorkspaceInfo>> listManagedWorkspaces({
    required String projectDirectory,
  }) => listWorkspaces();
  @override
  Future<List<WorkspaceAdapterInfo>> listWorkspaceAdapters({
    required String projectDirectory,
  }) => Future.error(
    const ProductException(
      'Workspace management is unavailable on this server',
    ),
  );
  @override
  Future<void> syncWorkspaceList({required String projectDirectory}) =>
      Future.error(
        const ProductException(
          'Workspace discovery is unavailable on this server',
        ),
      );
  @override
  Future<WorkspaceInfo> createManagedWorkspace({
    required String projectDirectory,
    required String type,
    String? branch,
  }) => Future.error(
    const ProductException('Workspace creation is unavailable on this server'),
  );
  @override
  Future<void> removeManagedWorkspace({
    required String projectDirectory,
    required String id,
  }) => Future.error(
    const ProductException('Workspace removal is unavailable on this server'),
  );
  @override
  Future<ServerPage<GlobalSessionResult>> listGlobalSessions({
    String? search,
    bool includeArchived = false,
    String? cursor,
    int limit = 50,
  }) => Future.error(
    const ProductException(
      'All-project session search is unavailable on this server',
    ),
  );
  @override
  Future<Session> getSessionDetails(String id) => Future.error(
    const ProductException('Session navigation is unavailable on this server'),
  );
  @override
  Future<List<Session>> listSessionChildren(String id) => Future.error(
    const ProductException('Subagent sessions are unavailable on this server'),
  );
  @override
  Future<List<ProjectDirectoryInfo>> listProjectDirectories(String projectID) =>
      Future.error(
        const ProductException(
          'Project directory discovery is unavailable on this server',
        ),
      );
  @override
  Future<void> moveSession(
    String sessionID, {
    required String directory,
    required bool moveChanges,
  }) => Future.error(
    const ProductException('Moving sessions is unavailable on this server'),
  );
  @override
  Future<void> warpSession(
    String sessionID, {
    required String? workspaceID,
    required bool copyChanges,
  }) => Future.error(
    const ProductException('Workspace warp is unavailable on this server'),
  );

  /// Asks the server to start its sync loops for workspaces in the current
  /// project that have active sessions. Returns the server's own boolean.
  @override
  Future<bool> startWorkspaceSync() => Future.error(
    const ProductException('Workspace sync is unavailable on this server'),
  );

  /// Reassigns [sessionID] to the currently selected workspace through the
  /// server's sync event system and returns the server-confirmed session ID.
  @override
  Future<String> stealSessionIntoWorkspace(String sessionID) => Future.error(
    const ProductException('Session steal is unavailable on this server'),
  );
  @override
  Future<List<ConsoleOrganization>> listConsoleOrganizations() => Future.error(
    const ProductException(
      'Organization switching is unavailable on this server',
    ),
  );
  @override
  Future<void> switchConsoleOrganization(ConsoleOrganization organization) =>
      Future.error(
        const ProductException(
          'Organization switching is unavailable on this server',
        ),
      );
  @override
  Future<void> addSessionLocationReminder(String sessionID, String directory) =>
      Future.value();
  @override
  Future<VersionControlHealth> loadVersionControlHealth();
  @override
  Future<void> initializeGitRepository() => Future.error(
    const ProductException('Git initialization is unavailable on this server'),
  );
  @override
  Future<List<VersionControlFile>> listFileStatuses();
  @override
  Future<List<LanguageServiceHealth>> listLanguageServices();
  @override
  Future<List<FormatterHealth>> listFormatters();
  @override
  Future<List<WorkspaceSymbol>> findWorkspaceSymbols(String query);
  @override
  Future<List<TerminalProcess>> listTerminals();
  @override
  Future<TerminalShellSettings> loadTerminalShellSettings() => Future.error(
    const ProductException('Shell settings are unavailable on this server'),
  );
  @override
  Future<void> selectTerminalShell(String value) => Future.error(
    const ProductException('Shell settings are unavailable on this server'),
  );
  @override
  Future<TerminalProcess> createTerminal({String? title});
  @override
  Future<void> renameTerminal(String id, String title);
  @override
  Future<void> resizeTerminal(
    String id, {
    required int rows,
    required int cols,
  });
  @override
  Future<void> removeTerminal(String id);
  @override
  Future<TerminalChannel> connectTerminal(String id, {int? cursor});
  @override
  Future<List<FileDiff>> listVcsDiffs(VcsDiffMode mode);
  @override
  Future<CatalogSnapshot> loadCatalog();
  @override
  Future<ExperimentalServerCapabilities> loadExperimentalCapabilities() =>
      Future.error(
        const ProductException(
          'Experimental capability discovery is unavailable on this server',
        ),
      );
  @override
  Future<List<String>> listCodingToolIDs() => Future.error(
    const ProductException('Tool discovery is unavailable on this server'),
  );
  @override
  Future<List<CodingToolInfo>> listCodingTools({
    required String providerID,
    required String modelID,
  }) => Future.error(
    const ProductException('Tool discovery is unavailable on this server'),
  );
  @override
  Future<ChatDefaults> loadChatDefaults() async => const ChatDefaults();
  @override
  Future<List<McpServerInfo>> listMcpServers();
  @override
  Future<List<McpResourceInfo>> listMcpResources();
  @override
  Future<void> connectMcp(String name);
  @override
  Future<void> disconnectMcp(String name);
  @override
  Future<McpAuthLaunch> startMcpAuthentication(String name);
  @override
  Future<McpServerInfo> completeMcpAuthentication(String name, String code) =>
      Future.error(
        const ProductException(
          'Completing MCP authentication is unavailable on this server',
        ),
      );
  @override
  Future<void> cancelMcpAuthentication(String name) => Future.error(
    const ProductException(
      'Cancelling MCP authentication is unavailable on this server',
    ),
  );
  @override
  Future<void> addMcpServer(
    McpServerDraft draft, {
    required McpConfigScope scope,
  }) => Future.error(
    const ProductException(
      'Persistent MCP setup is unavailable on this server',
    ),
  );
  @override
  Future<List<IntegrationInfo>> listIntegrations();
  @override
  Future<void> connectIntegrationKey(String id, String key, {String? label});
  @override
  Future<void> disconnectIntegration(IntegrationInfo integration);
  @override
  Future<void> refreshProviderRuntime();
  @override
  Future<IntegrationAuthLaunch> startIntegrationOAuth(
    String id,
    String methodID, {
    Map<String, String> inputs,
    String? label,
  });
  @override
  Future<IntegrationAuthStatus> integrationOAuthStatus(String attemptID);
  @override
  Future<void> completeIntegrationOAuth(String attemptID, {String? code});
  @override
  Future<void> cancelIntegrationOAuth(String attemptID);
  @override
  Future<List<CommandInfo>> listCommands();
  @override
  Future<List<SkillInfo>> listSkills();
  @override
  Future<List<ReferenceInfo>> listReferences();
  @override
  Future<List<PendingQuestion>> listQuestions();
  @override
  Future<List<SavedPermission>> listSavedPermissions() => Future.error(
    const ProductException(
      'Saved permission management is unavailable on this server',
    ),
  );
  @override
  Future<void> removeSavedPermission(String id) => Future.error(
    const ProductException(
      'Saved permission management is unavailable on this server',
    ),
  );
  @override
  Future<void> answerQuestion(String id, List<List<String>> answers);
  @override
  Future<void> rejectQuestion(String id);
  @override
  Future<String?> shareSession(String id);
  @override
  Future<void> unshareSession(String id);
  @override
  Future<void> archiveSession(String id);
  @override
  Future<String> forkSession(String id, {String? messageID});

  /// Permanently removes one message and all of its parts from the session's
  /// stored conversation, so future replies no longer see it. File changes
  /// that message made are not reverted.
  @override
  Future<void> deleteMessage({
    required String sessionID,
    required String messageID,
  }) => Future.error(
    const ProductException('Message deletion is unavailable on this server'),
  );

  @override
  Future<void> revertSession(String id, String messageID);
  @override
  Future<void> restoreSession(String id);
  @override
  Future<void> compactSession(
    String id, {
    required String providerID,
    required String modelID,
  });
}
