import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The last context-window share seen for each conversation of one server,
/// so the chats list can show a small ring without opening every chat or
/// fetching any messages. A chat that was open leaves its value here; one
/// never opened has none and shows no ring.
///
/// Stored under `oc.contextUsage.<profileId>` (a fraction per session id,
/// newest 200 kept) so `ProfileStore.profileScopedPreferenceKeys` sweeps it
/// with the profile. [closeProfile] stops admission and drains writes before
/// that sweep, so a late write cannot bring a deleted server's values back.
class ContextUsageMemory {
  factory ContextUsageMemory.forProfile(
    SharedPreferences preferences,
    String profileId,
  ) {
    final owners = _shared[preferences] ??= {};
    return owners[profileId] ??= ContextUsageMemory._(preferences, profileId);
  }

  ContextUsageMemory._(this._preferences, this._profileId);

  static final _shared = Expando<Map<String, ContextUsageMemory>>();
  static const maxEntries = 200;

  static String keyFor(String profileId) => 'oc.contextUsage.$profileId';

  final SharedPreferences _preferences;
  final String _profileId;
  Map<String, double>? _values;
  Future<void> _pending = Future<void>.value();
  bool _closed = false;

  /// Stops admission, then waits for writes already running.
  static Future<void> closeProfile(SharedPreferences preferences, String id) {
    final owner = ContextUsageMemory.forProfile(preferences, id);
    owner._closed = true;
    return owner._pending;
  }

  Map<String, double> get _map => _values ??= _read();

  Map<String, double> _read() {
    try {
      final raw = _preferences.getString(keyFor(_profileId));
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is Map) {
        return {
          for (final entry in decoded.entries)
            if (entry.key is String && entry.value is num)
              entry.key as String: (entry.value as num).toDouble(),
        };
      }
    } catch (_) {}
    return {};
  }

  /// The last share seen for [sessionID], or null.
  double? usageOf(String sessionID) => _closed ? null : _map[sessionID];

  /// Remembers [fraction] (null forgets it). Only a change is written.
  void remember(String sessionID, double? fraction) {
    if (_closed || _profileId.isEmpty || sessionID.isEmpty) return;
    final map = _map;
    final value = fraction == null || !fraction.isFinite
        ? null
        : double.parse(fraction.clamp(0.0, 1.0).toStringAsFixed(3));
    if (map[sessionID] == value) return;
    // Re-inserting keeps the insertion order newest-last, so the oldest
    // entries are the ones dropped at the cap.
    map.remove(sessionID);
    if (value != null) map[sessionID] = value;
    while (map.length > maxEntries) {
      map.remove(map.keys.first);
    }
    final text = jsonEncode(map);
    _pending = _pending.then((_) async {
      if (_closed) return;
      try {
        await _preferences.setString(keyFor(_profileId), text);
      } catch (_) {}
    });
  }
}
