import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/models.dart';
import '../platform/platform_capabilities.dart';
import '../domain/session_title_text.dart';

/// Publishes the connected profile's pinned sessions as dynamic launcher
/// shortcuts (long-press the app icon) and remembers what was published so
/// the entries can be withdrawn when the profile disconnects or is deleted.
///
/// Privacy mirrors the home-screen widget snapshot: the launcher menu is a
/// surface the user reaches deliberately and it shows exactly the titles the
/// app's own session list shows — never prompt text, tool input, file names
/// or server errors. Each entry carries only the IDs routing needs; tapping
/// one opens that chat and nothing is ever sent on the user's behalf.
class PinnedSessionShortcuts {
  PinnedSessionShortcuts({
    required this.prefs,
    Future<void> Function(Map<String, Object?> payload)? publishNative,
    bool? isAndroid,
  }) : _publishNative = publishNative ?? _publishViaChannel,
       _isAndroid = isAndroid ?? platformCapabilities.supportsLaunchShortcuts;

  /// Where the last published payload is remembered, so a later process can
  /// tell whose shortcuts are on the launcher without asking native.
  static const prefsKey = 'oc.pinnedShortcuts';

  /// At most this many pinned sessions are ever published.
  static const maxShortcuts = 4;

  /// Titles longer than this are cut before they leave the app; launchers
  /// truncate far earlier, and the payload stays small.
  static const maxTitleLength = 80;

  static const _channel = MethodChannel('oc/shortcut');

  final SharedPreferences prefs;
  final Future<void> Function(Map<String, Object?> payload) _publishNative;
  final bool _isAndroid;
  String? _lastPublished;

  static Future<void> _publishViaChannel(Map<String, Object?> payload) async {
    try {
      await _channel.invokeMethod<Object?>('setPinnedSessions', payload);
    } catch (_) {
      // No engine-side handler (tests, desktop, activity gone): the launcher
      // simply keeps its last state.
    }
  }

  /// Serializes [sessions] (already in pin order, already limited to the
  /// active profile and location) and publishes only when the payload
  /// actually changed, so frequent controller notifications stay cheap.
  ///
  /// [untitledLabel] is the localized fallback for a session without a
  /// title; the controller supplies it because this writer has no widget
  /// tree to read a locale from.
  Future<void> update({
    required List<Session> sessions,
    required String profileID,
    required String untitledLabel,
  }) async {
    if (!_isAndroid) return;
    final payload = _payload(
      profileID: profileID,
      sessions: [
        for (final session in sessions.take(maxShortcuts))
          if (session.id.trim().isNotEmpty)
            {'id': session.id, 'title': _title(session.title, untitledLabel)},
      ],
    );
    await _publish(payload);
  }

  /// Withdraws every published shortcut. Used on an explicit disconnect: a
  /// launcher entry that opens a server the user just left is a stale promise.
  Future<void> clear() async {
    if (!_isAndroid) return;
    await _publish(_payload(profileID: '', sessions: const []));
  }

  /// Withdraws the shortcuts when they belong to [profileID], so removing a
  /// server also removes the session titles its launcher menu was still
  /// showing. A payload written without an owner is withdrawn too.
  ///
  /// Runs on every platform: the stored payload is the privacy-relevant
  /// artifact, and only the native publish is Android-specific.
  Future<PinnedShortcutClear> clearForProfile(String profileID) async {
    final raw = prefs.getString(prefsKey);
    if (raw == null) return PinnedShortcutClear.nothingToClear;
    String? owner;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) owner = decoded['profileID']?.toString() ?? '';
    } catch (_) {
      // Unreadable payload: it cannot be shown to be another profile's, so
      // treat it as removable rather than leaving it behind.
      owner = '';
    }
    if (owner == null || (owner.isNotEmpty && owner != profileID)) {
      return PinnedShortcutClear.nothingToClear;
    }
    try {
      if (!await prefs.remove(prefsKey)) return PinnedShortcutClear.failed;
    } catch (_) {
      return PinnedShortcutClear.failed;
    }
    _lastPublished = null;
    if (_isAndroid) {
      await _publishNative(_payload(profileID: '', sessions: const []));
    }
    return PinnedShortcutClear.cleared;
  }

  Future<void> _publish(Map<String, Object?> payload) async {
    final encoded = jsonEncode(payload);
    if (encoded == _lastPublished) return;
    _lastPublished = encoded;
    final empty = (payload['sessions'] as List).isEmpty;
    if (empty) {
      await prefs.remove(prefsKey);
    } else if (prefs.getString(prefsKey) != encoded) {
      await prefs.setString(prefsKey, encoded);
    }
    await _publishNative(payload);
  }

  static Map<String, Object?> _payload({
    required String profileID,
    required List<Map<String, String>> sessions,
  }) => {'profileID': profileID, 'sessions': sessions};

  static String _title(String? title, String untitledLabel) {
    final trimmed = displaySessionTitleText(title);
    if (trimmed.isEmpty) return untitledLabel;
    if (trimmed.length <= maxTitleLength) return trimmed;
    return trimmed.substring(0, maxTitleLength).trimRight();
  }
}

/// What [PinnedSessionShortcuts.clearForProfile] actually did.
enum PinnedShortcutClear {
  /// No published shortcuts, or another profile's: nothing was at risk.
  nothingToClear,

  /// The profile's shortcuts are withdrawn and its record is gone from disk.
  cleared,

  /// The record is still on disk — the store refused the write. The caller
  /// must not report the data as deleted.
  failed,
}
