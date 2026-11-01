import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/automation_policy.dart';
import '../ui/kit/kit_redact.dart';
import 'team_planning.dart' show TeamSupervision;

export '../domain/automation_policy.dart';

/// The team's supervision level a local choice stands for: new team tasks
/// start at it (Settings › What runs by itself).
extension AutomationSupervisionTeam on AutomationSupervision {
  TeamSupervision get team => switch (this) {
    AutomationSupervision.high => TeamSupervision.high,
    AutomationSupervision.balanced => TeamSupervision.balanced,
    AutomationSupervision.autonomous => TeamSupervision.autonomous,
  };
}

/// One controller per profile, shared by its settings page and executors.
/// Listen for successfully persisted changes; setters throw a safe StateError
/// on failure. Merely constructing/listening never writes or starts work.
class AutomationPolicyController extends ChangeNotifier {
  AutomationPolicyController({
    required this.profileId,
    required SharedPreferences preferences,
  }) : _preferences = preferences {
    if (profileId.isEmpty || KitRedact.containsSecret(profileId)) {
      throw ArgumentError('A non-secret server profile ID is required');
    }
    _value = _read();
  }

  final String profileId;
  final SharedPreferences _preferences;
  late AutomationPolicy _value;
  Future<void> _pending = Future<void>.value();
  bool _closed = false;
  bool _pausedForDeletion = false;

  static String keyFor(String profileId) => 'oc.automation.$profileId';

  static final _shared =
      Map<
        SharedPreferences,
        Map<String, AutomationPolicyController>
      >.identity();

  /// The one shared controller of [profileId] on [preferences]: the
  /// settings page and every executor that consults the policy read the same
  /// instance, so there is never a second writer for one profile.
  static AutomationPolicyController forProfile(
    SharedPreferences preferences,
    String profileId,
  ) => (_shared[preferences] ??= {}).putIfAbsent(
    profileId,
    () => AutomationPolicyController(
      profileId: profileId,
      preferences: preferences,
    ),
  );

  /// Closes the shared controller of [profileId] and drains its write in
  /// flight, BEFORE the profile deletion sweep removes its key. A later
  /// [forProfile] starts a fresh controller from what storage then holds.
  static Future<void> closeProfile(
    SharedPreferences preferences,
    String profileId,
  ) async {
    final byProfile = _shared[preferences];
    final controller = byProfile?[profileId];
    if (controller == null) return;
    try {
      await controller.prepareForDeletion();
    } finally {
      if (identical(byProfile?[profileId], controller)) {
        byProfile!.remove(profileId);
      }
    }
  }

  /// Forgets every shared controller; tests only.
  @visibleForTesting
  static void resetShared() => _shared.clear();
  AutomationPolicy get value => _value;

  AutomationPolicy _read() {
    try {
      final raw = _preferences.getString(keyFor(profileId));
      return raw == null
          ? AutomationPolicy()
          : AutomationPolicy.fromJson(jsonDecode(raw));
    } catch (_) {
      return AutomationPolicy.disabled();
    }
  }

  Future<void> setBehavior(AutomationBehavior behavior, bool enabled) =>
      _change((p) => p.withBehavior(behavior, enabled));

  /// This selection is explicit consent, not a default or host-side mutation.
  Future<void> setSupervision(AutomationSupervision supervision) =>
      _change((p) => p.withSupervision(supervision));

  Future<void> setAutoApprove(bool enabled) =>
      _change((p) => p.withApprovals(autoApprove: enabled));

  Future<void> setAutoMergeOnGreen(bool enabled) =>
      _change((p) => p.withApprovals(autoMergeOnGreen: enabled));

  Future<void> disableAll() => _change((_) => AutomationPolicy.disabled());

  Future<void> _change(AutomationPolicy Function(AutomationPolicy) update) {
    if (_closed || _pausedForDeletion) {
      return Future.error(StateError('Automation policy is unavailable'));
    }
    final writing = _pending.then((_) async {
      if (_closed) throw StateError('Automation policy is closed');
      final next = update(_value);
      // Only enum names and booleans are stored. Redaction is still mandatory
      // at the persistence boundary; never save altered permission semantics.
      final raw = jsonEncode(next.toJson());
      final redacted = KitRedact.text(raw);
      if (raw != redacted) {
        throw StateError('Automation policy contains protected content');
      }
      try {
        if (!await _preferences.setString(keyFor(profileId), redacted)) {
          throw StateError('Storage refused the automation policy');
        }
      } catch (_) {
        // SharedPreferences optimistically changes its cache before writing.
        try {
          await _preferences.reload();
        } catch (_) {}
        throw StateError('Could not save automation policy');
      }
      _value = next;
      if (!_closed) notifyListeners();
    });
    // Later writes can recover from a failed write; callers still get failure.
    _pending = writing.catchError((Object _) {});
    return writing;
  }

  /// Stops accepting edits immediately and drains in-flight storage before
  /// ProfileStore's deletion sweep. The controller cannot be reused afterward.
  /// Await this BEFORE deleting a profile; dispose alone does not await I/O.
  Future<void> prepareForDeletion() {
    _closed = true;
    return _pending;
  }

  /// Stops new edits and drains edits already admitted without closing this
  /// shared owner. Keep it registered until deletion commits or is cancelled.
  Future<void> pauseForDeletion() {
    _pausedForDeletion = true;
    return _pending;
  }

  /// Restores editing after deletion validation or preservation aborts.
  /// A permanently closed controller remains closed.
  void cancelDeletion() {
    if (!_closed) _pausedForDeletion = false;
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}
