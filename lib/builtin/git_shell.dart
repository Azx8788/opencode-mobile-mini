import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../domain/git/git_credentials.dart';
import '../domain/git/git_shell.dart';
import 'builtin_folders.dart' show BuiltinRootfsFolders;
import 'builtin_linux.dart';

/// The Git page's commands in Ubuntu inside the app (`BuiltinLinux.run`).
class BuiltinGitShell implements GitShell {
  BuiltinGitShell(this._linux);

  final BuiltinLinux _linux;

  @override
  Future<String> run(String script, {required Duration timeout}) async {
    try {
      final result = await _linux.run(script, timeout: timeout);
      return result.output;
    } on BuiltinLinuxException catch (error) {
      throw GitShellException(
        error.code == 'timeout'
            ? GitShellFailure.timedOut
            : GitShellFailure.unavailable,
        details: error.details ?? error.message,
      );
    } on TimeoutException {
      throw const GitShellException(GitShellFailure.timedOut);
    } catch (_) {
      throw const GitShellException(GitShellFailure.unavailable);
    }
  }
}

/// Places GitHub tokens for one command in Ubuntu inside the app: a file
/// named at random under `/root/.oc-git`, made 0600 before the token is
/// written, overwritten and deleted afterwards. Writing happens on the app's
/// side of Ubuntu's files, so the token never passes through a script.
class BuiltinGitSecretDrop implements GitCredentialDrop {
  BuiltinGitSecretDrop({
    Future<Directory?> Function()? rootfs,
    Future<bool> Function(String path, String mode)? chmod,
    Random? random,
  }) : _rootfs = rootfs ?? BuiltinRootfsFolders.locateRootfs,
       _chmod = chmod ?? _systemChmod,
       _random = random ?? Random.secure();

  final Future<Directory?> Function() _rootfs;
  final Future<bool> Function(String path, String mode) _chmod;
  final Random _random;

  /// The folder inside Ubuntu.
  static const shellFolder = '/root/.oc-git';

  static Future<bool> _systemChmod(String path, String mode) async {
    try {
      final result = await Process.run('chmod', [mode, path]);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static bool _modeIs(FileStat stat, int mode) => stat.mode & 0x1ff == mode;

  @override
  Future<GitSecretFile> place(String secret) async {
    final root = await _rootfs();
    if (root == null) {
      throw const FileSystemException('In-app Ubuntu is not installed');
    }
    final folder = Directory('${root.path}$shellFolder');
    await folder.create(recursive: true);
    if (!await _chmod(folder.path, '700')) {
      throw const FileSystemException('Could not make the folder private');
    }
    final name =
        'c-${List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    final file = File('${folder.path}/$name');
    // Empty first, private second, secret last: the token is never in a
    // file anyone else could read.
    await file.writeAsString('', flush: true);
    if (!await _chmod(file.path, '600') || !_modeIs(await file.stat(), 0x180)) {
      await _delete(file);
      throw const FileSystemException('Could not make the file private');
    }
    try {
      await file.writeAsString(secret, flush: true);
    } catch (_) {
      await _delete(file);
      rethrow;
    }
    return GitSecretFile(shellPath: '$shellFolder/$name', hostPath: file.path);
  }

  @override
  Future<void> remove(GitSecretFile file) => _delete(File(file.hostPath));

  static Future<void> _delete(File file) async {
    try {
      if (await file.exists()) {
        final length = await file.length();
        if (length > 0) {
          await file.writeAsBytes(List.filled(length, 0), flush: true);
        }
        await file.delete();
      }
    } on FileSystemException {
      // Already gone (the script's exit trap removed it first).
    }
  }
}
