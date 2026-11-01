import '../ui/kit/kit_redact.dart';
import 'server_gateway.dart';

/// SV3 MCP action availability derived from current server contracts.
///
/// Import this extension beside [ServerCapabilities] when deciding whether to
/// offer these actions. Existing runtime add/remove and OAuth flags must not be
/// used as evidence for deletion, undo, or expiry guarantees. No server flavor
/// checks are needed, and unsupported operations have no mutation API.
extension Sv3McpCapabilities on ServerCapabilities {
  /// Whether MCP inventory and runtime connection controls are available.
  ///
  /// Disconnecting stops the current connection. It does not change persistent
  /// configuration, remove the server, or promise to survive a server restart.
  bool get mcpRuntimeDisconnect => serverCatalog;

  /// Whether a named MCP entry can be deleted from persistent configuration.
  ///
  /// Configuration patching does not define key deletion in OpenCode 1, and
  /// OpenCode 2 runtime removal does not change configuration files.
  bool get mcpConfigDeletion => false;

  /// Whether runtime Remove can be undone with the exact prior configuration.
  ///
  /// Runtime add exists, but inventory does not expose the prior runtime
  /// configuration and Remove returns no server-owned restoration handle.
  /// Reconstructing a server from its name and status would lose configuration.
  bool get mcpRuntimeRemovalUndo => false;

  /// Whether the server distinguishes an expired established OAuth credential.
  ///
  /// `needs_auth` is not proof of expiry. An integration authentication attempt
  /// expiring also says nothing about an established MCP credential's lifetime.
  bool get mcpOAuthTokenExpiry => false;

  /// Whether expiry-triggered reconnection is supported by a server contract.
  ///
  /// A connect endpoint alone supplies neither a token-expiry signal nor an
  /// unattended refresh guarantee. Do not schedule reconnects from guessed TTLs.
  bool get mcpExpiryAutoReconnect => false;
}

/// Stable failure reasons for runtime disconnection; contains no server text.
enum Sv3McpRuntimeFailure { unavailable, invalidName, requestFailed }

/// A safe error that can be mapped to localized UI copy by [reason].
final class Sv3McpRuntimeException implements Exception {
  final Sv3McpRuntimeFailure reason;

  const Sv3McpRuntimeException(this.reason);

  @override
  String toString() => 'MCP runtime disconnect: ${reason.name}';
}

/// SV3 runtime-only MCP controls using the existing domain gateway.
extension Sv3McpRuntimeActions on McpGateway {
  /// Disconnects [name] for the current server/location without deleting it.
  ///
  /// Uses the existing authenticated gateway. Success acknowledges the command;
  /// callers must refetch [McpGateway.listMcpServers] before showing a status.
  /// No configuration or credentials are persisted, and raw gateway errors are
  /// not exposed. A lost response may mean the operation happened server-side;
  /// refetch before retrying after [Sv3McpRuntimeFailure.requestFailed].
  Future<void> disconnectMcpRuntime(
    String name, {
    required ServerCapabilities capabilities,
  }) async {
    if (!capabilities.mcpRuntimeDisconnect) {
      throw const Sv3McpRuntimeException(Sv3McpRuntimeFailure.unavailable);
    }
    if (name.trim().isEmpty ||
        name != name.trim() ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name) ||
        KitRedact.containsSecret(name)) {
      throw const Sv3McpRuntimeException(Sv3McpRuntimeFailure.invalidName);
    }
    try {
      await disconnectMcp(name);
    } catch (_) {
      throw const Sv3McpRuntimeException(Sv3McpRuntimeFailure.requestFailed);
    }
  }
}
