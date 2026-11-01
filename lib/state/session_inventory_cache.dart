import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/models.dart';
import '../ui/kit/kit_redact.dart';
import 'profiles.dart';

/// Last-known labels for a read-only opening shell, never live session truth.
class SessionInventoryPreview {
  final DateTime fetchedAt;
  final List<SessionPreview> sessions;
  const SessionInventoryPreview(this.fetchedAt, this.sessions);
}

class SessionPreview {
  final String id;
  final String title;
  final int updated;
  const SessionPreview(this.id, this.title, this.updated);
}

/// One bounded location per profile. No prompts, auth, status, permission or
/// capability evidence is persisted. The deletion controller drains writes
/// before ProfileStore's `oc.<what>.<profileId>` sweep.
class SessionInventoryCache {
  SessionInventoryCache(this.prefs);
  final SharedPreferences prefs;
  static const maxSessions = 100;
  static const maxBytes = 65536;
  final _writes = <String, Future<void>>{};
  final _decoded = <String, (String, SessionInventoryPreview)>{};

  static String keyFor(String profileID) => 'oc.sessionInventory.$profileID';

  static String scopeFor(
    ServerProfile profile,
    String? directory,
    String? workspace,
  ) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            profile.backend.name,
            profile.flavor.name,
            profile.baseUrl,
            profile.username,
            directory,
            workspace,
          ]),
        ),
      )
      .toString();

  SessionInventoryPreview? read(String profileID, String scope) {
    try {
      final raw = prefs.getString(keyFor(profileID));
      if (raw == null || raw.length > maxBytes) return null;
      final previous = _decoded[profileID];
      final json = previous?.$1 == raw
          ? null
          : jsonDecode(raw) as Map<String, dynamic>;
      if (json == null) {
        // Scope remains part of the encoded owner. A changed location must
        // not reuse a decoded snapshot just because its profile ID matches.
        if (_scopes[profileID] == scope) return previous!.$2;
        return null;
      }
      if (json['v'] != 1 || json['scope'] != scope) return null;
      final rows = json['rows'] as List;
      if (rows.length > maxSessions) return null;
      final snapshot = SessionInventoryPreview(
        DateTime.fromMillisecondsSinceEpoch(json['at'] as int),
        List.unmodifiable(
          rows.map(
            (row) => SessionPreview(
              row['id'] as String,
              row['title'] as String,
              row['updated'] as int,
            ),
          ),
        ),
      );
      _decoded[profileID] = (raw, snapshot);
      _scopes[profileID] = scope;
      return snapshot;
    } catch (_) {
      return null;
    }
  }

  final _scopes = <String, String>{};

  Future<void> save(
    String profileID,
    String scope,
    List<Session> sessions, {
    required bool Function() isCurrent,
    DateTime? fetchedAt,
  }) {
    // Snapshot primitive values now; a deferred write never reads another
    // connection's session map. Truncate display copy, never server IDs.
    final rows = <Map<String, Object>>[];
    var rowBytes = 0;
    for (final session in sessions.take(maxSessions)) {
      if (session.id.isEmpty || session.id.length > 512) continue;
      final safe = KitRedact.text(session.title ?? '');
      final row = <String, Object>{
        'id': session.id,
        'title': String.fromCharCodes(safe.runes.take(256)),
        'updated': session.time?.updated ?? session.time?.created ?? 0,
      };
      final bytes = utf8.encode(jsonEncode(row)).length;
      if (rowBytes + bytes > maxBytes - 512) break;
      rowBytes += bytes + 1;
      rows.add(row);
    }
    final raw = jsonEncode({
      'v': 1,
      'scope': scope,
      'at': (fetchedAt ?? DateTime.now()).millisecondsSinceEpoch,
      'rows': rows,
    });
    final pending = (_writes[profileID] ?? Future<void>.value()).then((
      _,
    ) async {
      if (!isCurrent()) return;
      try {
        if (!await prefs.setString(keyFor(profileID), raw)) {
          // SharedPreferences updates its memory cache even on a refused
          // platform write. Reload rather than presenting an unpersisted row.
          await prefs.reload();
        }
      } catch (_) {
        try {
          await prefs.reload();
        } catch (_) {}
      }
      forget(profileID);
    });
    _writes[profileID] = pending;
    return pending;
  }

  Future<void> drain(String profileID) =>
      _writes[profileID] ?? Future<void>.value();
  void forget(String profileID) {
    _decoded.remove(profileID);
    _scopes.remove(profileID);
  }
}
