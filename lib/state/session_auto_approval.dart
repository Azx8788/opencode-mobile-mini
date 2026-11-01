import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How this phone answers permission requests for one session while the app
/// is connected.
///
/// [autoOnce] replies "once" to every incoming permission request. It never
/// replies "always": a saved rule would outlive the session and this device,
/// while a per-request "once" leaves the server's own allow and deny rules
/// exactly as they were.
enum AutoApprovalMode { ask, autoOnce }

/// One session's explicit approval setting.
@immutable
class SessionAutoApproval {
  const SessionAutoApproval({
    this.mode = AutoApprovalMode.ask,
    this.inheritToChildren = false,
  });

  static const ask = SessionAutoApproval();

  final AutoApprovalMode mode;

  /// Child (subagent) sessions without a setting of their own follow this
  /// session's [mode]. Meaningless while [mode] is [AutoApprovalMode.ask].
  final bool inheritToChildren;

  bool get automatic => mode == AutoApprovalMode.autoOnce;

  Map<String, Object?> toJson() => {
    'mode': mode.name,
    'inheritToChildren': inheritToChildren,
  };

  static SessionAutoApproval? fromJson(Object? value) {
    if (value is! Map) return null;
    final mode = AutoApprovalMode.values.cast<AutoApprovalMode?>().firstWhere(
      (candidate) => candidate!.name == value['mode'],
      orElse: () => null,
    );
    if (mode == null) return null;
    return SessionAutoApproval(
      mode: mode,
      inheritToChildren: value['inheritToChildren'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SessionAutoApproval &&
      other.mode == mode &&
      other.inheritToChildren == inheritToChildren;

  @override
  int get hashCode => Object.hash(mode, inheritToChildren);
}

/// The setting that applies to a session once inheritance is resolved.
@immutable
class EffectiveAutoApproval {
  const EffectiveAutoApproval({
    required this.setting,
    required this.explicit,
    this.inheritedFrom,
    this.serverWide = false,
  });

  static const askByDefault = EffectiveAutoApproval(
    setting: SessionAutoApproval.ask,
    explicit: false,
  );

  final SessionAutoApproval setting;

  /// True when the session carries its own stored setting.
  final bool explicit;

  /// The ancestor session whose setting applies, when [explicit] is false and
  /// an ancestor with "subagents inherit" reached this session.
  final String? inheritedFrom;

  /// True when neither the session nor an ancestor decided and the server's
  /// "approve everything" setting did.
  final bool serverWide;

  bool get automatic => setting.automatic;
  bool get inherited => inheritedFrom != null;
}

/// One permission this phone answered automatically, for the in-chat record.
@immutable
class AutoApprovedPermission {
  const AutoApprovedPermission({
    required this.requestID,
    required this.sessionID,
    required this.permission,
    required this.patterns,
    required this.at,
  });

  final String requestID;
  final String sessionID;

  /// The requested action as the server named it (`bash`, `edit`, ...).
  final String permission;
  final List<String> patterns;
  final DateTime at;
}

/// Device-only, per-profile session approval choices.
///
/// Stored under `oc.autoApprove.<profileId>` so the profile deletion sweep in
/// `ProfileStore.profileScopedPreferenceKeys` removes it; the controller
/// awaits [drain] before that sweep so a late write cannot resurrect a
/// deleted profile's choices.
class SessionAutoApprovalStore {
  SessionAutoApprovalStore(this.preferences);

  final SharedPreferences preferences;
  final _cache = <String, Map<String, SessionAutoApproval>>{};
  final _writes = <String, Future<void>>{};

  static String keyFor(String profileId) => 'oc.autoApprove.$profileId';

  /// The entry that holds the server-wide "approve everything" choice. It
  /// lives in the same map as the sessions so the profile sweep, [drain] and
  /// the write queue cover it; no session ID can be `*`.
  static const serverWideKey = '*';

  static const _everything = EffectiveAutoApproval(
    setting: SessionAutoApproval(
      mode: AutoApprovalMode.autoOnce,
      inheritToChildren: true,
    ),
    explicit: false,
    serverWide: true,
  );

  /// Whether every conversation on this server is approved automatically
  /// unless it (or an ancestor that passes its choice down) says otherwise.
  bool approvesEverything(String profile) =>
      profile.isNotEmpty && (_load(profile)[serverWideKey]?.automatic ?? false);

  Future<void> setApprovesEverything(String profile, bool value) => set(
    profile,
    serverWideKey,
    value
        ? const SessionAutoApproval(
            mode: AutoApprovalMode.autoOnce,
            inheritToChildren: true,
          )
        : null,
  );

  EffectiveAutoApproval _fallback(String profile) => approvesEverything(profile)
      ? _everything
      : EffectiveAutoApproval.askByDefault;

  Map<String, SessionAutoApproval> _load(String profile) =>
      _cache.putIfAbsent(profile, () {
        try {
          final value = jsonDecode(
            preferences.getString(keyFor(profile)) ?? '{}',
          );
          if (value is Map) {
            return {
              for (final entry in value.entries)
                if (entry.key case final String key when key.isNotEmpty)
                  key: ?SessionAutoApproval.fromJson(entry.value),
            };
          }
        } catch (_) {}
        return {};
      });

  /// The session's own stored setting, or null when it has none and follows
  /// its ancestors (or asks, when none of them inherit).
  SessionAutoApproval? explicitFor(String profile, String sessionID) =>
      profile.isEmpty ? null : _load(profile)[sessionID];

  /// Every session with an explicit setting, keyed by session ID.
  Map<String, SessionAutoApproval> settingsFor(String profile) =>
      profile.isEmpty
      ? const {}
      : Map.unmodifiable({
          for (final entry in _load(profile).entries)
            if (entry.key != serverWideKey) entry.key: entry.value,
        });

  /// Resolves the setting for [sessionID]: its own when it has one, else the
  /// nearest ancestor (via [parentOf]) whose setting inherits to children,
  /// else the server-wide choice, else ask. A conversation explicitly set to
  /// ask keeps asking under "approve everything". Cycles and unknown parents
  /// end the walk.
  EffectiveAutoApproval effectiveFor(
    String profile,
    String sessionID,
    String? Function(String sessionID) parentOf,
  ) {
    if (profile.isEmpty) return EffectiveAutoApproval.askByDefault;
    final settings = _load(profile);
    final own = settings[sessionID];
    if (own != null) {
      return EffectiveAutoApproval(setting: own, explicit: true);
    }
    final visited = <String>{sessionID};
    var parent = parentOf(sessionID);
    while (parent != null && parent.isNotEmpty && visited.add(parent)) {
      final setting = settings[parent];
      if (setting != null) {
        // An ancestor with an explicit setting decides for its subtree: it
        // passes its mode down when it inherits, and stops the walk when
        // it does not, so a grandparent cannot reach past an opted-out child.
        if (setting.inheritToChildren) {
          return EffectiveAutoApproval(
            setting: setting,
            explicit: false,
            inheritedFrom: parent,
          );
        }
        return _fallback(profile);
      }
      parent = parentOf(parent);
    }
    return _fallback(profile);
  }

  /// Stores [setting] for the session, or removes the session's own entry
  /// when [setting] is null so it follows its ancestors again. Throws when
  /// storage refuses the write; the cache changes only after acceptance.
  Future<void> set(
    String profile,
    String sessionID,
    SessionAutoApproval? setting,
  ) async {
    if (profile.isEmpty || sessionID.isEmpty) {
      throw StateError('The server profile is unavailable');
    }
    final previous = _writes[profile] ?? Future<void>.value();
    final writing = previous.catchError((Object _) {}).then((_) async {
      final next = {..._load(profile)};
      if (setting == null) {
        next.remove(sessionID);
      } else {
        next[sessionID] = setting;
      }
      final saved = await preferences.setString(
        keyFor(profile),
        jsonEncode({
          for (final entry in next.entries) entry.key: entry.value.toJson(),
        }),
      );
      if (!saved) {
        // The plugin mutates its cache before the platform write resolves;
        // reload disk truth so a reopened store cannot read a refused value.
        try {
          await preferences.reload();
        } catch (_) {}
        throw StateError('Could not save the approval setting');
      }
      _cache[profile] = next;
    });
    _writes[profile] = writing;
    try {
      await writing;
    } finally {
      if (identical(_writes[profile], writing)) _writes.remove(profile);
    }
  }

  /// Profile deletion waits for accepted writes before discovering keys.
  Future<void> drain(String profile) =>
      _writes[profile] ?? Future<void>.value();

  void forget(String profile) => _cache.remove(profile);
}
