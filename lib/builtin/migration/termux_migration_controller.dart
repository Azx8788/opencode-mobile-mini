import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/termux_migration.dart';
import 'migration_archive_store.dart';
import 'migration_space.dart';
import 'termux_migration_transport.dart';

abstract class TermuxMigrationJournal {
  Future<Map<String, dynamic>?> read(String sourceProfileId);
  Future<void> write(String sourceProfileId, Map<String, dynamic> value);
  Future<void> remove(String sourceProfileId);
}

/// The existing profile deletion sweep includes this source-scoped key.
class PreferencesTermuxMigrationJournal implements TermuxMigrationJournal {
  PreferencesTermuxMigrationJournal(this.preferences, {this.mayWrite});
  final bool Function(String)? mayWrite;
  final SharedPreferences preferences;
  static String key(String id) => 'oc.termuxMigration.$id';
  @override
  Future<Map<String, dynamic>?> read(String sourceProfileId) async {
    final raw = preferences.getString(key(sourceProfileId));
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  @override
  Future<void> remove(String sourceProfileId) async {
    if (!await preferences.remove(key(sourceProfileId))) {
      throw const TermuxMigrationException(TermuxMigrationFailure.storage);
    }
  }

  @override
  Future<void> write(String sourceProfileId, Map<String, dynamic> value) async {
    if (mayWrite?.call(sourceProfileId) == false) {
      throw const TermuxMigrationException(TermuxMigrationFailure.cancelled);
    }
    if (!await preferences.setString(key(sourceProfileId), jsonEncode(value))) {
      throw const TermuxMigrationException(TermuxMigrationFailure.storage);
    }
    // A deletion can begin while SharedPreferences is writing. Do not
    // recreate a scoped key after its sweep or admit any subsequent writes.
    if (mayWrite?.call(sourceProfileId) == false) {
      await preferences.remove(key(sourceProfileId));
      throw const TermuxMigrationException(TermuxMigrationFailure.cancelled);
    }
  }
}

typedef MigrationProfileSwitch =
    Future<String> Function({
      required String sourceProfileId,
      required bool Function() stillWanted,
      required Map<String, String> verifiedProjectPaths,
    });

/// One foreground migration owner. Keep it above routes; do not start from
/// build(). The journal survives process death; resume is an explicit action.
/// No error/callback data from either bridge is exposed in snapshots.
class TermuxMigrationController extends ChangeNotifier {
  TermuxMigrationController({
    required this.transport,
    required this.archives,
    required this.journal,
    required this.availableBytes,
    required this.switchProfile,
    required this.sourceProfileExists,
    String Function()? newJobId,
  }) : _newJobId = newJobId ?? _randomId;

  final TermuxMigrationTransport transport;
  final TermuxMigrationArchiveStore archives;
  final TermuxMigrationJournal journal;
  final Future<int?> Function() availableBytes;
  final MigrationProfileSwitch switchProfile;
  final bool Function(String) sourceProfileExists;
  final String Function() _newJobId;
  static const maxArchiveBytes = migrationMaxArchiveBytes;
  static const reserveBytes = migrationReserveBytes;
  static TermuxMigrationController? _active;
  static const attemptLimit = Duration(minutes: 15);
  Stopwatch? _attempt;
  bool get _expired => (_attempt?.elapsed ?? Duration.zero) >= attemptLimit;
  bool _cancelled = false;
  bool _disposed = false;
  bool _busy = false;
  Completer<void>? _settlement;
  Future<void>? _stopCommand;
  TermuxMigrationSource? _reviewSource;
  int? _appAvailableBytes;

  /// Completes once the admitted operation AND its stop command have exited.
  /// Capture after starting/checking/cancelling. Idle controllers are settled.
  Future<void> get whenSettled => _settlement?.future ?? Future<void>.value();

  bool _beginOperation() {
    if (_disposed || _busy || (_active != null && _active != this)) {
      return false;
    }
    _busy = true;
    _active = this;
    _cancelled = false;
    _stopCommand = null;
    _settlement = Completer<void>();
    return true;
  }

  Future<void> _finishOperation() async {
    final stop = _stopCommand;
    if (stop != null) await stop;
    _busy = false;
    if (_active == this) _active = null;
    _attempt?.stop();
    _attempt = null;
    _sourceProfileId = null;
    _settlement?.complete();
    if (!_disposed) notifyListeners();
  }

  String? _jobId;
  String? _sourceProfileId;
  TermuxMigrationSnapshot _snapshot = const TermuxMigrationSnapshot(
    phase: TermuxMigrationPhase.checking,
  );
  TermuxMigrationSnapshot get snapshot => _snapshot;
  bool get busy => _busy;
  bool get _wanted =>
      !_cancelled &&
      !_disposed &&
      !_expired &&
      (_sourceProfileId == null || sourceProfileExists(_sourceProfileId!));

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void _publish(
    TermuxMigrationPhase phase, {
    TermuxMigrationFailure? failure,
    TermuxMigrationItem? item,
    TermuxMigrationSource? source,
    int? requiredBytes,
    int? available,
    String? destination,
  }) {
    _snapshot = TermuxMigrationSnapshot(
      phase: phase,
      failure: failure,
      jobId: _jobId,
      item: item,
      source: source ?? _snapshot.source,
      requiredBytes: requiredBytes,
      availableBytes: available,
      destinationProfileId: destination,
    );
    if (!_disposed) notifyListeners();
  }

  void _checkCancelled() {
    if (_expired) {
      throw const TermuxMigrationException(TermuxMigrationFailure.timedOut);
    }
    if (!_wanted) {
      throw const TermuxMigrationException(TermuxMigrationFailure.cancelled);
    }
  }

  /// Fresh inventory; no archive, destination or profile is written here.
  Future<void> check({Set<TermuxMigrationItem> selected = const {}}) async {
    if (!_beginOperation()) return;
    _jobId = null;
    try {
      await _preflight(selected);
    } catch (e) {
      _failure(e);
    } finally {
      await _finishOperation();
    }
  }

  /// Recomputes selection cost from the latest check, with no bridge call.
  /// Call check(selected: ...) again to refresh the capacity reading.
  TermuxMigrationSpace reviewSpace(Set<TermuxMigrationItem> selected) {
    final source = _reviewSource;
    if (source == null) {
      throw const TermuxMigrationException(
        TermuxMigrationFailure.invalidSelection,
      );
    }
    return migrationSpaceFor(source, selected, _appAvailableBytes);
  }

  String _recordJob(Map<String, dynamic> record) {
    final job = record['job'];
    if (record['schema'] != 1 ||
        job is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(job)) {
      throw const TermuxMigrationException(TermuxMigrationFailure.storage);
    }
    return job;
  }

  /// Historical completion, not a fresh health/integrity check. Does not read
  /// imported files (which users may edit), contact Termux or switch profiles.
  Future<TermuxMigrationCompletedJob?> completedJob(
    String sourceProfileId,
  ) async {
    try {
      final record = await journal.read(sourceProfileId);
      if (record == null || record['done'] != true) return null;
      final job = _recordJob(record);
      final destination = record['destination'];
      if (destination is! String ||
          destination.isEmpty ||
          destination.length > 256) {
        throw const TermuxMigrationException(TermuxMigrationFailure.storage);
      }
      return TermuxMigrationCompletedJob(
        jobId: job,
        destinationProfileId: destination,
      );
    } catch (_) {
      throw const TermuxMigrationException(TermuxMigrationFailure.storage);
    }
  }

  /// Offline, fixed provider labels from a receipt-verified config export.
  /// Empty means unknown/not exported, never proof that no sign-in is needed.
  Future<List<String>> providerNames(String sourceProfileId) async {
    try {
      final record = await journal.read(sourceProfileId);
      if (record == null) return const [];
      final job = _recordJob(record);
      final expected = _expected(record, TermuxMigrationItem.config);
      if (expected == null) return const [];
      return await archives.providerNames(job, expected);
    } catch (_) {
      // Names are advisory; never return paths, content or parser errors.
      return const [];
    }
  }

  /// Discards only local transfer cache and unfinished metadata. Call cancel(),
  /// then await whenSettled first; active operations reject with sourceBusy.
  /// Committed imports, completed receipts, profiles and Termux are preserved.
  Future<TermuxMigrationDiscardResult> discardSavedCopy(
    String sourceProfileId,
  ) async {
    if (!_beginOperation()) {
      throw const TermuxMigrationException(TermuxMigrationFailure.sourceBusy);
    }
    _jobId = null;
    try {
      final record = await journal.read(sourceProfileId);
      if (record == null) return TermuxMigrationDiscardResult.nothingSaved;
      final job = _recordJob(record);
      if (record['done'] == true) {
        return TermuxMigrationDiscardResult.alreadyCompleted;
      }
      await archives.cleanupPartial(job);
      // Retain the journal until cleanup succeeds, so a failed discard retries.
      await journal.remove(sourceProfileId);
      _jobId = null;
      _publish(TermuxMigrationPhase.cancelled);
      return TermuxMigrationDiscardResult.discarded;
    } catch (_) {
      throw const TermuxMigrationException(TermuxMigrationFailure.storage);
    } finally {
      await _finishOperation();
    }
  }

  /// Restores the exact selection without exposing paths or archive content.
  Future<Set<TermuxMigrationItem>?> savedSelection(
    String sourceProfileId,
  ) async {
    try {
      final record = await journal.read(sourceProfileId);
      if (record == null) return null;
      final names = record['selected'];
      if (names is! List || names.isEmpty) {
        throw const TermuxMigrationException(TermuxMigrationFailure.storage);
      }
      return names
          .map((name) => TermuxMigrationItem.values.byName(name as String))
          .toSet();
    } catch (_) {
      throw const TermuxMigrationException(TermuxMigrationFailure.storage);
    }
  }

  Future<void> resume(String sourceProfileId) =>
      _start(sourceProfileId: sourceProfileId);

  Future<TermuxMigrationSource?> _preflight(
    Set<TermuxMigrationItem> selected,
  ) async {
    _reviewSource = null;
    _appAvailableBytes = null;
    _publish(TermuxMigrationPhase.checking);
    if (!await archives.builtinInstalled()) {
      _publish(TermuxMigrationPhase.needsBuiltin);
      return null;
    }
    _checkCancelled();
    final source = await transport.inspect();
    _validateSource(source);
    _checkCancelled();
    _reviewSource = source;
    try {
      _appAvailableBytes = await availableBytes();
    } catch (_) {
      // Capacity unavailable is unknown, not a successful zero-cost check.
    }
    _checkCancelled();
    final space = reviewSpace(selected);
    _publish(
      TermuxMigrationPhase.ready,
      source: source,
      requiredBytes: space.requiredBytes,
      available: space.availableBytes,
    );
    return source;
  }

  void _validateSource(TermuxMigrationSource source) {
    final seen = <TermuxMigrationItem>{};
    if (source.freeBytes < 0 ||
        source.items.any(
          (x) =>
              x.bytes < 0 ||
              x.files < 0 ||
              x.files > 20000 ||
              !seen.add(x.item),
        )) {
      throw const TermuxMigrationException(TermuxMigrationFailure.tooLarge);
    }
  }

  /// Start or resume the same source/selection. A different selection cannot
  /// mutate a saved job. Pass explicit selection after showing private-export
  /// and re-sign-in warnings; only projects become active files.
  Future<void> start({
    required String sourceProfileId,
    required Set<TermuxMigrationItem> selected,
  }) async {
    await _start(sourceProfileId: sourceProfileId, selected: selected);
  }

  Future<void> _start({
    required String sourceProfileId,
    Set<TermuxMigrationItem>? selected,
  }) async {
    if (!_beginOperation()) return;
    _jobId = null;
    _attempt = Stopwatch()..start();
    Map<String, dynamic>? record;
    try {
      _sourceProfileId = sourceProfileId;
      selected ??= await savedSelection(sourceProfileId);
      _checkCancelled();
      if (!sourceProfileExists(sourceProfileId) ||
          selected == null ||
          selected.isEmpty) {
        throw const TermuxMigrationException(
          TermuxMigrationFailure.invalidSelection,
        );
      }
      record = await journal.read(sourceProfileId);
      _checkCancelled();
      final names = selected.map((x) => x.name).toList()..sort();
      if (record != null) {
        if (record['schema'] != 1 ||
            jsonEncode(record['selected']) != jsonEncode(names) ||
            record['job'] is! String ||
            !RegExp(r'^[a-f0-9]{32}$').hasMatch(record['job'] as String)) {
          throw const TermuxMigrationException(
            TermuxMigrationFailure.invalidSelection,
          );
        }
        _jobId = record['job'] as String;
      } else {
        _jobId = _newJobId();
        if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(_jobId!)) {
          throw const TermuxMigrationException(
            TermuxMigrationFailure.invalidSelection,
          );
        }
        record = {
          'schema': 1,
          'job': _jobId,
          'selected': names,
          'archives': <String, dynamic>{},
        };
      }
      // Completed jobs verify their receipt/files, but do not need Termux or
      // restart/reselect a server on an idempotent UI retry.
      if (record['done'] == true) {
        for (final item in selected) {
          final expected = _expected(record, item);
          if (expected == null ||
              !await archives.imported(_jobId!, item, expected)) {
            throw const TermuxMigrationException(
              TermuxMigrationFailure.destinationConflict,
            );
          }
        }
        _checkCancelled();
        _publish(
          TermuxMigrationPhase.done,
          destination: record['destination'] as String?,
        );
        return;
      }
      final source = await _preflight(selected);
      if (source == null) return;
      final space = reviewSpace(selected);
      if (space.sufficient != true) {
        _publish(
          TermuxMigrationPhase.needsSpace,
          requiredBytes: space.requiredBytes,
          available: space.availableBytes,
        );
        return;
      }
      _checkCancelled();
      await journal.write(sourceProfileId, record);
      for (final item in selected) {
        _checkCancelled();
        if (!sourceProfileExists(sourceProfileId)) {
          throw const TermuxMigrationException(
            TermuxMigrationFailure.invalidSelection,
          );
        }
        var expected = _expected(record, item);
        if (expected != null &&
            await archives.imported(_jobId!, item, expected)) {
          continue;
        }
        _publish(TermuxMigrationPhase.packing, item: item);
        final packed = await transport.pack(
          _jobId!,
          item,
          maxBytes: maxArchiveBytes,
        );
        if (packed.bytes <= 0 ||
            packed.bytes > maxArchiveBytes ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(packed.sha256)) {
          throw const TermuxMigrationException(
            TermuxMigrationFailure.invalidArchive,
          );
        }
        if (expected != null &&
            (expected.sha256 != packed.sha256 ||
                expected.bytes != packed.bytes)) {
          throw const TermuxMigrationException(
            TermuxMigrationFailure.sourceChanged,
          );
        }
        expected = packed;
        (record['archives'] as Map<String, dynamic>)[item.name] = {
          'bytes': expected.bytes,
          'sha256': expected.sha256,
        };
        await journal.write(sourceProfileId, record);
        _checkCancelled();
        final file = File(
          '${archives.jobDirectory(_jobId!).path}/${item.name}.tar',
        );
        _publish(TermuxMigrationPhase.copying, item: item);
        await transport.copy(
          _jobId!,
          item,
          expected,
          file,
          cancelled: () => !_wanted,
        );
        _checkCancelled();
        _publish(TermuxMigrationPhase.verifying, item: item);
        await archives.verify(file, expected);
        _checkCancelled();
        _publish(TermuxMigrationPhase.unpacking, item: item);
        await archives.importItem(
          _jobId!,
          item,
          file,
          expected,
          cancelled: () => !_wanted,
        );
        _publish(TermuxMigrationPhase.verifying, item: item);
        if (!await archives.imported(_jobId!, item, expected)) {
          throw const TermuxMigrationException(
            TermuxMigrationFailure.checksumMismatch,
          );
        }
        _checkCancelled();
      }
      _checkCancelled();
      _publish(TermuxMigrationPhase.switching);
      final destination = await switchProfile(
        sourceProfileId: sourceProfileId,
        stillWanted: () => _wanted && sourceProfileExists(sourceProfileId),
        verifiedProjectPaths: selected.contains(TermuxMigrationItem.projects)
            ? {'/root/projects': '/root/projects/termux-$_jobId'}
            : const {},
      );
      _checkCancelled();
      record['done'] = true;
      record['destination'] = destination;
      await journal.write(sourceProfileId, record);
      // Private source archive remains available for recovery. Never remove
      // Termux projects/config/history; any source cleanup is a separate job.
      await archives.cleanupPartial(_jobId!);
      _publish(TermuxMigrationPhase.done, destination: destination);
    } catch (e) {
      _failure(e);
    } finally {
      await _finishOperation();
    }
  }

  TermuxMigrationArchive? _expected(
    Map<String, dynamic> record,
    TermuxMigrationItem item,
  ) {
    final values = record['archives'];
    if (values is! Map) {
      throw const TermuxMigrationException(TermuxMigrationFailure.storage);
    }
    final value = values[item.name];
    if (value == null) return null;
    if (value is! Map || value['bytes'] is! int || value['sha256'] is! String) {
      throw const TermuxMigrationException(TermuxMigrationFailure.storage);
    }
    return TermuxMigrationArchive(
      bytes: value['bytes'] as int,
      sha256: value['sha256'] as String,
    );
  }

  void _failure(Object error) {
    final code = _expired
        ? TermuxMigrationFailure.timedOut
        : !_wanted
        ? TermuxMigrationFailure.cancelled
        : error is TermuxMigrationException
        ? error.code
        : TermuxMigrationFailure.storage;
    _publish(
      code == TermuxMigrationFailure.cancelled
          ? TermuxMigrationPhase.cancelled
          : code == TermuxMigrationFailure.unavailable
          ? TermuxMigrationPhase.termuxUnreachable
          : TermuxMigrationPhase.failed,
      failure: code,
    );
  }

  /// Requests a stop immediately; this awaits only the bounded stop command.
  /// Await whenSettled before Resume/Discard/navigation that releases ownership.
  Future<void> cancel() async {
    if (!_busy) return;
    _cancelled = true;
    final job = _jobId;
    if (job != null) _stopCommand ??= _sendStop(job);
    _publish(
      TermuxMigrationPhase.cancelled,
      failure: TermuxMigrationFailure.cancelled,
    );
    await _stopCommand;
  }

  Future<void> _sendStop(String job) async {
    try {
      await transport.cancel(job);
    } catch (_) {
      // Fixed public state only; the operation still has its own timeout.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelled = true;
    final job = _jobId;
    if (_busy && job != null) {
      _stopCommand ??= _sendStop(job);
    }
    super.dispose();
  }
}
