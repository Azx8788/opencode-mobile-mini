import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/settings_scope.dart';

/// Shared local consent. This store never acquires a gateway or sends a receipt.
class ReadStateConsentStore extends ChangeNotifier {
  ReadStateConsentStore._(this._prefs);
  factory ReadStateConsentStore.forPreferences(SharedPreferences preferences) =>
      _owners[preferences] ??= ReadStateConsentStore._(preferences);

  static final _owners = Expando<ReadStateConsentStore>();
  static const migrationKey = 'oc.readStateConsentMigration.v1';
  static String preferenceKey(String id) => 'oc.shareSessionViews.$id';
  static String originKey(String id) => 'oc.shareSessionViewsOrigin.$id';
  static String defaultKey(String id) => 'oc.shareSessionViewsDefault.$id';
  final SharedPreferences _prefs;
  final _confirmed = <String, bool>{};
  final _origins = <String, SettingOriginKind>{};
  final _closed = <String>{};
  final _private = <String>{};
  final _migrationBlocked = <String>{};
  final _pendingCount = <String, int>{};
  final _generations = <String, int>{};
  Future<void> _writes = Future.value();
  int _epoch = 0;
  bool _migrationCompleted = false;
  int get epoch => _epoch;

  bool enabled(String profileId) {
    if (profileId.isEmpty ||
        _closed.contains(profileId) ||
        _private.contains(profileId) ||
        _migrationBlocked.contains(profileId) ||
        saving(profileId)) {
      return false;
    }
    return _confirmed.putIfAbsent(profileId, () {
      try {
        return _prefs.get(preferenceKey(profileId)) == true;
      } catch (_) {
        return false;
      }
    });
  }

  /// What this server starts from before the person chose: off for a new
  /// server, the carried-over value for one that existed before consent was
  /// per server. "Use my default" returns to it.
  bool defaultFor(String profileId) {
    try {
      final saved = _prefs.get(defaultKey(profileId));
      if (saved is bool) return saved;
      if (_prefs.get(originKey(profileId)) == 'migrated') {
        return _prefs.get(preferenceKey(profileId)) == true;
      }
    } catch (_) {}
    return false;
  }

  bool saving(String profileId) => (_pendingCount[profileId] ?? 0) > 0;
  bool isClosed(String profileId) => _closed.contains(profileId);

  SettingOriginKind origin(String profileId) =>
      _origins.putIfAbsent(profileId, () {
        try {
          if (_prefs.get(originKey(profileId)) == 'migrated') {
            return SettingOriginKind.migrated;
          }
          if (_prefs.get(preferenceKey(profileId)) is bool) {
            return SettingOriginKind.explicitValue;
          }
        } catch (_) {}
        return SettingOriginKind.defaultValue;
      });

  void _changed() {
    _epoch++;
    notifyListeners();
  }

  Future<void> _enqueue(Future<void> Function() write) {
    final result = _writes.then((_) => write());
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _accepted(Future<bool> operation) async {
    if (!await operation) {
      throw const SettingsFailure(SettingsFailureReason.storageFailed);
    }
  }

  Future<void> _reload() async {
    try {
      await _prefs.reload();
    } catch (_) {}
  }

  /// Capture the legacy population before any newly added profile can join it.
  /// The journal contains only IDs and a boolean, never transport/secret data.
  Future<void> migrateExistingProfiles(Iterable<String> profileIds) {
    if (_migrationCompleted) return Future.value();
    final present = profileIds.where((id) => id.isNotEmpty).toSet();
    for (final id in present) {
      _pendingCount.update(id, (n) => n + 1, ifAbsent: () => 1);
    }
    if (present.isNotEmpty) _changed();
    return _enqueue(() async {
      try {
        Map<String, dynamic>? journal;
        final raw = _prefs.get(migrationKey);
        if (raw != null) {
          final decoded = raw is String ? jsonDecode(raw) : null;
          if (decoded is! Map<String, dynamic> ||
              decoded['version'] != 1 ||
              decoded['complete'] is! bool ||
              decoded['ids'] is! List ||
              (decoded['ids'] as List).any((id) => id is! String) ||
              decoded['legacy'] is! bool) {
            throw const SettingsFailure(SettingsFailureReason.storageFailed);
          }
          journal = decoded;
          if (journal['complete'] == true) {
            _migrationCompleted = true;
            if (_migrationBlocked.isNotEmpty) {
              _migrationBlocked.clear();
              _confirmed.clear();
              _origins.clear();
              _changed();
            }
            return;
          }
        }
        if (journal == null) {
          final legacyRaw = _prefs.get('oc.shareSessionViews');
          journal = <String, dynamic>{
            'version': 1, 'complete': false, 'ids': present.toList()..sort(),
            // Missing used to mean on. Invalid data must not grant sharing.
            'legacy': legacyRaw == null || legacyRaw == true,
          };
          await _accepted(_prefs.setString(migrationKey, jsonEncode(journal)));
        }
        for (final id in (journal['ids'] as List).cast<String>()) {
          if (!present.contains(id) || _closed.contains(id)) continue;
          final key = preferenceKey(id);
          if (_prefs.containsKey(key)) continue; // explicit destination wins
          await _accepted(_prefs.setString(originKey(id), 'migrated'));
          await _accepted(_prefs.setBool(key, journal['legacy'] as bool));
          _confirmed[id] = journal['legacy'] as bool;
          _origins[id] = SettingOriginKind.migrated;
        }
        // Completion is committed last; completed journals retain no IDs.
        await _accepted(
          _prefs.setString(
            migrationKey,
            jsonEncode({
              'version': 1,
              'complete': true,
              'ids': <String>[],
              'legacy': journal['legacy'],
            }),
          ),
        );
        _migrationCompleted = true;
        _migrationBlocked.clear();
        _confirmed.clear();
        _origins.clear();
        _changed();
      } catch (_) {
        // An incomplete migration never grants new live sharing. Retry can
        // resume missing writes from its durable, original population.
        _migrationBlocked.addAll(present);
        await _reload();
        _changed();
        throw const SettingsFailure(SettingsFailureReason.storageFailed);
      } finally {
        for (final id in present) {
          _pendingCount[id] = (_pendingCount[id] ?? 1) - 1;
        }
        if (present.isNotEmpty) _changed();
      }
    });
  }

  Future<void> setEnabled(String profileId, bool value) =>
      setEnabledIfCurrent(profileId, value, isCurrent: () => true);

  /// Integration guard: a captured editor cannot authorize a replacement owner.
  Future<void> setEnabledIfCurrent(
    String profileId,
    bool value, {
    required bool Function() isCurrent,
  }) {
    if (profileId.isEmpty || _closed.contains(profileId) || !isCurrent()) {
      return Future.error(
        const SettingsFailure(SettingsFailureReason.staleTarget),
      );
    }
    final generation = (_generations[profileId] ?? 0) + 1;
    _generations[profileId] = generation;
    _pendingCount.update(profileId, (n) => n + 1, ifAbsent: () => 1);
    // Even a failed opt-out stays private; opt-in never authorizes early.
    _private.add(profileId);
    _changed();
    return _enqueue(() async {
      try {
        if (_closed.contains(profileId) || !isCurrent()) {
          throw const SettingsFailure(SettingsFailureReason.staleTarget);
        }
        // Remember what the carried-over value was before it is replaced.
        if (!_prefs.containsKey(defaultKey(profileId))) {
          await _accepted(
            _prefs.setBool(defaultKey(profileId), defaultFor(profileId)),
          );
        }
        await _accepted(_prefs.setString(originKey(profileId), 'explicit'));
        await _accepted(_prefs.setBool(preferenceKey(profileId), value));
        if (_closed.contains(profileId) || !isCurrent()) {
          // The write may have reached disk; erase its authorization before a restart.
          try {
            await _accepted(_prefs.setBool(preferenceKey(profileId), false));
          } catch (_) {}
          throw const SettingsFailure(SettingsFailureReason.staleTarget);
        }
        if (_generations[profileId] == generation) {
          _confirmed[profileId] = value;
          _origins[profileId] = SettingOriginKind.explicitValue;
          _private.remove(profileId);
        }
      } catch (error) {
        await _reload();
        if (error is SettingsFailure &&
            error.reason == SettingsFailureReason.staleTarget) {
          rethrow;
        }
        throw const SettingsFailure(SettingsFailureReason.storageFailed);
      } finally {
        _pendingCount[profileId] = (_pendingCount[profileId] ?? 1) - 1;
        _changed();
      }
    });
  }

  /// Close synchronously, then drain accepted writes and prune shared metadata.
  /// ProfileStore's standard sweep removes the actual per-profile keys next.
  Future<void> closeProfile(String profileId) {
    _closed.add(profileId);
    _private.add(profileId);
    _confirmed.remove(profileId);
    _origins.remove(profileId);
    _generations.update(profileId, (n) => n + 1, ifAbsent: () => 1);
    _changed();
    return _enqueue(() async {
      try {
        final raw = _prefs.get(migrationKey);
        if (raw is String) {
          final data = jsonDecode(raw);
          if (data is! Map<String, dynamic> || data['ids'] is! List) {
            throw const SettingsFailure(SettingsFailureReason.storageFailed);
          }
          final ids = data['ids'] as List;
          if (ids.contains(profileId)) {
            data['ids'] = ids.where((id) => id != profileId).toList();
            await _accepted(_prefs.setString(migrationKey, jsonEncode(data)));
          }
        }
      } catch (_) {
        await _reload();
        throw const SettingsFailure(SettingsFailureReason.storageFailed);
      }
    });
  }

  /// Failed deletion may reopen editing, but cannot restore automatic sharing.
  void reopenProfile(String profileId) {
    _closed.remove(profileId);
    _confirmed.remove(profileId);
    _origins.remove(profileId);
    _changed();
  }
}
