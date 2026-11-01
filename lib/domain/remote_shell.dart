/// Running one non-interactive command on the connected server, outside any
/// conversation. Implemented by gateways whose [ServerCapabilities.remoteShell]
/// is true (OpenCode 2: `POST /api/shell`, docs/opencode2-protocol-notes.md
/// §10). Check the flag, then `gateway is RemoteShellGateway`.
library;

/// How a server command ended.
enum RemoteShellStatus { exited, timedOut, killed }

class RemoteShellResult {
  const RemoteShellResult({
    required this.status,
    required this.output,
    this.exitCode,
  });

  final RemoteShellStatus status;

  /// Combined stdout and stderr, every page read.
  final String output;
  final int? exitCode;
}

/// Why a command could not run at all.
enum RemoteShellFailure {
  /// The server has no command endpoint.
  unsupported,

  /// The request failed (connection, auth, server error).
  failed,
}

class RemoteShellException implements Exception {
  const RemoteShellException(this.failure);

  final RemoteShellFailure failure;

  /// Deliberately no server text: it may echo the command.
  @override
  String toString() => 'RemoteShellException(${failure.name})';
}

abstract interface class RemoteShellGateway {
  /// Runs [command] with the server's shell in [directory] (the gateway's
  /// project when null), waits for it to end, reads all output, then asks the
  /// server to drop what it kept. The command never appears in a
  /// conversation transcript.
  Future<RemoteShellResult> runShellCommand(
    String command, {
    String? directory,
    required Duration timeout,
  });
}
