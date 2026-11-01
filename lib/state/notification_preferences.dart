import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/profile_monitor.dart';

/// The notification rules that are the same for every server: one quiet-hours
/// pair, one Wi-Fi-only choice, one check-in rule and one quota-alert choice.
///
/// Before the Notifications screen existed these lived per saved server (and,
/// for quota, per provider source), so a person could hold two different
/// quiet-hours definitions without a way to see both.
class SharedNotifyRules {
  const SharedNotifyRules({
    this.quietStart,
    this.quietEnd,
    this.wifiOnly = false,
    this.checkInAfterMinutes,
    this.quotaAlerts = false,
  });

  /// What the quota monitor's fixed "22:00–08:00" toggle meant, and what a
  /// person gets when they first turn quiet hours on.
  static const defaultQuietStart = 22 * 60;
  static const defaultQuietEnd = 8 * 60;

  /// Local wall-clock minutes after midnight; quiet hours are on only when
  /// both are set.
  final int? quietStart;
  final int? quietEnd;
  final bool wifiOnly;
  final int? checkInAfterMinutes;
  final bool quotaAlerts;

  bool get quietEnabled => quietStart != null && quietEnd != null;

  bool quietAt(DateTime now) => ProfileNotifyRules(
    quietStart: quietEnabled ? quietStart : null,
    quietEnd: quietEnabled ? quietEnd : null,
  ).quietAt(now);

  SharedNotifyRules copyWith({
    int? quietStart,
    int? quietEnd,
    bool clearQuiet = false,
    bool? wifiOnly,
    int? checkInAfterMinutes,
    bool clearCheckIn = false,
    bool? quotaAlerts,
  }) => SharedNotifyRules(
    quietStart: clearQuiet ? null : quietStart ?? this.quietStart,
    quietEnd: clearQuiet ? null : quietEnd ?? this.quietEnd,
    wifiOnly: wifiOnly ?? this.wifiOnly,
    checkInAfterMinutes: clearCheckIn
        ? null
        : checkInAfterMinutes ?? this.checkInAfterMinutes,
    quotaAlerts: quotaAlerts ?? this.quotaAlerts,
  );

  /// The per-server rule as the monitor must apply it: what is shared wins
  /// over whatever the server's own legacy record still says.
  ProfileNotifyRules applyTo(ProfileNotifyRules rules) => ProfileNotifyRules(
    enabled: rules.enabled,
    notifications: rules.notifications,
    wifiOnly: wifiOnly,
    quietStart: quietEnabled ? quietStart : null,
    quietEnd: quietEnabled ? quietEnd : null,
    checkInAfterMinutes: checkInAfterMinutes,
  );

  @override
  bool operator ==(Object other) =>
      other is SharedNotifyRules &&
      other.quietStart == quietStart &&
      other.quietEnd == quietEnd &&
      other.wifiOnly == wifiOnly &&
      other.checkInAfterMinutes == checkInAfterMinutes &&
      other.quotaAlerts == quotaAlerts;

  @override
  int get hashCode => Object.hash(
    quietStart,
    quietEnd,
    wifiOnly,
    checkInAfterMinutes,
    quotaAlerts,
  );

  @override
  String toString() =>
      'SharedNotifyRules(quiet: $quietStart-$quietEnd, wifiOnly: $wifiOnly, '
      'checkIn: $checkInAfterMinutes, quotaAlerts: $quotaAlerts)';
}

/// The notification part of one legacy quota-monitor source record.
class LegacyQuotaNotify {
  const LegacyQuotaNotify({
    this.notifications = false,
    this.wifiOnly = false,
    this.quietHours = false,
  });
  final bool notifications;
  final bool wifiOnly;

  /// The old screen only offered a fixed 22:00–08:00 toggle.
  final bool quietHours;
}

/// Folds every legacy definition into the one shared rule. Pure, so each
/// legacy shape is unit tested.
///
/// - Quiet hours: the first saved-server pair wins ([profileRules] is ordered
///   with the connected server first); otherwise 22:00–08:00 when any quota
///   source had its quiet toggle on; otherwise off.
/// - Wi-Fi only, quota alerts: on when any legacy record had it on. Turning a
///   restriction someone chose into "off" would spend their mobile data.
/// - Check-ins: the first saved server that had a duration.
SharedNotifyRules mergeLegacyNotifyRules({
  Iterable<ProfileNotifyRules> profileRules = const [],
  Iterable<LegacyQuotaNotify> quotaRules = const [],
}) {
  final pair = profileRules
      .where((rules) => rules.quietStart != null && rules.quietEnd != null)
      .firstOrNull;
  final quotaQuiet = quotaRules.any((rules) => rules.quietHours);
  return SharedNotifyRules(
    quietStart:
        pair?.quietStart ??
        (quotaQuiet ? SharedNotifyRules.defaultQuietStart : null),
    quietEnd:
        pair?.quietEnd ??
        (quotaQuiet ? SharedNotifyRules.defaultQuietEnd : null),
    wifiOnly:
        profileRules.any((rules) => rules.wifiOnly) ||
        quotaRules.any((rules) => rules.wifiOnly),
    checkInAfterMinutes: profileRules
        .map((rules) => rules.checkInAfterMinutes)
        .nonNulls
        .firstOrNull,
    quotaAlerts: quotaRules.any((rules) => rules.notifications),
  );
}

/// Storage for [SharedNotifyRules] and the two "what notifies me" choices.
///
/// [shared] is null until [migrate] has run once. Until then both monitors
/// keep reading their own legacy records, so a build that has not migrated
/// yet behaves exactly as before.
class NotificationPreferences {
  NotificationPreferences(this.prefs);
  final SharedPreferences prefs;

  static const versionKey = 'oc.notify.version';
  static const quietStartKey = 'oc.notify.quietStart';
  static const quietEndKey = 'oc.notify.quietEnd';
  static const wifiOnlyKey = 'oc.notify.wifiOnly';
  static const checkInKey = 'oc.notify.checkInAfterMinutes';
  static const quotaAlertsKey = 'oc.notify.quotaAlerts';
  static const finishedRunsKey = 'oc.notify.finishedRuns';
  static const requestsKey = 'oc.notify.requests';

  /// The legacy per-server records the migration reads and never deletes: an
  /// older build installed over this one must still find its own values.
  static String legacyProfileRulesKey(String id) => 'oc.notifyRules.$id';
  static String legacyQuotaRulesKey(String id) => 'oc.quotaMonitor.$id';

  bool get migrated => prefs.getInt(versionKey) == 1;

  SharedNotifyRules? get shared {
    if (!migrated) return null;
    int? minute(String key) {
      final value = prefs.getInt(key);
      return value != null && value >= 0 && value < 1440 ? value : null;
    }

    final checkIn = prefs.getInt(checkInKey);
    return SharedNotifyRules(
      quietStart: minute(quietStartKey),
      quietEnd: minute(quietEndKey),
      wifiOnly: prefs.getBool(wifiOnlyKey) ?? false,
      checkInAfterMinutes: checkIn != null && checkIn > 0 && checkIn <= 24 * 60
          ? checkIn
          : null,
      quotaAlerts: prefs.getBool(quotaAlertsKey) ?? false,
    );
  }

  /// Notify when a run finishes or fails on the connected server.
  bool get finishedRuns => prefs.getBool(finishedRunsKey) ?? true;
  Future<bool> setFinishedRuns(bool value) =>
      prefs.setBool(finishedRunsKey, value);

  /// Notify about approvals, questions and forms, on any server.
  bool get requests => prefs.getBool(requestsKey) ?? true;
  Future<bool> setRequests(bool value) => prefs.setBool(requestsKey, value);

  /// What the legacy records say, for [profileIDs] in the order given.
  SharedNotifyRules readLegacy(Iterable<String> profileIDs) {
    final profiles = <ProfileNotifyRules>[];
    final quota = <LegacyQuotaNotify>[];
    for (final id in profileIDs) {
      try {
        final raw = prefs.getString(legacyProfileRulesKey(id));
        if (raw != null) {
          profiles.add(
            ProfileNotifyRules.fromJson(
              Map<String, dynamic>.from(jsonDecode(raw) as Map),
            ),
          );
        }
      } catch (_) {
        // A corrupt record read as "off" before; it still does.
      }
      try {
        final raw = prefs.getString(legacyQuotaRulesKey(id));
        if (raw == null || raw.length > 65536) continue;
        final rules = (jsonDecode(raw) as Map)['rules'];
        if (rules is! Map) continue;
        for (final rule in rules.values) {
          if (rule is! Map) continue;
          quota.add(
            LegacyQuotaNotify(
              notifications: rule['notifications'] == true,
              wifiOnly: rule['wifiOnly'] == true,
              quietHours: rule['quietStart'] is int && rule['quietEnd'] is int,
            ),
          );
        }
      } catch (_) {}
    }
    return mergeLegacyNotifyRules(profileRules: profiles, quotaRules: quota);
  }

  /// Runs once; every later call returns the stored value untouched, so a
  /// person's edits are never overwritten by a second pass over stale legacy
  /// records. The version key is written last: an interrupted migration
  /// simply runs again.
  Future<SharedNotifyRules> migrate(Iterable<String> profileIDs) async {
    final existing = shared;
    if (existing != null) return existing;
    final merged = readLegacy(profileIDs);
    await _write(merged);
    await prefs.setInt(versionKey, 1);
    return merged;
  }

  /// Saving implies the shared value is now the truth, so it also marks the
  /// migration as done.
  Future<void> save(SharedNotifyRules rules) async {
    await _write(rules);
    await prefs.setInt(versionKey, 1);
  }

  Future<void> _write(SharedNotifyRules rules) async {
    Future<void> number(String key, int? value) =>
        value == null ? prefs.remove(key) : prefs.setInt(key, value);
    await number(quietStartKey, rules.quietEnabled ? rules.quietStart : null);
    await number(quietEndKey, rules.quietEnabled ? rules.quietEnd : null);
    await prefs.setBool(wifiOnlyKey, rules.wifiOnly);
    await number(checkInKey, rules.checkInAfterMinutes);
    await prefs.setBool(quotaAlertsKey, rules.quotaAlerts);
  }
}
