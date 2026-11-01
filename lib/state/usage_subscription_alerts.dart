import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/usage_subscriptions.dart';
import 'notification_preferences.dart';

/// One notification to show.
class UsageAlertNote {
  const UsageAlertNote({
    required this.profileId,
    required this.key,
    required this.token,
    required this.reset,
    required this.providerName,
  });

  /// The connection the reading came from ('phone' for this phone's agents).
  final String profileId;

  /// Notification key: one per subscription and kind.
  final String key;

  /// 64 hex characters the notification carries, so a tap can find the
  /// subscription again without a name.
  final String token;

  /// "back again" (D5) rather than "past the alert level" (D4).
  final bool reset;
  final String providerName;
}

/// The second alert delivery path (contract open questions 3 and 5): keyed on
/// the subscription, so plans read by a computer, by Paseo or from the Codex
/// account alert like In-app Ubuntu's, and any plan can send the reset
/// message. It reuses the quota monitor's rules: the shared switch, quiet
/// hours, Wi-Fi only, no delivery while the app is open, and a marker per
/// window and reset time so one crossing alerts once.
class SubscriptionAlertDelivery {
  SubscriptionAlertDelivery({
    required this.prefs,
    required this.sharedRules,
    required this.show,
    required this.dismiss,
    required this.wifi,
    DateTime Function()? clock,
    this.maxAge = const Duration(minutes: 45),
    this.resetWithin = const Duration(hours: 12),
  }) : clock = clock ?? DateTime.now;

  /// Shared blob. Holds opaque subscription keys and numbers, never a name.
  static const storeKey = 'oc.usageAlertSeen.v1';

  final SharedPreferences prefs;
  final SharedNotifyRules Function() sharedRules;
  final Future<bool> Function(UsageAlertNote note) show;
  final Future<void> Function(String key) dismiss;

  /// True on Wi-Fi, false off it, null when unknown.
  final Future<bool?> Function() wifi;
  final DateTime Function() clock;

  /// Numbers older than this never alert.
  final Duration maxAge;

  /// A reset is announced only when the high reading it follows is this fresh.
  final Duration resetWithin;

  static String _hash(Object? value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  /// The token a notification for [subscriptionKey] carries.
  static String tokenFor(String subscriptionKey) =>
      _hash(['usage-alert', subscriptionKey]);

  static String _alertKey(String subscriptionKey, {required bool reset}) =>
      '${reset ? 'quota-reset' : 'quota-sub'}|${_hash(subscriptionKey).substring(0, 16)}';

  /// Whether a tapped notification names a subscription read from
  /// [profileId].
  bool owns(UsageSnapshot snapshot, String profileId, String token) {
    for (final s in snapshot.subscriptions) {
      if (s.readFrom?.id == profileId && tokenFor(s.key) == token) return true;
    }
    return false;
  }

  Map<String, Map<String, Map<String, Object?>>> _load() {
    try {
      final raw = prefs.getString(storeKey);
      if (raw == null || raw.length > 262144) return {};
      final data = jsonDecode(raw);
      final subs = data is Map ? data['subs'] : null;
      if (subs is! Map) return {};
      final out = <String, Map<String, Map<String, Object?>>>{};
      for (final entry in subs.entries.take(256)) {
        final windows = entry.value;
        if (entry.key is! String || windows is! Map) continue;
        out[entry.key as String] = {
          for (final w in windows.entries.take(16))
            if (w.key is String && w.value is Map)
              w.key as String: Map<String, Object?>.from(w.value as Map),
        };
      }
      return out;
    } on Object {
      return {};
    }
  }

  Future<void> _save(
    Map<String, Map<String, Map<String, Object?>>> seen,
  ) async {
    try {
      await prefs.setString(storeKey, jsonEncode({'v': 1, 'subs': seen}));
    } on Object {
      // The next evaluation tries again.
    }
  }

  /// Drops records of subscriptions that no longer exist anywhere.
  Future<void> prune(Set<String> alive) async {
    final seen = _load();
    final before = seen.length;
    seen.removeWhere((key, _) => !alive.contains(key));
    if (seen.length != before) await _save(seen);
  }

  /// Looks at the current subscriptions and shows what is due.
  ///
  /// [covered] says a subscription's threshold alert already comes from the
  /// quota monitor (In-app Ubuntu's reader, an enrolled collector), so only
  /// its reset message is sent here.
  Future<void> evaluate(
    UsageSnapshot snapshot, {
    required bool alertsOn,
    required bool foreground,
    required bool Function(UsageSubscription) covered,
  }) async {
    final now = clock();
    final rules = sharedRules();
    // The app being open, the switch being off and quiet hours leave records
    // as they were: a crossing missed meanwhile is announced afterwards.
    if (!alertsOn || foreground || rules.quietAt(now.toLocal())) return;
    final seen = _load();
    var changed = false;
    bool? onWifi;
    Future<bool> allowed() async {
      if (!rules.wifiOnly) return true;
      onWifi ??= await wifi();
      return onWifi == true;
    }

    for (final s in snapshot.subscriptions) {
      final from = s.readFrom;
      final fetched = s.fetchedAt;
      if (from == null ||
          fetched == null ||
          s.windows.isEmpty ||
          s.state == SubscriptionState.offlineStale ||
          s.state == SubscriptionState.readerBroken ||
          now.difference(fetched) > maxAge) {
        continue;
      }
      final threshold = s.alertThreshold;
      final record = seen.putIfAbsent(s.key, () => {});
      var wantsReset = false;
      var wantsAlert = false;
      final next = <String, Map<String, Object?>>{};
      for (final w in s.windows) {
        final id = w.id;
        final prev = record[id];
        final prevUsed = prev?['u'];
        final prevReset = prev?['r'];
        final prevAt = prev?['t'];
        final resetMs = w.resetsAt?.millisecondsSinceEpoch;
        if (s.notifyOnReset &&
            prevUsed is num &&
            prevUsed >= threshold &&
            w.usedPercent < threshold &&
            prevReset != resetMs &&
            prevAt is int &&
            now.millisecondsSinceEpoch - prevAt <= resetWithin.inMilliseconds) {
          wantsReset = true;
        }
        var marker = prev?['m'];
        if (w.usedPercent >= threshold) {
          final fresh = _hash([
            s.key,
            id,
            w.durationSeconds,
            resetMs,
            threshold,
          ]);
          if (marker != fresh) {
            if (!covered(s)) wantsAlert = true;
            marker = fresh;
          }
        } else {
          marker = null;
        }
        next[id] = {
          'u': w.usedPercent,
          'r': resetMs,
          't': now.millisecondsSinceEpoch,
          'm': ?marker,
        };
      }
      final high = s.windows.any((w) => w.usedPercent >= threshold);
      if (!high) await dismiss(_alertKey(s.key, reset: false));
      final note = UsageAlertNote(
        profileId: from.id,
        key: _alertKey(s.key, reset: false),
        token: tokenFor(s.key),
        reset: false,
        providerName: _safeName(s.displayName),
      );
      var keepMarkers = true;
      if ((wantsAlert || wantsReset) && !await allowed()) {
        // Off Wi-Fi: leave this subscription as it was and look again later.
        continue;
      }
      if (wantsAlert) {
        final shown = await show(note);
        // An unavailable notification sink is not a delivery: forget the
        // marker so the next evaluation tries the same crossing again.
        if (!shown) keepMarkers = false;
      }
      if (wantsReset) {
        await show(
          UsageAlertNote(
            profileId: from.id,
            key: _alertKey(s.key, reset: true),
            token: tokenFor(s.key),
            reset: true,
            providerName: _safeName(s.displayName),
          ),
        );
      }
      if (!keepMarkers) {
        for (final value in next.values) {
          value.remove('m');
        }
      }
      record
        ..clear()
        ..addAll(next);
      changed = true;
    }
    if (changed) await _save(seen);
  }

  static String _safeName(String name) =>
      RegExp(r'^[A-Za-z0-9 .-]{1,32}$').hasMatch(name) ? name : '';
}
