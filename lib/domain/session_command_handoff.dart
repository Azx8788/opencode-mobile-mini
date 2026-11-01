/// Optional protocol facet: implemented only where the CLI attach syntax is
/// verified. It neither starts a process nor reads or copies a password.
abstract interface class SessionCommandHandoffGateway {
  SessionCommandHandoff createSessionCommandHandoff({
    required String sessionID,
    required String? directory,
    required String? workspaceID,
    required String username,
  });
}

enum SessionCommandUnavailable {
  unsafeAddress,
  localAddress,
  missingDirectory,
  unsupportedWorkspace,
  invalidReference,
}

class SessionCommandHandoff {
  final String? command;
  final SessionCommandUnavailable? unavailable;

  const SessionCommandHandoff._(this.command, this.unavailable);
  const SessionCommandHandoff.unavailable(SessionCommandUnavailable reason)
    : this._(null, reason);

  /// A command supplied by a gateway with verified CLI attach support.
  const SessionCommandHandoff.command(String this.command) : unavailable = null;
}
