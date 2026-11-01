/// Where the Git page runs its commands, and how text reaches a shell safely.
///
/// The Git page never talks to Git directly: it writes one POSIX `sh` script
/// per action and hands it to whichever command bridge reaches the project
/// (Ubuntu inside the app, Termux's Ubuntu, or an OpenCode 2 server's
/// `POST /api/shell`). Every path, branch name and message reaches that script
/// through [shQuote], never as bare text.
library;

/// Runs one POSIX `sh` script where the project lives and returns what it
/// printed (stdout, and stderr where the bridge merges them).
///
/// Implementations: `BuiltinGitShell` (lib/builtin/git_shell.dart),
/// `TermuxGitShell` (lib/termux/git_shell.dart) and `ServerGitShell`
/// (lib/state/git_workspace.dart, over a [RemoteShellGateway]).
abstract interface class GitShell {
  Future<String> run(String script, {required Duration timeout});
}

/// Why a bridge could not run the script at all (not a Git failure).
enum GitShellFailure {
  /// The bridge is not there or not ready (Ubuntu not installed, Termux not
  /// reachable, the server connection closed).
  unavailable,

  /// The server has no command endpoint (404 on `POST /api/shell`).
  unsupported,

  /// The script did not finish in time.
  timedOut,
}

class GitShellException implements Exception {
  const GitShellException(this.failure, {this.details = ''});

  final GitShellFailure failure;

  /// The bridge's own description, for Details only.
  final String details;

  @override
  String toString() => 'GitShellException(${failure.name})';
}

/// [value] as one single-quoted `sh` word: `it's` becomes `'it'\''s'`.
///
/// Single quotes stop every expansion (`$`, backticks, `\`, globbing), so the
/// only character needing care is the quote itself. A NUL byte cannot be
/// carried by any shell word and is refused.
String shQuote(String value) {
  if (value.contains('\x00')) {
    throw ArgumentError.value('<redacted>', 'value', 'contains a NUL byte');
  }
  return "'${value.replaceAll("'", r"'\''")}'";
}

/// [argv] as one `sh` command line, every word quoted.
String shCommand(List<String> argv) => argv.map(shQuote).join(' ');
