import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import '../ui/kit/kit_redact.dart';

/// Severity of one [AppLog] line. Order matters: it is what the filter uses.
enum AppLogLevel { debug, info, warn, error }

/// Append-only, on-device log for the paths that can only be diagnosed after
/// the fact: first run, setup, starting OpenCode, reconnecting.
///
/// The log lives in the app's private support directory (`logs/`), one JSON
/// object per line, one file per day, seven days kept. Nothing is uploaded; the
/// user can pull it with `adb pull` or share it from the app.
///
/// Three rules keep it safe to call from anywhere:
/// - writing never blocks a frame: lines go into a queue and are flushed in the
///   background;
/// - a failure to log is swallowed, because a logger that throws turns a
///   diagnosable bug into a crash;
/// - every field passes through `KitRedact`, so a password or token in a setup
///   step cannot end up on disk.
class AppLog {
  AppLog._();

  /// A day's file stops growing here. Setup steps and server lifecycle events
  /// are far below this; the cap only exists so a loop cannot fill the disk.
  static const int maxFileBytes = 8 * 1024 * 1024;

  /// Files older than this are deleted when the log opens.
  static const int keepDays = 7;

  static const int _maxBufferedLines = 2000;
  static const int _flushEvery = 40;
  static const int _maxFieldChars = 2000;

  static Directory? _directory;
  static IOSink? _sink;
  static File? _file;
  static String? _day;
  static String _runId = '';
  static DateTime Function() _clock = DateTime.now;
  static final List<String> _buffer = <String>[];
  static Future<void> _chain = Future<void>.value();
  static int _sinceFlush = 0;
  static int _written = 0;
  static bool _started = false;
  static bool _ready = false;
  static bool _enabled = false;

  /// True once [start] found a writable folder.
  static bool get isEnabled => _enabled;

  /// The folder holding today's file, for the settings screen to show.
  static String? get directoryPath => _directory?.path;

  /// The file currently being appended to.
  static File? get currentFile => _file;

  /// The id shared by every line of this process, so a file that spans two
  /// launches can still be split apart.
  static String get runId => _runId;

  /// Opens the log. Safe to call once, from `main`, after the binding is up.
  ///
  /// [directory] and [clock] exist for tests; production passes neither.
  static Future<void> start({
    Directory? directory,
    DateTime Function()? clock,
    String? runId,
  }) async {
    if (_started) return;
    _started = true;
    if (clock != null) _clock = clock;
    _runId = runId ?? _stamp(_clock()).replaceAll(RegExp(r'[-:T.]'), '');
    try {
      final dir =
          directory ??
          Directory('${(await getApplicationSupportDirectory()).path}/logs');
      await dir.create(recursive: true);
      _directory = dir;
      _enabled = true;
      await _prune();
      await _open(_clock());
      _ready = true;
      await _drain();
    } catch (_) {
      // No folder, no file log. The app still runs; `adb logcat` still works.
      _enabled = false;
      _ready = true;
      _buffer.clear();
    }
  }

  /// Closes the file. Tests use this to start over in a clean folder.
  static Future<void> stop() async {
    await _chain;
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    _file = null;
    _day = null;
    _directory = null;
    _started = false;
    _ready = false;
    _enabled = false;
    _buffer.clear();
    _written = 0;
    _sinceFlush = 0;
  }

  static void debug(
    String source,
    String message, [
    Map<String, Object?> fields = const {},
  ]) => _enqueue(AppLogLevel.debug, source, message, fields);

  static void info(
    String source,
    String message, [
    Map<String, Object?> fields = const {},
  ]) => _enqueue(AppLogLevel.info, source, message, fields);

  static void warn(
    String source,
    String message, [
    Map<String, Object?> fields = const {},
  ]) => _enqueue(AppLogLevel.warn, source, message, fields);

  /// An error with its stack, in one line. [fields] carry the step that failed.
  static void error(
    String source,
    Object error, {
    StackTrace? stack,
    String message = '',
    Map<String, Object?> fields = const {},
  }) {
    _enqueue(AppLogLevel.error, source, message, {
      ...fields,
      'error': _oneLine('$error'),
      if (stack != null) 'stack': _oneLine('$stack'),
    });
  }

  /// Waits until everything queued so far is on disk.
  static Future<void> flush() async {
    await _chain;
    try {
      await _sink?.flush();
    } catch (_) {}
  }

  /// The recent log as one text, newest file last. Used by the share sheet.
  static Future<String> export({int days = keepDays}) async {
    await flush();
    final dir = _directory;
    if (dir == null) return '';
    final files = <File>[];
    try {
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.log')) files.add(entity);
      }
    } catch (_) {
      return '';
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    final out = StringBuffer();
    for (final file in files.skip(
      files.length > days ? files.length - days : 0,
    )) {
      try {
        out.writeln('== ${file.uri.pathSegments.last} ==');
        out.write(await file.readAsString());
      } catch (_) {}
    }
    return out.toString();
  }

  static void _enqueue(
    AppLogLevel level,
    String source,
    String message,
    Map<String, Object?> fields,
  ) {
    if (!_started) return;
    final line = _line(level, source, message, fields);
    // Mirror to the device log so `adb logcat -s flutter` shows the same steps
    // in real time, while the file keeps them after the screen is gone.
    if (level != AppLogLevel.debug) debugPrint('OCLOG $line');
    // Until [start] finishes, lines wait here so the earliest steps — the ones
    // worth having — are not lost to the folder lookup.
    if (!_ready) {
      if (_buffer.length < _maxBufferedLines) _buffer.add(line);
      return;
    }
    if (!_enabled) return;
    if (_sink == null) {
      if (_buffer.length < _maxBufferedLines) _buffer.add(line);
      return;
    }
    _write(line);
  }

  static String _line(
    AppLogLevel level,
    String source,
    String message,
    Map<String, Object?> fields,
  ) {
    final record = <String, Object?>{
      't': _clock().toIso8601String(),
      'lvl': level.name,
      'run': _runId,
      'src': _oneLine(source),
      if (message.isNotEmpty) 'msg': _redact(message),
      for (final entry in fields.entries)
        if (entry.value != null) entry.key: _field(entry.key, entry.value!),
    };
    try {
      return jsonEncode(record);
    } catch (_) {
      return jsonEncode({
        't': _clock().toIso8601String(),
        'lvl': 'error',
        'src': 'applog',
        'msg': 'unencodable entry',
      });
    }
  }

  /// Field names whose whole value is a credential. Checked by name because
  /// this log writes JSON: `KitRedact` masks `password=…` by replacing the
  /// value *and* its delimiters, which would leave invalid JSON behind.
  static const _secretKeys = {
    'password',
    'passwd',
    'secret',
    'token',
    'apikey',
    'api_key',
    'authorization',
    'cookie',
    'credential',
    'credentials',
  };

  static bool _isSecretKey(String key) {
    final lower = key.toLowerCase();
    return _secretKeys.contains(lower) ||
        lower.contains('password') ||
        lower.contains('secret') ||
        lower.contains('token') ||
        lower.contains('apikey');
  }

  /// A field value: masked outright for a credential-shaped name, otherwise
  /// run through `KitRedact` so a key embedded in a message is still caught.
  static String _field(String key, Object value) {
    final text = '$value';
    if (_isSecretKey(key)) return KitRedact.mask;
    return _redact(text);
  }

  /// Masks credentials, flattens newlines (one record per line is the format)
  /// and bounds the length so one bad value cannot fill the day's file.
  static String _redact(String value) => _oneLine(KitRedact.text(value));

  static String _oneLine(String value) {
    final flat = value.replaceAll(RegExp(r'[\r\n]+'), r'\n').trim();
    return flat.length <= _maxFieldChars
        ? flat
        : '${flat.substring(0, _maxFieldChars)}…';
  }

  static void _write(String line) {
    _chain = _chain.then((_) async {
      if (_sink == null) return;
      try {
        // Midnight rollover: the file name carries the day, so a long-running
        // session starts a new one instead of writing into yesterday's.
        if (_stamp(_clock()) != _day) await _open(_clock());
        final sink = _sink;
        if (sink == null) return;
        if (_written + line.length > maxFileBytes) {
          await _rotateFull();
          return;
        }
        sink.writeln(line);
        _written += line.length + 1;
        if (++_sinceFlush >= _flushEvery) {
          _sinceFlush = 0;
          await sink.flush();
        }
      } catch (_) {}
    });
  }

  static Future<void> _drain() async {
    if (_buffer.isEmpty) return;
    final pending = List<String>.from(_buffer);
    _buffer.clear();
    for (final line in pending) {
      _write(line);
    }
    _chain = _chain.then((_) async {
      try {
        await _sink?.flush();
      } catch (_) {}
    });
  }

  /// A day that hit [maxFileBytes] is closed with a marker and a fresh name, so
  /// the cap never silently swallows the rest of the day.
  static Future<void> _rotateFull() async {
    try {
      _sink?.writeln(
        jsonEncode({
          't': _clock().toIso8601String(),
          'lvl': 'warn',
          'run': _runId,
          'src': 'applog',
          'msg': 'log file reached maxFileBytes; continuing in a new file',
        }),
      );
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    _file = null;
    final day = _day ?? _stamp(_clock());
    var index = 1;
    File next;
    do {
      next = File('${_directory!.path}/app-$day.$index.log');
      index++;
    } while (await next.exists());
    try {
      _sink = next.openWrite(mode: FileMode.append);
      _file = next;
      _written = 0;
      _sinceFlush = 0;
    } catch (_) {
      _enabled = false;
    }
  }

  static Future<void> _open(DateTime now) async {
    final day = _stamp(now);
    if (_day == day && _sink != null) return;
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    File file = File('${_directory!.path}/app-$day.log');
    var index = 0;
    while (await file.exists() && await file.length() >= maxFileBytes) {
      index++;
      file = File('${_directory!.path}/app-$day.$index.log');
    }
    try {
      _sink = file.openWrite(mode: FileMode.append);
      _file = file;
      _day = day;
      _written = (await file.exists()) ? await file.length() : 0;
      _sinceFlush = 0;
    } catch (_) {
      _enabled = false;
    }
  }

  /// Drops files past [keepDays]. Runs once, when the log opens.
  static Future<void> _prune() async {
    final dir = _directory;
    if (dir == null) return;
    final cutoff = _clock().subtract(const Duration(days: keepDays));
    try {
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.log')) continue;
        try {
          if ((await entity.lastModified()).isBefore(cutoff)) {
            await entity.delete();
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  static String _stamp(DateTime at) =>
      '${at.year.toString().padLeft(4, '0')}-'
      '${at.month.toString().padLeft(2, '0')}-'
      '${at.day.toString().padLeft(2, '0')}';
}
