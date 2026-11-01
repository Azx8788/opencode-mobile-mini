import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/models.dart';
import '../ui/kit/kit_redact.dart';

/// Text-only last-known opening content. Never merge this into authoritative
/// history: tools, reasoning, attachments and older-history cursors are absent.
class SessionTailPreview {
  final DateTime fetchedAt;
  final List<SessionTailText> messages;
  const SessionTailPreview(this.fetchedAt, this.messages);
}

class SessionTailText {
  final String id;
  final String role;
  final String text;
  const SessionTailText(this.id, this.role, this.text);
}

/// One most-recent conversation per profile, max 12 text excerpts of 1,000
/// Unicode scalars each. All output is redacted before it reaches disk.
class SessionTailCache {
  SessionTailCache(this.prefs);
  final SharedPreferences prefs;
  final _writes = <String, Future<void>>{};
  final _decoded = <String, (String, String, String, SessionTailPreview)>{};
  static String keyFor(String id) => 'oc.chatTail.$id';

  SessionTailPreview? read(String profile, String scope, String session) {
    try {
      final raw = prefs.getString(keyFor(profile));
      if (raw == null || raw.length > 100000) return null;
      final previous = _decoded[profile];
      if (previous != null &&
          previous.$1 == raw &&
          previous.$2 == scope &&
          previous.$3 == session) {
        return previous.$4;
      }
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['v'] != 1 ||
          data['scope'] != scope ||
          data['session'] != session) {
        return null;
      }
      final rows = data['rows'] as List;
      if (rows.length > 12) return null;
      final preview = SessionTailPreview(
        DateTime.fromMillisecondsSinceEpoch(data['at'] as int),
        List.unmodifiable(
          rows.map(
            (row) => SessionTailText(
              row['id'] as String,
              row['role'] as String,
              row['text'] as String,
            ),
          ),
        ),
      );
      _decoded[profile] = (raw, scope, session, preview);
      return preview;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(
    String profile,
    String scope,
    String session,
    List<MessageWithParts> messages, {
    required bool Function() isCurrent,
  }) {
    final rows = <Map<String, String>>[];
    // Walk the newest end first; keep only a small read-only excerpt. Do not
    // retain live mutable MessageWithParts objects or tool input/output maps.
    for (final message in messages.reversed) {
      if (rows.length == 12) break;
      if (message.info.sessionID != session ||
          message.info.id.length > 512 ||
          !const ['user', 'assistant'].contains(message.info.role)) {
        continue;
      }
      final text = StringBuffer();
      for (final part in message.parts) {
        if (part.type != 'text' ||
            part.synthetic ||
            part.text.isEmpty ||
            part.text.length > 16384) {
          continue;
        }
        final safe = KitRedact.text(part.text);
        if (text.isNotEmpty) text.write('\n');
        text.write(String.fromCharCodes(safe.runes.take(1000)));
        if (text.length >= 1000) break;
      }
      if (text.isEmpty) continue;
      rows.add({
        'id': message.info.id,
        'role': message.info.role,
        'text': String.fromCharCodes(text.toString().runes.take(1000)),
      });
    }
    final raw = jsonEncode({
      'v': 1,
      'scope': scope,
      'session': session,
      'at': DateTime.now().millisecondsSinceEpoch,
      'rows': rows.reversed.toList(),
    });
    final write = (_writes[profile] ?? Future<void>.value()).then((_) async {
      if (!isCurrent()) return;
      try {
        if (!await prefs.setString(keyFor(profile), raw)) await prefs.reload();
      } catch (_) {
        try {
          await prefs.reload();
        } catch (_) {}
      }
    });
    _writes[profile] = write;
    return write;
  }

  Future<void> removeSession(String profile, String session) {
    final write = (_writes[profile] ?? Future<void>.value()).then((_) async {
      try {
        final raw = prefs.getString(keyFor(profile));
        if (raw == null) return;
        final data = jsonDecode(raw) as Map<String, dynamic>;
        if (data['session'] == session) await prefs.remove(keyFor(profile));
      } catch (_) {
        // Optional preview cleanup must not replace the server delete result.
      }
      forget(profile);
    });
    _writes[profile] = write;
    return write;
  }

  void forget(String profile) => _decoded.remove(profile);
  Future<void> drain(String profile) =>
      _writes[profile] ?? Future<void>.value();
}
