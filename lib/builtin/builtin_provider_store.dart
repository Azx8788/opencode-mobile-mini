/// Reads and writes the in-app server's own `opencode.json`.
///
/// The in-app server runs in a rootfs under the app's private storage, and
/// the app can already run shell inside it ([BuiltinLinux.run]) — so a
/// provider can be saved without any new platform code, and without the
/// experimental file API that a remote server would need.
///
/// Two rules shape the shell here:
///
///  * Content crosses the boundary base64-encoded. A config carries quotes,
///    newlines and — on Windows-authored machines — full-width punctuation;
///    quoting all of that through `sh -c` is a class of bug that can be
///    avoided, not debugged.
///  * A file is replaced by writing a sibling and renaming it, so a failure
///    mid-write leaves the previous config intact.
///
/// A `jsonc` file (a config with comments) is never rewritten: the app cannot
/// preserve comments it cannot parse, and silently dropping a person's
/// comments is worse than asking them to merge by hand.
library;

import 'dart:convert';

import '../diagnostics/app_log.dart';
import '../domain/custom_provider.dart';
import '../domain/custom_provider_record.dart';
import 'builtin_linux.dart';

/// What the server already has on disk.
class ProviderConfigSnapshot {
  const ProviderConfigSnapshot({
    required this.path,
    required this.exists,
    required this.document,
    required this.hasComments,
  });

  final String path;
  final bool exists;

  /// Parsed JSON, or null when the file is missing or could not be parsed.
  final Map<String, Object?>? document;

  /// A `.jsonc` file was found where the JSON would be, or the JSON would not
  /// parse. Either way, merging is refused.
  final bool hasComments;

  /// True when the file exists but is not a JSON object this app can merge
  /// into — the caller falls back to showing the snippet.
  bool get canMerge => !hasComments && (document != null || !exists);
}

class ProviderWriteReceipt {
  const ProviderWriteReceipt({
    required this.configPath,
    required this.backupPath,
    required this.keyFileWritten,
    required this.providerID,
    required this.format,
  });

  /// Absolute path inside the server, for the confirmation line.
  final String configPath;
  final String? backupPath;
  final bool keyFileWritten;
  final String providerID;
  final ProviderConfigFormat format;
}

/// Which file this server actually reads.
///
/// OpenCode 2 keeps its config under `.oc-opencode2`. Its start script pins
/// `XDG_CONFIG_HOME` there, so that is the only path it reads — a file left
/// in the OpenCode 1 location (`.config/opencode`) is invisible to it.
///
/// This used to prefer whichever file existed, which quietly wrote every
/// save into the v1 location on a server upgraded from OpenCode 1: the file
/// was there, the save said "saved", and the running server never read it.
/// The v1 file is now left untouched and the v2 path is written instead; a
/// person whose old entry lived in v1 sees an empty form once and saves it
/// again into the file that is actually read.
class ResolvedProviderConfig {
  const ResolvedProviderConfig({
    required this.format,
    required this.relativePath,
    required this.exists,
    this.commentFile = false,
  });

  final ProviderConfigFormat format;
  final String relativePath;
  final bool exists;

  /// The file found is a `.jsonc`. Reading it as JSON would report "missing"
  /// (that name is not there) and the write would create a second config
  /// beside it — so this is carried, not re-derived.
  final bool commentFile;
}

/// Thrown when the server's config cannot be written safely.
class ProviderWriteRefused implements Exception {
  const ProviderWriteRefused(this.message, {this.reason});

  final String message;
  final String? reason;

  @override
  String toString() => message;
}

/// Runs a shell script inside the server, as [BuiltinLinux.run] does.
///
/// Injected so the scripts this file generates can be checked for syntax and
/// their effects decoded, without a phone.
typedef BuiltinScriptRunner =
    Future<BuiltinLinuxRunResult> Function(String script, Duration timeout);

class BuiltinProviderStore {
  BuiltinProviderStore({
    BuiltinLinux? linux,
    String? home,
    BuiltinScriptRunner? run,
  }) : assert(
         linux != null || run != null,
         'BuiltinProviderStore needs a bridge or a runner',
       ),
       _home = home ?? '/root',
       _run =
           run ?? ((script, timeout) => linux!.run(script, timeout: timeout));

  final String _home;
  final BuiltinScriptRunner _run;

  /// OpenCode 2's own directory first: it is what this app runs.
  static const _v2Path = '.oc-opencode2/config/opencode/opencode.json';

  /// The OpenCode 1 location, which an upgraded server may still use.
  static const _v1Path = '.config/opencode/opencode.json';

  String _absolute(String relative) => '$_home/$relative';

  /// Finds the file the server would read.
  ///
  /// Only the v2 location: the start script pins `XDG_CONFIG_HOME` at
  /// `.oc-opencode2/config`, and OpenCode 1's directory is not on that path.
  /// A `.jsonc` beside it is refused rather than shadowed.
  Future<ResolvedProviderConfig> resolve() async {
    final script =
        '''
set -u
if [ -f '$_home/$_v2Path' ]; then printf 'JSON:%s' '$_home/$_v2Path'; exit 0; fi
if [ -f '$_home/${_v2Path}c' ]; then printf 'JSONC:%s' '$_home/${_v2Path}c'; exit 0; fi
printf 'NEW:$_home/$_v2Path'
''';
    final result = await _run(script, const Duration(seconds: 30));
    final output = result.output.trim();
    if (result.exitCode != 0) {
      throw ProviderWriteRefused(
        'The server\u2019s configuration could not be found',
        reason: 'exit ${result.exitCode}',
      );
    }
    final marker = output.indexOf(':');
    if (marker < 0) {
      throw const ProviderWriteRefused(
        'The server\u2019s configuration could not be found',
      );
    }
    final kind = output.substring(0, marker);
    final path = output.substring(marker + 1).trim();
    final relative = path.startsWith('$_home/')
        ? path.substring(_home.length + 1)
        : path;
    final format = path.endsWith(_v1Path)
        ? ProviderConfigFormat.v1
        : ProviderConfigFormat.v2;
    return ResolvedProviderConfig(
      format: format,
      relativePath: relative,
      exists: kind == 'JSON' || kind == 'JSONC',
      commentFile: kind == 'JSONC',
    );
  }

  /// Reads the current config, without ever logging its contents: on a v1
  /// server it can carry an API key.
  Future<ProviderConfigSnapshot> read(ResolvedProviderConfig resolved) async {
    final path = _absolute(resolved.relativePath);
    if (resolved.commentFile) {
      // Never rewritten: the app cannot re-emit comments it never parsed,
      // and a config that loses the person's comments is worse than one the
      // app declines to touch.
      return ProviderConfigSnapshot(
        path: path,
        exists: true,
        document: null,
        hasComments: true,
      );
    }
    final script =
        '''
set -u
f='$path'
if [ -f "\$f" ]; then
  printf 'JSON:'
  base64 "\$f" | tr -d '\\n'
else
  printf 'MISSING:'
fi
''';
    final result = await _run(script, const Duration(seconds: 30));
    final output = result.output.trim();
    if (result.exitCode != 0) {
      throw ProviderWriteRefused(
        'The server\u2019s configuration could not be read',
        reason: 'exit ${result.exitCode}',
      );
    }
    final marker = output.indexOf(':');
    if (marker < 0) {
      throw const ProviderWriteRefused(
        'The server\u2019s configuration could not be read',
      );
    }
    final kind = output.substring(0, marker);
    final payload = output.substring(marker + 1).trim();
    if (kind == 'MISSING') {
      return ProviderConfigSnapshot(
        path: path,
        exists: false,
        document: null,
        hasComments: false,
      );
    }
    if (kind == 'JSONC') {
      return ProviderConfigSnapshot(
        path: path,
        exists: true,
        document: null,
        hasComments: true,
      );
    }
    String text;
    try {
      text = utf8.decode(base64Decode(payload));
    } catch (_) {
      throw const ProviderWriteRefused(
        'The server\u2019s configuration could not be decoded',
      );
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw const ProviderWriteRefused(
          'The server\u2019s configuration is not a JSON object',
        );
      }
      return ProviderConfigSnapshot(
        path: path,
        exists: true,
        document: {for (final e in decoded.entries) '${e.key}': e.value},
        hasComments: false,
      );
    } on FormatException {
      // A file that will not parse is treated as a comment-bearing one:
      // whatever makes it unparsable is the person's, and must survive.
      return ProviderConfigSnapshot(
        path: path,
        exists: true,
        document: null,
        hasComments: true,
      );
    }
  }

  /// Writes the provider, keeping a backup of the previous file.
  ///
  /// [replace] is the edit path: an entry with the same id is overwritten
  /// instead of refused. A draft whose key box was left empty keeps the key
  /// file the config already points at.
  Future<ProviderWriteReceipt> save(
    CustomProviderDraft draft, {
    ResolvedProviderConfig? resolved,
    bool replace = false,
  }) async {
    final target = resolved ?? await resolve();
    final snapshot = await read(target);
    if (snapshot.hasComments) {
      throw const ProviderWriteRefused(
        'The server\u2019s configuration has comments, so it cannot be merged '
        'automatically',
        reason: 'jsonc',
      );
    }
    final Map<String, Object?> merged;
    try {
      merged = draft.mergeInto(
        snapshot.document,
        target.format,
        replace: replace,
      );
    } on Exception catch (error) {
      throw ProviderWriteRefused('$error', reason: 'merge');
    }
    final backup = await _writeDocument(
      merged,
      path: snapshot.path,
      exists: snapshot.exists,
    );

    var keyWritten = false;
    if (draft.keyMode == ProviderKeyMode.secretFile && draft.hasKey) {
      final secret = draft.secretPath!;
      final encodedKey = base64Encode(utf8.encode(draft.apiKey!.trim()));
      // 600: the key is the person's, and anything else on the server has no
      // business reading it.
      final keyScript =
          '''
set -eu
mkdir -p '$_home/.secrets'
chmod 700 '$_home/.secrets'
printf '%s' '$encodedKey' | base64 -d > '$secret'
chmod 600 '$secret'
echo DONE
''';
      final keyResult = await _run(keyScript, const Duration(seconds: 30));
      keyWritten = keyResult.exitCode == 0 && keyResult.output.contains('DONE');
      if (!keyWritten) {
        AppLog.warn('provider', 'key file could not be written', {
          'provider': draft.id,
        });
      }
    }

    AppLog.info('provider', 'custom provider saved', {
      'provider': draft.id,
      'format': target.format.name,
      'models': draft.models.length,
      'keyMode': draft.keyMode.name,
      'backup': backup != null,
      'keyFile': keyWritten,
    });
    return ProviderWriteReceipt(
      configPath: snapshot.path,
      backupPath: backup,
      keyFileWritten: keyWritten,
      providerID: draft.id,
      format: target.format,
    );
  }

  /// Every provider entry the config holds, in the form the editor reads.
  ///
  /// A comment-bearing or unparsable file throws the same refusal a write
  /// would: the list can then say why it is read-only instead of showing
  /// "no providers" for a file that has plenty.
  Future<CustomProviderCatalogue> readRecords({
    ResolvedProviderConfig? resolved,
  }) async {
    final target = resolved ?? await resolve();
    final snapshot = await read(target);
    if (snapshot.hasComments) {
      throw const ProviderWriteRefused(
        'The server\u2019s configuration has comments, so it cannot be '
        'listed here',
        reason: 'jsonc',
      );
    }
    return readCustomProviders(snapshot.document, target.format);
  }

  /// Removes one provider entry, keeping a backup of the previous file.
  ///
  /// The key file is left alone: another entry may point at it, and deleting
  /// a secret the app did not write is not this method's call.
  Future<ProviderWriteReceipt> remove(
    String providerID, {
    ResolvedProviderConfig? resolved,
  }) async {
    final target = resolved ?? await resolve();
    final snapshot = await read(target);
    if (snapshot.hasComments) {
      throw const ProviderWriteRefused(
        'The server\u2019s configuration has comments, so it cannot be '
        'changed automatically',
        reason: 'jsonc',
      );
    }
    final document = snapshot.document;
    if (document == null) {
      throw const ProviderWriteRefused(
        'There is no provider configuration to remove from',
        reason: 'missing',
      );
    }
    final root = target.format == ProviderConfigFormat.v1
        ? 'provider'
        : 'providers';
    final current = document[root];
    if (current is! Map || !current.containsKey(providerID)) {
      throw ProviderWriteRefused(
        'No provider named "$providerID" is in the configuration',
        reason: 'missing',
      );
    }
    final providers = <String, Object?>{};
    current.forEach((key, value) => providers['$key'] = value);
    providers.remove(providerID);
    final next = <String, Object?>{...document};
    next[root] = providers;
    final backup = await _writeDocument(
      next,
      path: snapshot.path,
      exists: snapshot.exists,
    );
    AppLog.info('provider', 'custom provider removed', {
      'provider': providerID,
      'format': target.format.name,
      'backup': backup != null,
    });
    return ProviderWriteReceipt(
      configPath: snapshot.path,
      backupPath: backup,
      keyFileWritten: false,
      providerID: providerID,
      format: target.format,
    );
  }

  /// Reads the key file an entry points at, or null when it is not there.
  ///
  /// Only the list's explicit "test" action asks for this: a key that cannot
  /// be read means the test cannot run, not that the provider is broken.
  Future<String?> readSecret(String path) async {
    final script =
        '''
set -u
f='$path'
if [ -f "\$f" ]; then
  printf 'KEY:'
  base64 "\$f" | tr -d '\\n'
else
  printf 'MISSING:'
fi
''';
    final result = await _run(script, const Duration(seconds: 20));
    if (result.exitCode != 0) return null;
    final output = result.output.trim();
    if (!output.startsWith('KEY:')) return null;
    try {
      return utf8.decode(base64Decode(output.substring(4))).trim();
    } catch (_) {
      return null;
    }
  }

  /// Replaces the file with [document], writing a sibling first. Returns the
  /// backup path when there was a previous file.
  Future<String?> _writeDocument(
    Map<String, Object?> document, {
    required String path,
    required bool exists,
  }) async {
    if (!await _underLimit(document)) {
      throw const ProviderWriteRefused(
        'The configuration would grow beyond the size this app writes',
        reason: 'too-large',
      );
    }
    final encoded = base64Encode(utf8.encode(jsonEncode(document)));
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final backup = exists ? '$path.bak.$stamp' : null;

    final writeScript =
        '''
set -eu
f='$path'
mkdir -p "\$(dirname "\$f")"
${backup != null ? "cp \"\$f\" '$backup'" : ''}
printf '%s' '$encoded' | base64 -d > "\$f.tmp.$stamp"
mv "\$f.tmp.$stamp" "\$f"
echo DONE
''';
    final written = await _run(writeScript, const Duration(seconds: 45));
    if (written.exitCode != 0 || !written.output.contains('DONE')) {
      throw ProviderWriteRefused(
        'The configuration could not be written',
        reason: written.output.trim().isEmpty
            ? 'exit ${written.exitCode}'
            : written.output.trim(),
      );
    }
    return backup;
  }

  /// The config is one JSON file the server reads on every start; a document
  /// this app would not want to hand back is a bug, not a preference.
  Future<bool> _underLimit(Map<String, Object?> document) async =>
      jsonEncode(document).length <= 4 * 1024 * 1024;

  /// Whether this provider id is already in the config.
  Future<bool> contains(
    String providerID,
    ResolvedProviderConfig resolved,
  ) async {
    final snapshot = await read(resolved);
    final document = snapshot.document;
    if (document == null) return false;
    final root = resolved.format == ProviderConfigFormat.v1
        ? 'provider'
        : 'providers';
    final providers = document[root];
    return providers is Map && providers.containsKey(providerID);
  }
}
