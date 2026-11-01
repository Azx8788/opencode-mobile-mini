import 'server_gateway.dart';

/// Persistent configuration scope. Runtime disconnect is a separate MCP action.
enum CodingToolConfigScope { project, global }

enum ToolConfigurationError {
  unavailable,
  invalidToolID,
  invalidMcpServer,
  projectRequired,
  requestFailed,
}

/// A safe failure that never retains a transport exception or response config.
class ToolConfigurationException implements Exception {
  final ToolConfigurationError code;

  const ToolConfigurationException(this.code);

  @override
  String toString() => switch (code) {
    ToolConfigurationError.unavailable =>
      'This configuration change is unavailable on this server',
    ToolConfigurationError.invalidToolID => 'Choose a valid tool',
    ToolConfigurationError.invalidMcpServer => 'Choose a valid MCP server',
    ToolConfigurationError.projectRequired =>
      'Select a project before changing project configuration',
    ToolConfigurationError.requestFailed => 'Could not update configuration',
  };
}

/// Optional companion gateway for persistent individual-tool configuration.
///
/// Obtain tool IDs from [CatalogGateway.listCodingTools]. A successful write
/// means the server accepted the configuration, not that a running turn stopped.
/// Do not infer MCP provenance or an effective enabled state from a tool ID.
/// A request failure can follow a committed write: refresh before offering a
/// manual retry, and never automatically retry or flip the local state.
abstract interface class ToolConfigurationGateway {
  Future<void> setCodingToolEnabled(
    String toolID,
    bool enabled, {
    required CodingToolConfigScope scope,
  });
}

/// Optional persistent MCP enablement, distinct from runtime disconnect.
/// Success acknowledges config acceptance, not effective runtime enablement.
/// Refresh inventory after success or an ambiguous failure; never auto-retry.
abstract interface class McpConfigurationGateway {
  Future<void> setMcpServerEnabled(
    String name,
    bool enabled, {
    required CodingToolConfigScope scope,
  });
}

/// SV3 companion capability gates; importing this file adds no server support.
extension Sv3ToolCapabilities on ServerCapabilities {
  bool canConfigureCodingTools({ToolConfigurationGateway? gateway}) =>
      toolInventory && mcpConfigWrites && gateway != null;

  bool canConfigureMcpEnablement({McpConfigurationGateway? gateway}) =>
      serverCatalog && mcpConfigWrites && gateway != null;

  /// Neither current tool catalog reports authoritative MCP provenance.
  bool get codingToolSourceMcp => false;

  /// The tool catalog does not report effective enablement after overrides.
  bool get codingToolEnabledState => false;
}
