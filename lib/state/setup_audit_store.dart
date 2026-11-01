import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/setup_assistant.dart';
import '../ui/kit/kit_redact.dart';

/// One metadata-only writer per profile, shared by every setup controller.
/// No configuration, credential, server location or Undo handle belongs here.
class SetupAuditStore {
  factory SetupAuditStore.forProfile(
    SharedPreferences preferences,
    String profileId,
  ) {
    if (profileId.isEmpty || KitRedact.containsSecret(profileId)) {
      throw const SetupFailure(
        SetupFailureCode.storage,
        'Setup history is unavailable.',
      );
    }
    final owners = _shared[preferences] ??= {};
    return owners[profileId] ??= SetupAuditStore._(preferences, profileId);
  }

  SetupAuditStore._(this._preferences, this._profileId);

  static final _shared = Expando<Map<String, SetupAuditStore>>();
  static const _actions = {
    'proposed',
    'pending',
    'accepted',
    'verified',
    'uncertain',
    'rejected',
  };
  static const _operations = {'apply', 'undo', 'review'};
  static final _idPattern = RegExp(
    r'^(?:(?:proposal|undo)-[0-9]+|[0-9a-f]{48}|(?:proposal-)?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$',
  );
  static const _storageFailure = SetupFailure(
    SetupFailureCode.storage,
    'Setup history could not be saved. Refresh before trying again.',
  );
  static const _closedFailure = SetupFailure(
    SetupFailureCode.offline,
    'Setup is unavailable for this server.',
  );

  final SharedPreferences _preferences;
  final String _profileId;
  Future<void> _pending = Future<void>.value();
  bool _closed = false;
  bool _reloadFailed = false;

  String get _key => 'oc.setupAudit.$_profileId';

  /// Stops admission before returning, then drains already running writes.
  /// Keep the closed owner registered until restart so a new controller cannot
  /// reopen admission between the key sweep and profile metadata removal.
  static Future<void> closeProfile(SharedPreferences preferences, String id) {
    final owner = SetupAuditStore.forProfile(preferences, id);
    owner._closed = true;
    return owner._pending;
  }

  bool get _present {
    try {
      final raw = _preferences.getString('oc.profiles');
      if (raw == null) return false;
      final profiles = jsonDecode(raw);
      return profiles is List &&
          profiles.any(
            (profile) => profile is Map && profile['id'] == _profileId,
          );
    } catch (_) {
      return false;
    }
  }

  bool get isAvailable =>
      !_closed && !_reloadFailed && _present && _readRecords() != null;

  /// Invalid stored text is never promoted to presentation data. An unreadable
  /// history remains unavailable and cannot be overwritten by a fresh append.
  List<Map<String, Object?>> get records {
    if (_closed || !_present || _reloadFailed) return const [];
    return _readRecords() ?? const [];
  }

  List<Map<String, Object?>>? _readRecords() {
    try {
      final raw = _preferences.getString(_key);
      if (raw == null) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final result = <Map<String, Object?>>[];
      for (final record in decoded) {
        if (record is! Map ||
            record.keys.any(
              (key) =>
                  key != 'id' &&
                  key != 'action' &&
                  key != 'at' &&
                  key != 'operation',
            )) {
          return null;
        }
        final id = record['id'];
        final action = record['action'];
        final at = record['at'];
        final operation = record['operation'];
        if (id is! String ||
            !_validId(id) ||
            !_actions.contains(action) ||
            at is! String ||
            at.length > 40 ||
            (operation != null && !_operations.contains(operation))) {
          return null;
        }
        final timestamp = DateTime.tryParse(at);
        if (timestamp == null || !timestamp.isUtc) return null;
        result.add(
          Map<String, Object?>.unmodifiable({
            'id': id,
            'action': action as String,
            'at': timestamp.toUtc().toIso8601String(),
            if (operation != null) 'operation': operation as String,
          }),
        );
      }
      return List.unmodifiable(
        result.length > 100 ? result.sublist(result.length - 100) : result,
      );
    } catch (_) {
      return null;
    }
  }

  static bool _validId(String id) =>
      _idPattern.hasMatch(id) && !KitRedact.containsSecret(id);

  void _checkAdmission() {
    if (_closed || !_present) throw _closedFailure;
    if (_reloadFailed || _readRecords() == null) throw _storageFailure;
  }

  Future<void> append(String id, String action, {String? operation}) {
    try {
      _checkAdmission();
      if (!_validId(id) ||
          !_actions.contains(action) ||
          (operation != null && !_operations.contains(operation))) {
        throw _storageFailure;
      }
    } catch (error, stack) {
      return Future<void>.error(error, stack);
    }
    final result = _pending.then((_) async {
      _checkAdmission();
      final previous = _readRecords()!;
      final next = <Map<String, Object?>>[
        ...previous,
        {
          'id': id,
          'action': action,
          'at': DateTime.now().toUtc().toIso8601String(),
          'operation': ?operation,
        },
      ];
      final bounded = next.length > 100
          ? next.sublist(next.length - 100)
          : next;
      try {
        if (await _preferences.setString(_key, jsonEncode(bounded))) return;
      } catch (_) {
        // A platform error can include its payload; never retain that error.
      }
      // SharedPreferences updates the cache before the platform accepts a write.
      // Reload before allowing a retry to trust the previous durable history.
      try {
        await _preferences.reload();
      } catch (_) {
        _reloadFailed = true;
      }
      throw _storageFailure;
    });
    _pending = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
