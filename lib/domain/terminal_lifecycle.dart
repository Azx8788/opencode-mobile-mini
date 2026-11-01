import 'server_gateway.dart';

/// Optional gateway facet for rerunning a PTY's reported executable, arguments,
/// working directory and title in a NEW PTY. The ended PTY is retained.
///
/// The server's default environment is used: the wire response does not expose
/// the original environment or commands typed into an interactive shell. This
/// API does not restore either. Nothing is persisted or logged.
abstract interface class TerminalCommandGateway {
  Future<TerminalProcess> rerunTerminalCommand(TerminalProcess ended);
}

/// The title the app gives its one-shot usage check terminal. Terminal lists
/// leave terminals with this title out: they are not the person's.
const computerUsageTitle = 'OpenCode Mini usage check';

/// Optional gateway facet: runs one command in a NEW PTY on the server and
/// hands back the terminal so a caller can read its output and remove it.
/// Used by the computer usage check. Nothing is persisted or logged, and a
/// failure carries no command text.
abstract interface class OneShotCommandGateway {
  /// Starts [command] with [arguments] (never joined into a shell line).
  Future<TerminalProcess> createCommandTerminal({
    required String command,
    required List<String> arguments,
    String? title,
  });
}

/// Capability checks for the additive terminal lifecycle facet. An unwired
/// facet is unavailable; these checks never infer a protocol from its flavor.
extension TerminalLifecycleCapabilities on ServerCapabilities {
  bool supportsTerminalCommandRerun(TerminalCommandGateway? gateway) =>
      terminal && gateway != null;

  /// Neither pinned PTY contract reports the process start timestamp.
  bool get terminalAge => false;

  /// Shell.Info has no effective deadline, including after a timeout update.
  bool get externalCommandTimeLeft => false;
}

/// Validates and snapshots the reported process before a rerun request. This
/// rejects active processes and missing executable/cwd; it never synthesizes
/// shell commands or reads credentials. Arguments are passed without joining.
TerminalProcess terminalRerunSnapshot(TerminalProcess ended) {
  if (ended.running ||
      ended.command.trim().isEmpty ||
      ended.directory.trim().isEmpty ||
      [
        ended.command,
        ended.directory,
        ...ended.arguments,
      ].any((value) => value.contains('\u0000'))) {
    throw const ProductException('This terminal command cannot be rerun.');
  }
  return TerminalProcess(
    id: ended.id,
    title: ended.title,
    command: ended.command,
    arguments: List.unmodifiable(ended.arguments),
    directory: ended.directory,
    running: false,
    pid: ended.pid,
    exitCode: ended.exitCode,
  );
}
