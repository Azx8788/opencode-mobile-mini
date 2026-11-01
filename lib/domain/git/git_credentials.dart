/// Handing a GitHub sign-in to one `git push` or `git pull` without the
/// token ever appearing in a script, a command line or a log
/// (docs/design/git-page-push-feasibility-2026-10-19.md §2).
///
/// 1. The app writes the token to a fresh file only the app's user can read
///    (0600), named at random, where the project's shell sees it.
/// 2. The script names only the file's path (`OC_TOKEN_FILE`). Git is told
///    to forget every stored helper (`credential.helper=` resets the list)
///    and to ask one inline helper, which reads the file when GitHub asks
///    for a password and answers nothing for any other host.
/// 3. SSH addresses of GitHub are rewritten to HTTPS for that one command
///    (`url.<https>.insteadOf`); the saved remote is never changed.
/// 4. The file is removed by the script's exit trap and again by the app in
///    a `finally`, whether the command worked or not.
///
/// Remote servers never get the token: they push with their own sign-in.
library;

/// A secret file placed for one command.
class GitSecretFile {
  const GitSecretFile({required this.shellPath, required this.hostPath});

  /// The path as the project's shell sees it (`/root/.oc-git/c-…`).
  final String shellPath;

  /// The same file from the app's side, for removal.
  final String hostPath;
}

/// Places and removes [GitSecretFile]s where one environment's shell can read
/// them. Only environments the app can write into privately have one (Ubuntu
/// inside the app); Termux and remote servers do not.
abstract interface class GitCredentialDrop {
  /// Writes [secret] to a new 0600 file. Throws when the file cannot be made
  /// private; never returns a file others could read.
  Future<GitSecretFile> place(String secret);

  /// Deletes [file]; safe to call twice and when it is already gone.
  Future<void> remove(GitSecretFile file);
}

/// The variable naming the token file for the helper.
const gitTokenFileVariable = 'OC_TOKEN_FILE';

/// The inline credential helper. Git runs it with `sh`; it answers `get`
/// for `host=github.com` only, reading the password from the file named by
/// [gitTokenFileVariable]. Contains no secret.
const gitHubCredentialHelper =
    '!f() { test "\$1" = get || return 0; h=; '
    'while IFS== read -r k v; do test "\$k" = host && h=\$v; done; '
    'test "\$h" = github.com || return 0; '
    'printf "username=x-access-token\\npassword=%s\\n" '
    '"\$(cat "\$$gitTokenFileVariable")"; }; f';

/// `git -c …` options for one command run with a GitHub sign-in.
List<String> gitHubCredentialOptions() => const [
  '-c',
  'credential.helper=',
  '-c',
  'credential.helper=$gitHubCredentialHelper',
  '-c',
  'url.https://github.com/.insteadOf=git@github.com:',
  '-c',
  'url.https://github.com/.insteadOf=ssh://git@github.com/',
];
