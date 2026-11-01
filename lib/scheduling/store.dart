import 'dart:convert';

import 'package:flutter/services.dart';

import 'models.dart';
import 'recurrence.dart';

/// Implementations must atomically compare AND write across isolates/processes.
/// Native Android also rejects writes after the owning profile is removed.
abstract interface class ScheduledPromptBackend {
  Future<String?> read(String key);
  Future<bool> compareAndSet(String key, String? expected, String value);
}

class ChannelScheduledPromptBackend implements ScheduledPromptBackend {
  const ChannelScheduledPromptBackend();
  static const _channel = MethodChannel('oc/scheduled_prompts');

  @override
  Future<String?> read(String key) =>
      _channel.invokeMethod<String>('readStore', {'key': key});

  @override
  Future<bool> compareAndSet(
    String key,
    String? expected,
    String value,
  ) async =>
      await _channel.invokeMethod<bool>('casStore', {
        'key': key,
        'expected': expected,
        'value': value,
      }) ??
      false;
}

/// A fixed safe code; persistence failures never disclose serialized prompts.
class ScheduledPromptStoreException implements Exception {
  const ScheduledPromptStoreException(this.code);
  final String code;
  @override
  String toString() => 'ScheduledPromptStoreException($code)';
}

/// One versioned envelope avoids partial schedule/history/digest writes.
/// Native dispatch claims are separate, permanent occurrence tombstones. This
/// history is bounded for presentation and MUST NOT be used to deduplicate sends.
class ScheduledPromptStore {
  ScheduledPromptStore({
    ScheduledPromptBackend? backend,
    DateTime Function()? now,
  }) : _backend = backend ?? const ChannelScheduledPromptBackend(),
       _now = now ?? DateTime.now;

  static const maxSchedules = 100;
  static const maxHistory = 500;
  static const maxBytes = 4 * 1024 * 1024;
  final ScheduledPromptBackend _backend;
  final DateTime Function() _now;

  static String keyFor(String profileId) {
    if (RegExp(r'^[a-zA-Z0-9_-]{1,128}$').firstMatch(profileId)?.end !=
        profileId.length) {
      throw const ScheduledPromptStoreException('invalid_profile');
    }
    return 'oc.scheduledPrompts.$profileId';
  }

  Future<List<ScheduledPrompt>> load(String profileId) async =>
      List.unmodifiable((await _read(profileId)).schedules);

  Future<List<ScheduledPromptRun>> history(
    String profileId, {
    String? scheduleId,
  }) async {
    final runs =
        (await _read(profileId)).runs
            .where((run) => scheduleId == null || run.scheduleId == scheduleId)
            .toList()
          ..sort((a, b) => b.scheduledAt.compareTo(a.scheduledAt));
    return List.unmodifiable(runs);
  }

  Future<ScheduledPromptDigest> digest(String profileId) async =>
      (await _read(profileId)).digest;

  Future<void> save(ScheduledPrompt schedule) async {
    schedule.validate();
    await _mutate(schedule.profileId, (state) {
      final index = state.schedules.indexWhere(
        (item) => item.id == schedule.id,
      );
      if (index < 0) {
        if (state.schedules.length >= maxSchedules) {
          throw const ScheduledPromptStoreException('schedule_limit');
        }
        state.schedules.add(schedule);
      } else {
        if (schedule.revision != state.schedules[index].revision + 1) {
          throw const ScheduledPromptStoreException('stale_schedule');
        }
        state.schedules[index] = schedule;
      }
    });
  }

  /// Removes its visible history too. Native occurrence claims remain fenced
  /// until profile deletion so a delayed worker cannot repeat a removed run.
  Future<void> delete(String profileId, String id) =>
      _mutate(profileId, (state) {
        state.schedules.removeWhere((item) => item.id == id);
        state.runs.removeWhere((item) => item.scheduleId == id);
      });

  Future<void> setEnabled(String profileId, String id, bool enabled) =>
      _mutate(profileId, (state) {
        final index = state.schedules.indexWhere((item) => item.id == id);
        if (index < 0) {
          throw const ScheduledPromptStoreException('schedule_missing');
        }
        final current = state.schedules[index];
        if (current.enabled == enabled) return;
        final next = enabled
            ? nextScheduledOccurrence(current.recurrence, _now())
            : null;
        if (enabled && next == null) {
          throw const ScheduledPromptStoreException('schedule_expired');
        }
        state.schedules[index] = current.copyWith(
          enabled: enabled,
          nextRunAt: next,
          clearNextRunAt: !enabled,
          revision: current.revision + 1,
        );
      });

  /// Advances only the exact occurrence a worker claimed. A stale worker never
  /// revives a removed schedule or overwrites an edit/pause made during dispatch.
  Future<bool> advanceOccurrence(
    ScheduledPrompt expected,
    DateTime? next,
  ) async {
    var advanced = false;
    await _mutate(expected.profileId, (state) {
      advanced = false;
      final index = state.schedules.indexWhere(
        (item) => item.id == expected.id,
      );
      if (index < 0) return;
      final current = state.schedules[index];
      if (current.revision != expected.revision ||
          !_sameInstant(current.nextRunAt, expected.nextRunAt) ||
          !current.enabled) {
        return;
      }
      state.schedules[index] = current.copyWith(
        nextRunAt: next,
        clearNextRunAt: next == null,
        enabled: next != null,
      );
      advanced = true;
    });
    return advanced;
  }

  /// Claims the digest cutoff before notification delivery. A concurrent toggle
  /// or previously claimed cutoff suppresses delivery without reverting settings.
  Future<bool> claimDigest(
    String profileId,
    ScheduledPromptDigest expectedDigest,
    DateTime cutoff,
  ) async {
    var claimed = false;
    await _mutate(profileId, (state) {
      claimed = false;
      final current = state.digest;
      if (!current.enabled ||
          jsonEncode(current.toJson()) != jsonEncode(expectedDigest.toJson()) ||
          (current.lastDeliveredAt != null &&
              !cutoff.isAfter(current.lastDeliveredAt!))) {
        return;
      }
      state.digest = ScheduledPromptDigest(
        enabled: current.enabled,
        hour: current.hour,
        minute: current.minute,
        lastDeliveredAt: cutoff,
      );
      claimed = true;
    });
    return claimed;
  }

  Future<void> setDigest(String profileId, ScheduledPromptDigest digest) async {
    digest.validate();
    await _mutate(profileId, (state) => state.digest = digest);
  }

  Future<void> recordRun(String profileId, ScheduledPromptRun run) async {
    run.validate();
    await _mutate(profileId, (state) {
      if (!state.schedules.any((schedule) => schedule.id == run.scheduleId)) {
        throw const ScheduledPromptStoreException('schedule_missing');
      }
      final index = state.runs.indexWhere((item) => item.id == run.id);
      if (index >= 0) {
        final previous = state.runs[index];
        if (previous.scheduleId != run.scheduleId ||
            !previous.scheduledAt.isAtSameMomentAs(run.scheduledAt) ||
            !previous.startedAt.isAtSameMomentAs(run.startedAt) ||
            (previous.status != ScheduledPromptRunStatus.running &&
                jsonEncode(previous.toJson()) != jsonEncode(run.toJson()))) {
          throw const ScheduledPromptStoreException('invalid_run_transition');
        }
        state.runs[index] = run;
      } else {
        state.runs.add(run);
      }
      state.runs.sort((a, b) => b.scheduledAt.compareTo(a.scheduledAt));
      // Never discard an in-flight run merely to make room for display history.
      while (state.runs.length > maxHistory) {
        final oldestTerminal = state.runs.lastIndexWhere(
          (item) => item.status != ScheduledPromptRunStatus.running,
        );
        if (oldestTerminal < 0) {
          throw const ScheduledPromptStoreException('history_limit');
        }
        state.runs.removeAt(oldestTerminal);
      }
    });
  }

  Future<_State> _read(String profileId) async {
    try {
      return _State.decode(await _backend.read(keyFor(profileId)), profileId);
    } on ScheduledPromptStoreException {
      rethrow;
    } catch (_) {
      throw const ScheduledPromptStoreException('storage_unavailable');
    }
  }

  Future<void> _mutate(String profileId, void Function(_State) mutation) async {
    final key = keyFor(profileId);
    try {
      for (var attempt = 0; attempt < 20; attempt++) {
        final raw = await _backend.read(key);
        final state = _State.decode(raw, profileId);
        mutation(state);
        final encoded = state.encode();
        if (utf8.encode(encoded).length > maxBytes) {
          throw const ScheduledPromptStoreException('storage_limit');
        }
        if (await _backend.compareAndSet(key, raw, encoded)) return;
      }
      throw const ScheduledPromptStoreException('storage_busy');
    } on ScheduledPromptStoreException {
      rethrow;
    } catch (_) {
      throw const ScheduledPromptStoreException('storage_unavailable');
    }
  }
}

// JSON stores UTC while a live worker's clock normally returns local DateTime.
// Identity is the instant, preserving full microsecond precision, not isUtc.
bool _sameInstant(DateTime? left, DateTime? right) => left == null
    ? right == null
    : right != null && left.isAtSameMomentAs(right);

class _State {
  _State({required this.schedules, required this.runs, required this.digest});
  final List<ScheduledPrompt> schedules;
  final List<ScheduledPromptRun> runs;
  ScheduledPromptDigest digest;

  factory _State.decode(String? raw, String profileId) {
    if (raw == null) {
      return _State(
        schedules: [],
        runs: [],
        digest: const ScheduledPromptDigest(),
      );
    }
    try {
      if (utf8.encode(raw).length > ScheduledPromptStore.maxBytes) {
        throw const FormatException();
      }
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (json['schemaVersion'] != 1) throw const FormatException();
      final schedules = (json['schedules'] as List)
          .map((row) => ScheduledPrompt.fromJson(row as Map<String, dynamic>))
          .toList();
      final runs = (json['runs'] as List)
          .map(
            (row) => ScheduledPromptRun.fromJson(row as Map<String, dynamic>),
          )
          .toList();
      if (schedules.length > ScheduledPromptStore.maxSchedules ||
          runs.length > ScheduledPromptStore.maxHistory ||
          schedules.any((row) => row.profileId != profileId) ||
          schedules.map((row) => row.id).toSet().length != schedules.length ||
          runs.map((row) => row.id).toSet().length != runs.length) {
        throw const FormatException();
      }
      return _State(
        schedules: schedules,
        runs: runs,
        digest: ScheduledPromptDigest.fromJson(
          json['digest'] as Map<String, dynamic>,
        ),
      );
    } catch (_) {
      throw const ScheduledPromptStoreException('storage_corrupt');
    }
  }

  String encode() => jsonEncode({
    'schemaVersion': 1,
    'schedules': schedules.map((row) => row.toJson()).toList(),
    'runs': runs.map((row) => row.toJson()).toList(),
    'digest': digest.toJson(),
  });
}
