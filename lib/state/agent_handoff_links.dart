import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../ui/kit/kit_redact.dart';
import '../domain/agent_handoff.dart' show HandoffOrigin;

/// Navigation metadata only: never stores prompts, transcripts or credentials.
class HandoffLink {
  const HandoffLink({
    required this.id,
    required this.sourceProfileId,
    required this.sourceSessionId,
    this.sourceOrigin = HandoffOrigin.server,
    required this.sourceTitle,
    required this.targetProfileId,
    required this.targetSessionId,
    this.targetOrigin = HandoffOrigin.server,
    required this.targetAgent,
    required this.projectDirectory,
    required this.handoffPath,
  });

  final String id;
  final String sourceProfileId;
  final String sourceSessionId;
  final HandoffOrigin sourceOrigin;
  final String sourceTitle;
  final String targetProfileId;
  final String targetSessionId;
  final HandoffOrigin targetOrigin;
  final String targetAgent;
  final String projectDirectory;
  final String handoffPath;

  Map<String, Object> _json() => {
    'id': id,
    'sourceProfileId': sourceProfileId,
    'sourceSessionId': sourceSessionId,
    'sourceOrigin': sourceOrigin.name,
    'sourceTitle': KitRedact.text(sourceTitle),
    'targetProfileId': targetProfileId,
    'targetSessionId': targetSessionId,
    'targetOrigin': targetOrigin.name,
    'targetAgent': KitRedact.text(targetAgent),
    'projectDirectory': KitRedact.text(projectDirectory),
    'handoffPath': KitRedact.text(handoffPath),
  };

  static HandoffLink _decode(Object? value) {
    if (value is! Map) throw const FormatException();
    String field(String name) {
      final text = value[name];
      if (text is! String || text.length > 4096) {
        throw const FormatException();
      }
      return KitRedact.text(text);
    }

    HandoffOrigin origin(String name) {
      final raw = value[name];
      // Records written before runtime origins were explicit are server links.
      if (raw == null) return HandoffOrigin.server;
      return HandoffOrigin.values.firstWhere(
        (origin) => origin.name == raw,
        orElse: () => throw const FormatException(),
      );
    }

    final link = HandoffLink(
      id: field('id'),
      sourceProfileId: field('sourceProfileId'),
      sourceSessionId: field('sourceSessionId'),
      sourceOrigin: origin('sourceOrigin'),
      sourceTitle: field('sourceTitle'),
      targetProfileId: field('targetProfileId'),
      targetSessionId: field('targetSessionId'),
      targetOrigin: origin('targetOrigin'),
      targetAgent: field('targetAgent'),
      projectDirectory: field('projectDirectory'),
      handoffPath: field('handoffPath'),
    );
    for (final name in const [
      'id',
      'sourceProfileId',
      'sourceSessionId',
      'targetProfileId',
      'targetSessionId',
    ]) {
      final original = value[name] as String;
      if (original.isEmpty ||
          original.length > 256 ||
          KitRedact.text(original) != original ||
          original.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
        throw const FormatException();
      }
    }
    return link;
  }
}

/// One serialized writer per preferences instance. Each link has one canonical
/// copy under its source profile; both conversations discover it through
/// [forSession]. This avoids a partially persisted pair of navigation links.
/// Removing either profile removes its references from every surviving owner.
class AgentHandoffLinks {
  AgentHandoffLinks._(this._prefs);

  static final _owners = Expando<AgentHandoffLinks>();
  static AgentHandoffLinks forPreferences(SharedPreferences prefs) =>
      _owners[prefs] ??= AgentHandoffLinks._(prefs);
  static const _prefix = 'oc.agentHandoffs.';
  static String keyFor(String profileId) => '$_prefix$profileId';

  final SharedPreferences _prefs;
  final Set<String> _closed = {};
  final Map<String, int> _epochs = {};
  Future<void> _tail = Future<void>.value();
  bool _readable = true;

  bool _hasProfile(String profileId) {
    try {
      final rows = jsonDecode(_prefs.getString('oc.profiles') ?? '[]');
      return rows is List &&
          rows.any((row) => row is Map && row['id'] == profileId);
    } catch (_) {
      return false;
    }
  }

  void _checkProfile(String profileId, [int? epoch]) {
    if (_closed.contains(profileId) ||
        !_hasProfile(profileId) ||
        (epoch != null && epoch != (_epochs[profileId] ?? 0))) {
      throw StateError('The conversation profile is unavailable');
    }
  }

  /// Synchronous admission check, independent of link-storage readability.
  /// Use at the final dispatch fence; it remains closed during deletion.
  void checkProfiles(String sourceProfileId, String targetProfileId) {
    _checkProfile(sourceProfileId);
    _checkProfile(targetProfileId);
  }

  List<HandoffLink> _read(String key) {
    final raw = _prefs.getString(key);
    if (raw == null) return [];
    try {
      if (raw.length > 4 * 1024 * 1024) throw const FormatException();
      final envelope = jsonDecode(raw);
      if (envelope is! Map ||
          envelope['version'] != 1 ||
          envelope['links'] is! List) {
        throw const FormatException();
      }
      final links = (envelope['links'] as List)
          .map(HandoffLink._decode)
          .toList();
      if (links.any((link) => keyFor(link.sourceProfileId) != key)) {
        throw const FormatException();
      }
      return links;
    } catch (_) {
      throw StateError('Could not read conversation links');
    }
  }

  /// Includes outgoing and incoming links, in insertion order within an owner.
  /// The UI refreshes after save completes; this store keeps no transcript cache.
  /// [profileId] is always a durable parent profile. Pass [origin] when an
  /// agent and server conversation can share the same session identifier.
  List<HandoffLink> forSession(
    String profileId,
    String sessionId, {
    HandoffOrigin? origin,
  }) {
    _checkProfile(profileId);
    if (!_readable) throw StateError('Could not read conversation links');
    return List.unmodifiable([
      for (final key in _prefs.getKeys().where(
        (key) => key.startsWith(_prefix),
      ))
        for (final link in _read(key))
          if (!_closed.contains(link.sourceProfileId) &&
              !_closed.contains(link.targetProfileId) &&
              _hasProfile(link.sourceProfileId) &&
              _hasProfile(link.targetProfileId) &&
              ((link.sourceProfileId == profileId &&
                      link.sourceSessionId == sessionId &&
                      (origin == null || link.sourceOrigin == origin)) ||
                  (link.targetProfileId == profileId &&
                      link.targetSessionId == sessionId &&
                      (origin == null || link.targetOrigin == origin))))
            link,
    ]);
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> _reload() async {
    try {
      await _prefs.reload();
      _readable = true;
    } catch (_) {
      _readable = false;
      throw StateError('Could not read conversation links');
    }
  }

  Future<void> _write(String key, List<HandoffLink> links) async {
    final encoded = links.isEmpty
        ? null
        : jsonEncode({
            'version': 1,
            'links': links.map((l) => l._json()).toList(),
          });
    if (encoded != null && encoded.length > 4 * 1024 * 1024) {
      throw StateError('Conversation link storage is full');
    }
    _readable = false;
    try {
      final saved = encoded == null
          ? await _prefs.remove(key)
          : await _prefs.setString(key, encoded);
      if (!saved) throw const FormatException();
      await _prefs.reload();
      if (_prefs.getString(key) != encoded) throw const FormatException();
      _readable = true;
    } catch (_) {
      _readable = false;
      // SharedPreferences writes its cache before persistence is confirmed.
      try {
        await _prefs.reload();
      } catch (_) {}
      throw StateError('Could not save conversation links');
    }
  }

  /// Idempotent for an identical ID and record; conflicting IDs are rejected.
  /// Only call after the new conversation exists. A storage failure must be
  /// surfaced separately from creation so a retry never creates another chat.
  Future<void> save(HandoffLink link) async {
    // Validate original IDs before redaction could turn an unsafe ID into one.
    final original = {
      ...link._json(),
      'id': link.id,
      'sourceProfileId': link.sourceProfileId,
      'sourceSessionId': link.sourceSessionId,
      'targetProfileId': link.targetProfileId,
      'targetSessionId': link.targetSessionId,
    };
    final checked = HandoffLink._decode(original);
    _checkProfile(checked.sourceProfileId);
    _checkProfile(checked.targetProfileId);
    final sourceEpoch = _epochs[checked.sourceProfileId] ?? 0;
    final targetEpoch = _epochs[checked.targetProfileId] ?? 0;
    await _serialize(() async {
      await _reload();
      _checkProfile(checked.sourceProfileId, sourceEpoch);
      _checkProfile(checked.targetProfileId, targetEpoch);
      final key = keyFor(checked.sourceProfileId);
      final links = _read(key);
      for (final existing in links) {
        if (existing.id != checked.id) continue;
        if (jsonEncode(existing._json()) != jsonEncode(checked._json())) {
          throw StateError('This conversation link already exists');
        }
        return;
      }
      await _write(key, [...links, checked]);
      _checkProfile(checked.sourceProfileId, sourceEpoch);
      _checkProfile(checked.targetProfileId, targetEpoch);
    });
  }

  /// Closes admission synchronously; drain before the profile preference sweep.
  static Future<void> closeProfile(SharedPreferences prefs, String profileId) {
    final owner = forPreferences(prefs);
    owner._closed.add(profileId);
    owner._epochs[profileId] = (owner._epochs[profileId] ?? 0) + 1;
    return owner._tail;
  }

  /// May partially remove links on failure, but never claims successful cleanup.
  /// Retry is idempotent. No new link involving the closing profile is admitted.
  static Future<void> removeProfile(SharedPreferences prefs, String profileId) {
    closeProfile(prefs, profileId);
    final owner = forPreferences(prefs);
    return owner._serialize(() async {
      await owner._reload();
      final keys = prefs
          .getKeys()
          .where((key) => key.startsWith(_prefix))
          .toList();
      for (final key in keys) {
        if (key == keyFor(profileId)) {
          await owner._write(key, []);
          continue;
        }
        final links = owner._read(key);
        final kept = links
            .where((link) => link.targetProfileId != profileId)
            .toList();
        if (kept.length != links.length) await owner._write(key, kept);
      }
    });
  }

  /// Called only when deletion was aborted and the profile still exists.
  static Future<void> cancelDeletion(
    SharedPreferences prefs,
    String profileId,
  ) async {
    final owner = forPreferences(prefs);
    final epoch = owner._epochs[profileId];
    await owner._tail;
    try {
      await owner._reload();
      if (owner._epochs[profileId] == epoch && owner._hasProfile(profileId)) {
        owner._closed.remove(profileId);
      }
    } catch (_) {
      // Uncertain durable membership keeps admission closed.
    }
  }
}
