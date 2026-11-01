import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/provider_quota.dart';
import '../domain/provider_usage.dart';
import '../domain/usage_subscriptions.dart';
import '../platform/platform_capabilities.dart';
import 'widget_snapshot.dart';

/// Persists the display numbers of the Android "Usage" home-screen widget.
///
/// The widget is native and may be drawn while the app process is gone, so it
/// reads the last stored numbers instead of asking a controller, and it never
/// calls the network. Only what the widget prints is written: the provider,
/// the server's saved name, each limit window's length, remaining percent and
/// reset time, and when the numbers were measured. Account references,
/// tokens, addresses, plan names and raw errors are never stored, and Claude
/// (whose collection is off) can never appear.
///
/// One preference per server, `oc.widgetUsage.<profileId>`, so the profile
/// deletion sweep removes it with the rest of the server's local data. The
/// native widget lists every `flutter.oc.widgetUsage.*` key.
///
/// The numbers are refreshed by the quota monitor, which runs while the app
/// process lives (foreground every 5 minutes, background every 15 only with
/// background monitoring allowed). The widget therefore labels old numbers
/// "Updated 2h ago" instead of pretending; no extra service is started.
class UsageWidgetSnapshot {
  UsageWidgetSnapshot({
    required this.prefs,
    Future<void> Function()? refreshNative,
    bool? isAndroid,
  }) : _refreshNative =
           refreshNative ?? WidgetSessionSnapshot.refreshHomeWidget,
       _isAndroid = isAndroid ?? platformCapabilities.supportsHomeWidget;

  static const keyPrefix = 'oc.widgetUsage';
  static String key(String profileId) => '$keyPrefix.$profileId';

  /// The rows a single widget can show; extra windows are dropped.
  static const maxWindowsPerProvider = 3;

  final SharedPreferences prefs;
  final Future<void> Function() _refreshNative;
  final bool _isAndroid;

  /// Records a measurement the monitor accepted as fresh.
  Future<void> record({
    required String profileId,
    required String profileName,
    required ProviderQuotaSnapshot snapshot,
  }) async {
    if (!_isAndroid || profileId.isEmpty) return;
    if (!quotaCollectionAvailable(snapshot.provider) ||
        !snapshot.canShowWindows) {
      return;
    }
    final windows = <Map<String, Object?>>[
      for (final window in snapshot.windows)
        if (window.remainingPercent != null && window.durationSeconds != null)
          {
            'seconds': window.durationSeconds,
            'left': window.remainingPercent!.clamp(0, 100).round(),
            'resetsAt': window.resetsAt?.millisecondsSinceEpoch,
          },
    ].take(maxWindowsPerProvider).toList();
    if (windows.isEmpty) return;
    await _mutate(profileId, profileName, (rows) {
      rows[snapshot.provider.name] = {
        'state': 'ok',
        'fetchedAt': snapshot.fetchedAt.millisecondsSinceEpoch,
        'windows': windows,
      };
    });
  }

  /// Replaces everything stored for a Paseo server with what its daemon just
  /// reported. A Paseo server has no other source, so providers the daemon no
  /// longer reports disappear. Only cleaned names and numbers are kept; the
  /// daemon's plan, source and error text never reach this method.
  Future<void> recordReadings({
    required String profileId,
    required String profileName,
    required List<ProviderUsageReading> readings,
    bool thisPhone = false,
  }) async {
    if (!_isAndroid || profileId.isEmpty) return;
    await _mutate(profileId, profileName, local: thisPhone, (rows) {
      rows.clear();
      for (final reading in readings) {
        if (reading.needsSignIn && reading.windows.isEmpty) {
          rows[reading.providerId] = {
            'state': 'signin',
            'action': actionFor(reading.providerId),
            'name': reading.displayName,
            'fetchedAt': reading.fetchedAt.millisecondsSinceEpoch,
            'windows': <Object?>[],
          };
          continue;
        }
        if (reading.windows.isEmpty) continue;
        rows[reading.providerId] = {
          'state': 'ok',
          'name': reading.displayName,
          'fetchedAt': reading.fetchedAt.millisecondsSinceEpoch,
          'windows': [
            for (final window in reading.windows.take(maxWindowsPerProvider))
              {
                if (window.durationSeconds != null)
                  'seconds': window.durationSeconds
                else
                  'label': window.label,
                'left': window.remainingPercent.clamp(0, 100),
                'resetsAt': window.resetsAt?.millisecondsSinceEpoch,
              },
          ],
        };
      }
    });
  }

  /// How a provider is signed in, which decides the widget row's words and
  /// the screen a tap opens: GLM and MiniMax take a key, the rest sign in.
  static String actionFor(String providerId) =>
      providerId == 'glm' || providerId == 'minimax' ? addKey : signIn;

  static const signIn = 'sign_in';
  static const addKey = 'add_key';
  static const setUp = 'set_up';

  /// The collector says the stored sign-in no longer works: keep the last
  /// numbers (a row of its own when there are none) and let the widget say
  /// so. The row carries the tap target that opens the fix.
  Future<void> markAuthNeeded({
    required String profileId,
    required String profileName,
    required QuotaProvider provider,
  }) async {
    if (!_isAndroid || profileId.isEmpty) return;
    if (!quotaCollectionAvailable(provider)) return;
    await _mutate(profileId, profileName, (rows) {
      final row = rows[provider.name] ??= {
        'fetchedAt': DateTime.now().millisecondsSinceEpoch,
        'windows': <Object?>[],
      };
      row['state'] = 'auth';
      row['action'] = actionFor(provider.name);
    });
  }

  /// The source says this provider is not signed in (or has no key) where
  /// the app reads it. Numbers are never invented: an existing row keeps its
  /// windows and only changes state; otherwise a row with no windows is
  /// stored so the widget can offer the way in.
  Future<void> markNotSignedIn({
    required String profileId,
    required String profileName,
    required String providerId,
    String displayName = '',
    bool thisPhone = false,
  }) async {
    if (!_isAndroid || profileId.isEmpty || !validProviderId(providerId)) {
      return;
    }
    await _mutate(profileId, profileName, local: thisPhone, (rows) {
      final row = rows[providerId] ??= {
        'fetchedAt': DateTime.now().millisecondsSinceEpoch,
        'windows': <Object?>[],
      };
      final windows = row['windows'];
      if (windows is List && windows.isNotEmpty) return;
      row['state'] = 'signin';
      row['action'] = actionFor(providerId);
      if (displayName.isNotEmpty) row['name'] = displayName;
    });
  }

  static final _providerIdPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,31}$');
  static bool validProviderId(String id) => _providerIdPattern.hasMatch(id);

  /// Monitoring of this provider ended (consent withdrawn, source changed).
  Future<void> removeProvider({
    required String profileId,
    required QuotaProvider provider,
  }) async {
    if (!_isAndroid || profileId.isEmpty) return;
    await _mutate(profileId, '', (rows) => rows.remove(provider.name));
  }

  /// The single feed the widget prefers: one entry per subscription, in the
  /// order of the Usage page, each with both its 5-hour and weekly window
  /// when the provider reports both. Rows that need setup are included unless
  /// [settings] hide them (D7). Display numbers only: no account references,
  /// plan names, addresses or error text. See
  /// docs/design/usage-subscriptions-contract-2026-10-13.md section 5.
  Future<void> publishSubscriptions(
    UsageSnapshot snapshot,
    UsageWidgetSettings settings,
  ) async {
    if (!_isAndroid) return;
    final entries = <Map<String, Object?>>[];
    for (final s in snapshot.subscriptions) {
      if (settings.hiddenKeys.contains(s.key)) continue;
      final entry = widgetEntryFor(s, settings);
      if (entry != null) entries.add(entry);
    }
    final raw = prefs.getString(subscriptionsKey);
    if (entries.isEmpty && !snapshot.loaded) return;
    final payload = jsonEncode({'v': 1, 'entries': entries});
    if (payload == raw) return;
    await prefs.setString(subscriptionsKey, payload);
    await _refreshNative();
  }

  static const subscriptionsKey = 'oc.widgetUsageSubs';

  /// The widget entry for [s], or null when it has nothing to say there
  /// (no limits reported, or a setup row the person turned off).
  static Map<String, Object?>? widgetEntryFor(
    UsageSubscription s,
    UsageWidgetSettings settings,
  ) {
    final setup = switch (s.state) {
      SubscriptionState.cantReadYet ||
      SubscriptionState.notSignedIn ||
      SubscriptionState.signInExpired => true,
      _ => false,
    };
    if (setup && !settings.showSetupRows) return null;
    if (s.state == SubscriptionState.noLimits ||
        s.state == SubscriptionState.apiKeyOnly) {
      return null;
    }
    final chosen = <UsageWindow>[];
    final five = s.fiveHour, week = s.weekly;
    switch (settings.windows) {
      case UsageWidgetWindows.both:
        if (five != null) chosen.add(five);
        if (week != null) chosen.add(week);
        if (chosen.isEmpty) chosen.addAll(s.windows.take(2));
      case UsageWidgetWindows.fiveHour:
        chosen.addAll([?five ?? (s.windows.isEmpty ? null : s.windows.first)]);
      case UsageWidgetWindows.weekly:
        chosen.addAll([?week ?? (s.windows.isEmpty ? null : s.windows.first)]);
    }
    if (!setup && chosen.isEmpty && s.state != SubscriptionState.readerBroken) {
      return null;
    }
    final state = switch (s.state) {
      SubscriptionState.ok => 'ok',
      SubscriptionState.nearLimit => 'near',
      SubscriptionState.exhausted => 'out',
      SubscriptionState.offlineStale =>
        s.resetSinceLastReading ? 'reset' : 'stale',
      SubscriptionState.readerBroken => 'broken',
      SubscriptionState.cantReadYet => 'setup',
      SubscriptionState.notSignedIn ||
      SubscriptionState.signInExpired => 'signin',
      _ => 'ok',
    };
    return {
      'key': s.key,
      'provider': s.providerId,
      'name': s.displayName,
      'state': state,
      'fetchedAt': s.fetchedAt?.millisecondsSinceEpoch ?? 0,
      'reset': s.resetSinceLastReading,
      'windows': [
        for (final w in chosen)
          {
            if (w.durationSeconds != null)
              'seconds': w.durationSeconds
            else
              'label': w.label,
            'left': w.leftPercent.round().clamp(0, 100),
            'resetsAt': w.resetsAt?.millisecondsSinceEpoch,
          },
      ],
      'action': switch (s.fix) {
        UsageFix.signIn => signIn,
        UsageFix.addKey => addKey,
        UsageFix.setUp => setUp,
        _ => '',
      },
      'profileId': s.fixConnection?.id ?? '',
    };
  }

  Future<void> clearSubscriptions() async {
    if (prefs.getString(subscriptionsKey) == null) return;
    try {
      await prefs.remove(subscriptionsKey);
    } catch (_) {
      return;
    }
    if (_isAndroid) await _refreshNative();
  }

  /// Drops everything stored for [profileId]; true when nothing is left.
  Future<bool> clearForProfile(String profileId) async {
    if (profileId.isEmpty) return true;
    if (prefs.getString(key(profileId)) == null) return true;
    try {
      if (!await prefs.remove(key(profileId))) return false;
    } catch (_) {
      return false;
    }
    if (_isAndroid) await _refreshNative();
    return true;
  }

  Future<void> _mutate(
    String profileId,
    String profileName,
    void Function(Map<String, Map<String, Object?>> rows) change, {
    bool local = false,
  }) async {
    final rows = <String, Map<String, Object?>>{};
    var name = profileName;
    final raw = prefs.getString(key(profileId));
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          if (name.isEmpty) name = decoded['name']?.toString() ?? '';
          final stored = decoded['rows'];
          if (stored is Map) {
            for (final entry in stored.entries) {
              if (entry.value is Map) {
                rows[entry.key.toString()] = Map<String, Object?>.from(
                  entry.value as Map,
                );
              }
            }
          }
        }
      } catch (_) {
        // Unreadable payload: start over rather than keep unknown content.
      }
    }
    change(rows);
    if (rows.isEmpty) {
      if (raw == null) return;
      await prefs.remove(key(profileId));
    } else {
      final payload = jsonEncode({
        'name': name,
        'rows': rows,
        'local': ?(local ? true : null),
      });
      if (payload == raw) return;
      await prefs.setString(key(profileId), payload);
    }
    await _refreshNative();
  }
}

/// Which windows each widget entry shows.
enum UsageWidgetWindows { both, fiveHour, weekly }

/// The person's widget choices (D7): which subscriptions, which windows, and
/// whether rows that need setup appear. Stored in `oc.usageWidget.v1`.
class UsageWidgetSettings {
  const UsageWidgetSettings({
    this.hiddenKeys = const {},
    this.showSetupRows = true,
    this.windows = UsageWidgetWindows.both,
  });

  final Set<String> hiddenKeys;
  final bool showSetupRows;
  final UsageWidgetWindows windows;

  static const key = 'oc.usageWidget.v1';

  UsageWidgetSettings copyWith({
    Set<String>? hiddenKeys,
    bool? showSetupRows,
    UsageWidgetWindows? windows,
  }) => UsageWidgetSettings(
    hiddenKeys: hiddenKeys ?? this.hiddenKeys,
    showSetupRows: showSetupRows ?? this.showSetupRows,
    windows: windows ?? this.windows,
  );

  String toJson() => jsonEncode({
    'hidden': hiddenKeys.toList()..sort(),
    'setup': showSetupRows,
    'windows': windows.name,
  });

  static UsageWidgetSettings load(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(key);
      if (raw == null) return const UsageWidgetSettings();
      final data = jsonDecode(raw) as Map;
      return UsageWidgetSettings(
        hiddenKeys: {
          for (final k in (data['hidden'] as List? ?? const []))
            if (k is String && k.length <= 160) k,
        },
        showSetupRows: data['setup'] != false,
        windows:
            UsageWidgetWindows.values
                .where((w) => w.name == data['windows'])
                .firstOrNull ??
            UsageWidgetWindows.both,
      );
    } catch (_) {
      return const UsageWidgetSettings();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is UsageWidgetSettings &&
      other.showSetupRows == showSetupRows &&
      other.windows == windows &&
      other.hiddenKeys.length == hiddenKeys.length &&
      other.hiddenKeys.containsAll(hiddenKeys);

  @override
  int get hashCode => Object.hash(showSetupRows, windows, hiddenKeys.length);
}
