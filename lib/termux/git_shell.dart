import '../domain/git/git_shell.dart';
import 'bridge.dart';

/// Runs one script in Termux (`bash -s`) and returns its result.
typedef TermuxGitRunner =
    Future<TermuxCommandResult> Function(String script, Duration timeout);

/// The Git page's commands in Termux's managed Ubuntu, where the Termux
/// server and its projects live (`proot-distro login opencode-ubuntu`).
///
/// The script travels in a Termux RUN_COMMAND intent, so it never carries a
/// secret: this shell has no [GitCredentialDrop], and pushes use whatever
/// sign-in Termux's Ubuntu already has.
class TermuxGitShell implements GitShell {
  TermuxGitShell({TermuxGitRunner? run}) : _run = run ?? _bridgeRun;

  final TermuxGitRunner _run;

  /// The managed Ubuntu's proot-distro name (lib/termux/termux_folders.dart).
  static const distro = 'opencode-ubuntu';

  static Future<TermuxCommandResult> _bridgeRun(
    String script,
    Duration timeout,
  ) => TermuxBridge.run(script, timeout: timeout);

  /// [script] wrapped to run inside the managed Ubuntu. The outer script
  /// always exits 0 so the bridge returns the envelope instead of throwing.
  static String wrap(String script) =>
      'proot-distro login $distro -- sh -c ${shQuote(script)}; exit 0\n';

  @override
  Future<String> run(String script, {required Duration timeout}) async {
    try {
      final result = await _run(
        wrap(script),
        // Room for a cold proot login on top of the command's own time.
        timeout + const Duration(seconds: 20),
      );
      return result.stdout;
    } on TermuxBridgeException catch (error) {
      throw GitShellException(
        GitShellFailure.unavailable,
        details: error.message,
      );
    } catch (_) {
      throw const GitShellException(GitShellFailure.unavailable);
    }
  }
}
