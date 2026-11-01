import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Device-only favorites, isolated by server profile and selected location.
class SessionPinStore {
  SessionPinStore(this.preferences);
  final SharedPreferences preferences;
  final _cache = <String, Map<String, Set<String>>>{};
  final _writes = <String, Future<void>>{};
  // Row membership checks repeat this pair thousands of times per build.
  // Retain only the latest pair, rather than every location ever queried.
  static ({String? directory, String? workspace, String encoded})? _lastScope;

  static String scope(String? directory, String? workspace) {
    final previous = _lastScope;
    if (previous != null &&
        previous.directory == directory &&
        previous.workspace == workspace) {
      return previous.encoded;
    }
    final encoded = jsonEncode([directory, workspace]);
    _lastScope = (directory: directory, workspace: workspace, encoded: encoded);
    return encoded;
  }

  Map<String, Set<String>> _load(String profile) =>
      _cache.putIfAbsent(profile, () {
        try {
          final value = jsonDecode(
            preferences.getString('oc.sessionPins.$profile') ?? '{}',
          );
          if (value is Map) {
            return {
              for (final entry in value.entries)
                if (entry.key is String && entry.value is List)
                  entry.key as String: Set<String>.unmodifiable(
                    (entry.value as List).whereType<String>().where(
                      (id) => id.isNotEmpty,
                    ),
                  ),
            };
          }
        } catch (_) {}
        return {};
      });

  Set<String> ids(String profile, String scope) =>
      _load(profile)[scope] ?? const <String>{};

  Future<void> setPinned(
    String profile,
    String scope,
    String id,
    bool pinned,
  ) async {
    final previous = _writes[profile] ?? Future<void>.value();
    final writing = previous.catchError((Object _) {}).then((_) async {
      final next = {
        for (final entry in _load(profile).entries) entry.key: {...entry.value},
      };
      final entries = next.putIfAbsent(scope, () => <String>{});
      pinned ? entries.add(id) : entries.remove(id);
      if (entries.isEmpty) next.remove(scope);
      final saved = await preferences.setString(
        'oc.sessionPins.$profile',
        jsonEncode({
          for (final entry in next.entries) entry.key: entry.value.toList(),
        }),
      );
      if (!saved) throw StateError('Could not save pinned conversations');
      // Only show a persistent pin after storage acknowledges the write.
      // Every published set is an immutable snapshot. Reuse it for reads,
      // while retaining the previous snapshot until the write succeeds.
      _cache[profile] = {
        for (final entry in next.entries)
          entry.key: Set<String>.unmodifiable(entry.value),
      };
    });
    _writes[profile] = writing;
    try {
      await writing;
    } finally {
      if (identical(_writes[profile], writing)) _writes.remove(profile);
    }
  }

  Future<void> drain(String profile) =>
      _writes[profile] ?? Future<void>.value();
  void forget(String profile) {
    _cache.remove(profile);
    // A deleted profile must not leave its location in the process-wide memo.
    _lastScope = null;
  }
}
