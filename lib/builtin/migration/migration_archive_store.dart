import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../domain/termux_migration.dart';
import 'migration_provider_names.dart';

/// Private, bounded USTAR importer. Exports are never activated as configuration.
/// A manifest travels in the atomic directory rename so a lost journal write
/// cannot cause a second import or overwrite a user's imported project.
class TermuxMigrationArchiveStore {
  TermuxMigrationArchiveStore({required this.support});

  final Directory support;
  static const maxBytes = 512 * 1024 * 1024;
  static const maxEntries = 20000;
  static const _manifest = '.oc-migration-manifest.json';

  Directory jobDirectory(String jobId) {
    _job(jobId);
    return Directory('${support.path}/migrations/$jobId');
  }

  Future<bool> builtinInstalled() async {
    try {
      await _existingParents(Directory('${support.path}/linux/ubuntu'));
      return await FileSystemEntity.type(
            '${support.path}/linux/ubuntu.ready',
            followLinks: false,
          ) ==
          FileSystemEntityType.file;
    } on TermuxMigrationException {
      return false;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> verify(File archive, TermuxMigrationArchive expected) async {
    _expected(expected);
    try {
      if (await FileSystemEntity.type(archive.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await archive.length() != expected.bytes) {
        _fail(TermuxMigrationFailure.invalidArchive);
      }
      final digest = await sha256.bind(archive.openRead()).first;
      if (digest.toString() != expected.sha256) {
        _fail(TermuxMigrationFailure.checksumMismatch);
      }
    } on FileSystemException {
      _fail(TermuxMigrationFailure.storage);
    }
  }

  Future<void> importItem(
    String jobId,
    TermuxMigrationItem item,
    File archive,
    TermuxMigrationArchive expected, {
    required bool Function() cancelled,
  }) async {
    _job(jobId);
    _cancel(cancelled);
    if (await imported(jobId, item, expected)) {
      return;
    }
    await verify(archive, expected);
    _cancel(cancelled);
    final stage = Directory('${jobDirectory(jobId).path}/staging/${item.name}');
    try {
      await _directory('migrations/$jobId/staging');
      await _deleteStage(stage);
      await stage.create();
      await _mode(stage.path, 448);
      final entries = await _extract(archive, stage, item, cancelled);
      await verify(archive, expected);
      _cancel(cancelled);
      final marker = File('${stage.path}/$_manifest');
      await marker.writeAsString(
        jsonEncode({
          'version': 1,
          'archiveBytes': expected.bytes,
          'archiveSha256': expected.sha256,
          'item': item.name,
          'entries': entries,
        }),
        flush: true,
      );
      await _secureStage(stage, entries);
      final destination = _destination(jobId, item);
      if (item != TermuxMigrationItem.projects && !await builtinInstalled()) {
        _fail(TermuxMigrationFailure.unavailable);
      }
      await _directory(
        item == TermuxMigrationItem.projects
            ? 'projects'
            : 'linux/ubuntu/root/.oc-migration-exports/$jobId',
      );
      if (await FileSystemEntity.type(destination.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        _fail(TermuxMigrationFailure.destinationConflict);
      }
      _cancel(cancelled);
      await stage.rename(destination.path);
      // Re-read destination hashes before reporting a verified import.
      await imported(jobId, item, expected);
    } on TermuxMigrationException {
      rethrow;
    } catch (_) {
      _fail(TermuxMigrationFailure.storage);
    } finally {
      // Only uncommitted staging belongs to this attempt. Imported files remain.
      try {
        await _deleteStage(stage);
      } on FileSystemException {
        _fail(TermuxMigrationFailure.storage);
      }
    }
  }

  Future<bool> imported(
    String jobId,
    TermuxMigrationItem item,
    TermuxMigrationArchive expected,
  ) async {
    _job(jobId);
    _expected(expected);
    final destination = _destination(jobId, item);
    if (await FileSystemEntity.type(destination.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return false;
    }
    try {
      await _existingParents(destination);
      final marker = File('${destination.path}/$_manifest');
      if (await FileSystemEntity.type(marker.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await marker.length() > 16 * 1024 * 1024) {
        _fail(TermuxMigrationFailure.destinationConflict);
      }
      final data =
          jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
      if (data['version'] != 1 ||
          data['archiveBytes'] != expected.bytes ||
          data['archiveSha256'] != expected.sha256 ||
          data['item'] != item.name) {
        _fail(TermuxMigrationFailure.destinationConflict);
      }
      final entries = data['entries'] as List<dynamic>;
      if (entries.length > maxEntries) {
        _fail(TermuxMigrationFailure.destinationConflict);
      }
      final paths = <String>{};
      var total = 0;
      for (final value in entries) {
        final entry = value as Map<String, dynamic>;
        final path = _path(entry['path'] as String);
        if (!paths.add(path) || path == _manifest) {
          _fail(TermuxMigrationFailure.destinationConflict);
        }
        final target = '${destination.path}/$path';
        await _existingParents(Directory(File(target).parent.path));
        final type = await FileSystemEntity.type(target, followLinks: false);
        if (entry['type'] == 'directory') {
          if (type != FileSystemEntityType.directory) {
            _fail(TermuxMigrationFailure.destinationConflict);
          }
        } else if (entry['type'] == 'file') {
          final bytes = entry['bytes'] as int;
          total += bytes;
          if (bytes < 0 ||
              total > maxBytes ||
              type != FileSystemEntityType.file ||
              await File(target).length() != bytes ||
              (await sha256.bind(File(target).openRead()).first).toString() !=
                  entry['sha256']) {
            _fail(TermuxMigrationFailure.destinationConflict);
          }
        } else {
          _fail(TermuxMigrationFailure.destinationConflict);
        }
        if (((await FileStat.stat(target)).mode & 511) != entry['mode']) {
          _fail(TermuxMigrationFailure.destinationConflict);
        }
      }
      var count = 0;
      await for (final entity in destination.list(
        recursive: true,
        followLinks: false,
      )) {
        final relative = entity.path.substring(destination.path.length + 1);
        if (relative == _manifest) {
          continue;
        }
        if (++count > maxEntries || !paths.contains(relative)) {
          _fail(TermuxMigrationFailure.destinationConflict);
        }
      }
      if (count != paths.length) {
        _fail(TermuxMigrationFailure.destinationConflict);
      }
      return true;
    } catch (_) {
      _fail(TermuxMigrationFailure.destinationConflict);
    }
  }

  /// Only verified inactive config exports can supply advisory provider labels.
  Future<List<String>> providerNames(
    String jobId,
    TermuxMigrationArchive expected,
  ) async {
    if (!await imported(jobId, TermuxMigrationItem.config, expected)) {
      return const [];
    }
    return readMigrationProviderNames(
      _destination(jobId, TermuxMigrationItem.config),
    );
  }

  Future<void> cleanupPartial(String jobId) async {
    _job(jobId);
    final job = jobDirectory(jobId);
    try {
      // Transfer archives and offsets can contain private source data. Once
      // completed, retain only the verified import and its in-directory receipt.
      await _existingParents(job, allowMissing: true);
      await _deleteStage(job);
    } on FileSystemException {
      _fail(TermuxMigrationFailure.storage);
    }
  }

  Directory _destination(String jobId, TermuxMigrationItem item) => Directory(
    item == TermuxMigrationItem.projects
        ? '${support.path}/projects/termux-$jobId'
        : '${support.path}/linux/ubuntu/root/.oc-migration-exports/$jobId/${item.name}',
  );

  Future<List<Map<String, Object>>> _extract(
    File archive,
    Directory stage,
    TermuxMigrationItem item,
    bool Function() cancelled,
  ) async {
    final input = await archive.open();
    final entries = <String, Map<String, Object>>{};
    final explicit = <String>{};
    var payload = 0;
    var headers = 0;
    var zeros = 0;
    final archiveBytes = await input.length();
    try {
      while (await input.position() < archiveBytes) {
        _cancel(cancelled);
        final header = await _read(input, 512);
        if (header.every((b) => b == 0)) {
          zeros++;
          continue;
        }
        if (zeros != 0 || ++headers > maxEntries) {
          _fail(TermuxMigrationFailure.invalidArchive);
        }
        var checksum = 0;
        for (var i = 0; i < 512; i++) {
          checksum += i >= 148 && i < 156 ? 32 : header[i];
        }
        if (_octal(header, 148, 8) != checksum ||
            _text(header, 257, 6) != 'ustar' ||
            ascii.decode(header.sublist(263, 265)) != '00') {
          _fail(TermuxMigrationFailure.invalidArchive);
        }
        final type = header[156];
        if (type != 0 && type != 48 && type != 53) {
          _fail(TermuxMigrationFailure.unsupportedEntry);
        }
        if (_text(header, 157, 100).isNotEmpty) {
          _fail(TermuxMigrationFailure.unsupportedEntry);
        }
        final prefix = _text(header, 345, 155);
        var raw = '${prefix.isEmpty ? '' : '$prefix/'}${_text(header, 0, 100)}';
        final size = _octal(header, 124, 12);
        final sourceMode = _octal(header, 100, 8);
        if (type == 53 && size != 0) {
          _fail(TermuxMigrationFailure.invalidArchive);
        }
        if ((raw == './' || raw == '.') && type == 53) {
          if (!explicit.add('.')) {
            _fail(TermuxMigrationFailure.invalidArchive);
          }
          continue;
        }
        if (raw.startsWith('./')) {
          {
            raw = raw.substring(2);
          }
        }
        if (type == 53 && raw.endsWith('/')) {
          raw = raw.substring(0, raw.length - 1);
        }
        final path = _path(raw);
        if (path == _manifest || !explicit.add(path)) {
          _fail(TermuxMigrationFailure.invalidArchive);
        }
        payload += size;
        if (payload > maxBytes ||
            size > archiveBytes - await input.position()) {
          _fail(TermuxMigrationFailure.tooLarge);
        }
        final parts = path.split('/');
        for (var i = 1; i < parts.length; i++) {
          await _stageDirectory(stage, parts.take(i).join('/'), entries);
        }
        if (type == 53) {
          await _stageDirectory(stage, path, entries);
        } else {
          if (entries.containsKey(path)) {
            _fail(TermuxMigrationFailure.invalidArchive);
          }
          final target = File('${stage.path}/$path');
          final output = await target.open(mode: FileMode.write);
          final sink = _DigestSink();
          final hash = sha256.startChunkedConversion(sink);
          final mode =
              item == TermuxMigrationItem.projects && (sourceMode & 73) != 0
              ? 448
              : 384;
          try {
            var remaining = size;
            while (remaining > 0) {
              _cancel(cancelled);
              final chunk = await _read(
                input,
                remaining > 65536 ? 65536 : remaining,
              );
              hash.add(chunk);
              await output.writeFrom(chunk);
              remaining -= chunk.length;
            }
            hash.close();
            await output.flush();
          } finally {
            await output.close();
          }
          entries[path] = {
            'path': path,
            'type': 'file',
            'bytes': size,
            'sha256': sink.value.toString(),
            'mode': mode,
          };
          if (entries.length > maxEntries) {
            _fail(TermuxMigrationFailure.tooLarge);
          }
          final padding = (512 - size % 512) % 512;
          if (padding > 0 &&
              !(await _read(input, padding)).every((b) => b == 0)) {
            _fail(TermuxMigrationFailure.invalidArchive);
          }
        }
      }
      if (zeros < 2) {
        _fail(TermuxMigrationFailure.invalidArchive);
      }
      return entries.values.toList();
    } on FormatException {
      _fail(TermuxMigrationFailure.invalidArchive);
    } finally {
      await input.close();
    }
  }

  Future<void> _stageDirectory(
    Directory stage,
    String path,
    Map<String, Map<String, Object>> entries,
  ) async {
    final existing = entries[path];
    if (existing != null) {
      if (existing['type'] != 'directory') {
        _fail(TermuxMigrationFailure.invalidArchive);
      }
      return;
    }
    if (entries.length >= maxEntries) {
      _fail(TermuxMigrationFailure.tooLarge);
    }
    final directory = Directory('${stage.path}/$path');
    await directory.create();
    entries[path] = {'path': path, 'type': 'directory', 'mode': 448};
  }

  Future<void> _directory(String relative) async {
    var current = support.path;
    await _existingParents(support);
    for (final part in relative.split('/')) {
      current = '$current/$part';
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        await Directory(current).create();
        await _mode(current, 448);
      } else if (type != FileSystemEntityType.directory) {
        _fail(TermuxMigrationFailure.destinationConflict);
      }
    }
  }

  Future<void> _existingParents(
    Directory directory, {
    bool allowMissing = false,
  }) async {
    var current = support.path;
    final relative = directory.path == current
        ? ''
        : directory.path.substring(current.length + 1);
    for (final part in [
      '',
      ...relative.split('/').where((s) => s.isNotEmpty),
    ]) {
      if (part.isNotEmpty) {
        current = '$current/$part';
      }
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (allowMissing && type == FileSystemEntityType.notFound) {
        return;
      }
      if (type != FileSystemEntityType.directory) {
        _fail(TermuxMigrationFailure.destinationConflict);
      }
    }
  }

  Future<void> _deleteStage(Directory stage) async {
    final type = await FileSystemEntity.type(stage.path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await stage.delete(recursive: true);
    } else if (type != FileSystemEntityType.notFound) {
      _fail(TermuxMigrationFailure.destinationConflict);
    }
  }

  static Future<void> _secureStage(
    Directory stage,
    List<Map<String, Object>> entries,
  ) async {
    // The enclosing staging directory is 0700 from creation. Batch permission
    // changes avoid a subprocess for each of up to 20,000 archive entries.
    final executable = Platform.isAndroid ? '/system/bin/chmod' : 'chmod';
    final base = await Process.run(executable, [
      '-R',
      'u=rwX,go=',
      stage.path,
    ]).timeout(const Duration(seconds: 30));
    if (base.exitCode != 0) {
      _fail(TermuxMigrationFailure.storage);
    }
    final files = entries
        .where((e) => e['type'] == 'file' && e['mode'] == 448)
        .map((e) => '${stage.path}/${e['path']}')
        .toList();
    for (var start = 0; start < files.length; start += 100) {
      final end = start + 100 < files.length ? start + 100 : files.length;
      final result = await Process.run(executable, [
        '700',
        ...files.sublist(start, end),
      ]).timeout(const Duration(seconds: 5));
      if (result.exitCode != 0) {
        _fail(TermuxMigrationFailure.storage);
      }
    }
  }

  static Future<void> _mode(String path, int mode) async {
    final result = await Process.run(
      Platform.isAndroid ? '/system/bin/chmod' : 'chmod',
      [mode.toRadixString(8), path],
    ).timeout(const Duration(seconds: 5));
    if (result.exitCode != 0) {
      _fail(TermuxMigrationFailure.storage);
    }
  }

  static Future<Uint8List> _read(RandomAccessFile input, int bytes) async {
    final result = Uint8List(bytes);
    var offset = 0;
    while (offset < bytes) {
      final count = await input.readInto(result, offset, bytes);
      if (count == 0) {
        _fail(TermuxMigrationFailure.invalidArchive);
      }
      offset += count;
    }
    return result;
  }

  static String _text(Uint8List bytes, int start, int length) {
    final field = bytes.sublist(start, start + length);
    final zero = field.indexOf(0);
    return utf8.decode(zero < 0 ? field : field.sublist(0, zero));
  }

  static int _octal(Uint8List bytes, int start, int length) {
    final value = _text(bytes, start, length).trim();
    if (!RegExp(r'^[0-7]+$').hasMatch(value)) {
      _fail(TermuxMigrationFailure.invalidArchive);
    }
    return int.parse(value, radix: 8);
  }

  static String _path(String path) {
    if (path.isEmpty ||
        path.length > 255 ||
        path.startsWith('/') ||
        path.contains('\\') ||
        path.codeUnits.any((c) => c < 32 || c == 127)) {
      _fail(TermuxMigrationFailure.invalidArchive);
    }
    final parts = path.split('/');
    if (parts.length > 64 ||
        parts.any((p) => p.isEmpty || p == '.' || p == '..')) {
      _fail(TermuxMigrationFailure.invalidArchive);
    }
    return path;
  }

  static void _job(String job) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(job)) {
      _fail(TermuxMigrationFailure.invalidSelection);
    }
  }

  static void _expected(TermuxMigrationArchive expected) {
    if (expected.bytes < 1024 ||
        expected.bytes > maxBytes ||
        expected.bytes % 512 != 0 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(expected.sha256)) {
      _fail(TermuxMigrationFailure.invalidArchive);
    }
  }

  static void _cancel(bool Function() cancelled) {
    if (cancelled()) {
      _fail(TermuxMigrationFailure.cancelled);
    }
  }

  static Never _fail(TermuxMigrationFailure code) =>
      throw TermuxMigrationException(code);
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
