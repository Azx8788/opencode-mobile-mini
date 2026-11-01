/// Device-side persistence for the AI Team plugin, per profile: the last
/// snapshot the host answered with (provider JSON with secrets redacted), the
/// event-stream cursor, and when the data was last refreshed.
///
/// Every key starts with `oc.orchestration.<profileId>.` so the profile
/// deletion sweep in `ProfileStore.profileScopedPreferenceKeys` already
/// matches it; [sweep] deletes the same keys explicitly (plus the plugin's
/// secrets) so turning the plugin off leaves no trace without deleting the
/// profile. [drain] lets both paths wait for an in-flight write first, so a
/// late write cannot resurrect what was just removed.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../orchestration/events/cursor.dart';
import '../orchestration/models/agent.dart';
import '../orchestration/models/run.dart';
import 'mutation_store.dart';
import 'team_storage_redaction.dart';

export 'mutation_store.dart';

/// The provider JSON behind one snapshot, as the store keeps it: raw lists
/// per scope, redacted before storage but never re-mapped here. Adapters rebuild models from these when
/// a cached view is shown before the host answers.
class OrchestrationSnapshotCache {
  const OrchestrationSnapshotCache({
    this.projects = const [],
    this.runs = const [],
    this.work = const [],
    this.agents = const [],
    this.gates = const [],
    this.usage,
    this.refreshedAt,
  });

  final List<Map<String, Object?>> projects;
  final List<Map<String, Object?>> runs;
  final List<Map<String, Object?>> work;
  final List<Map<String, Object?>> agents;
  final List<Map<String, Object?>> gates;
  final Map<String, Object?>? usage;

  /// When the host last answered a full or partial refresh.
  final DateTime? refreshedAt;

  Map<String, Object?> toJson() => {
    'projects': projects,
    'runs': runs,
    'work': work,
    'agents': agents,
    'gates': gates,
    if (usage != null) 'usage': usage,
    if (refreshedAt != null)
      'refreshedAt': refreshedAt!.toUtc().toIso8601String(),
  };

  /// Decodes a stored snapshot; null for anything that is not a map.
  static OrchestrationSnapshotCache? fromJson(Object? json) {
    if (json is! Map) return null;
    final refreshedAt = json['refreshedAt'];
    final usage = json['usage'];
    return OrchestrationSnapshotCache(
      projects: _maps(json['projects']),
      runs: _maps(json['runs']),
      work: _maps(json['work']),
      agents: _maps(json['agents']),
      gates: _maps(json['gates']),
      usage: usage is Map ? usage.cast<String, Object?>() : null,
      refreshedAt: refreshedAt is String
          ? DateTime.tryParse(refreshedAt)
          : null,
    );
  }

  static List<Map<String, Object?>> _maps(Object? value) => [
    if (value is List)
      for (final item in value)
        if (item is Map) item.cast<String, Object?>(),
  ];
}

/// The team as the app last read it, kept small on the device so the
/// Team page can still show it after Android stopped the phone's team (and
/// the app with it): each task's title and state and each agent's name and
/// state, and when they were read. Only for showing, dimmed, "as of" —
/// never acted on; the host stays the truth.
class TeamLastKnown {
  const TeamLastKnown({
    required this.asOf,
    this.runs = const [],
    this.agents = const [],
  });

  /// At most this many tasks and agents are kept.
  static const int limit = 30;

  /// Builds the record from a live read: the person's tasks (not the
  /// host's upkeep) and the agents, each cut to [limit].
  factory TeamLastKnown.of({
    required DateTime asOf,
    required Iterable<OrchestrationRun> runs,
    required Iterable<OrchestrationAgent> agents,
  }) => TeamLastKnown(
    asOf: asOf,
    runs: [
      for (final run in runs.where((run) => !run.isUpkeep).take(limit))
        OrchestrationRun(id: run.id, title: run.title, state: run.state),
    ],
    agents: [
      for (final agent in agents.take(limit))
        OrchestrationAgent(
          id: agent.id,
          name: agent.name,
          pool: agent.pool,
          state: agent.state,
          suspended: agent.suspended,
        ),
    ],
  );

  final DateTime asOf;
  final List<OrchestrationRun> runs;
  final List<OrchestrationAgent> agents;

  Map<String, Object?> toJson() => {
    'asOf': asOf.toUtc().toIso8601String(),
    'runs': [
      for (final run in runs)
        {'id': run.id, 'title': run.title, 'state': run.state.name},
    ],
    'agents': [
      for (final agent in agents)
        {
          'id': agent.id,
          'name': agent.name,
          if (agent.pool != null) 'pool': agent.pool,
          'state': agent.state.name,
          if (agent.suspended) 'suspended': true,
        },
    ],
  };

  /// Null for anything unreadable.
  static TeamLastKnown? fromJson(Object? json) {
    if (json is! Map) return null;
    final asOf = json['asOf'];
    final at = asOf is String ? DateTime.tryParse(asOf) : null;
    if (at == null) return null;
    T byName<T extends Enum>(List<T> values, Object? name, T fallback) {
      for (final value in values) {
        if (value.name == name) return value;
      }
      return fallback;
    }

    return TeamLastKnown(
      asOf: at,
      runs: [
        for (final item in OrchestrationSnapshotCache._maps(json['runs']))
          if (item['id'] case final String id)
            OrchestrationRun(
              id: id,
              title: item['title'] is String ? item['title']! as String : id,
              state: byName(RunState.values, item['state'], RunState.unknown),
            ),
      ],
      agents: [
        for (final item in OrchestrationSnapshotCache._maps(json['agents']))
          if ((item['id'], item['name']) case (
            final String id,
            final String name,
          ))
            OrchestrationAgent(
              id: id,
              name: name,
              pool: item['pool'] is String ? item['pool']! as String : null,
              state: byName(
                AgentState.values,
                item['state'],
                AgentState.unknown,
              ),
              suspended: item['suspended'] == true,
            ),
      ],
    );
  }
}

/// Per-profile cache, cursor and mutation receipts for the AI Team plugin.
class OrchestrationStore {
  OrchestrationStore(this.prefs, {FlutterSecureStorage? secure})
    : secure = secure ?? const FlutterSecureStorage(),
      mutations = MutationStore(prefs);

  final SharedPreferences prefs;

  /// Idempotency keys and receipts (TEAM-202), under
  /// `oc.orchestration.<profileId>.mutations.<key>` so [sweep] and the
  /// profile deletion drop them with the rest.
  final MutationStore mutations;

  /// The same Keystore the profiles keep their passwords in.
  final FlutterSecureStorage secure;
  final _writes = <String, Future<void>>{};

  /// `oc.orchestration.<profileId>.` — every key of the profile's plugin
  /// data starts with this.
  static String prefix(String profileId) => 'oc.orchestration.$profileId.';

  static String snapshotKey(String profileId) => '${prefix(profileId)}snapshot';

  /// `oc.orchestration.<profileId>.mutations.<key>`: one persisted
  /// [MutationRecord].
  static String mutationKey(String profileId, String key) =>
      MutationStore.keyFor(profileId, key);
  static String cursorKey(String profileId) => '${prefix(profileId)}cursor';

  /// `oc.orchestration.<profileId>.lastKnown`: the [TeamLastKnown] record.
  static String lastKnownKey(String profileId) =>
      '${prefix(profileId)}lastKnown';
  static String refreshedAtKey(String profileId) =>
      '${prefix(profileId)}refreshedAt';

  /// When the person dismissed the discovery offer for this profile, as an
  /// ISO-8601 instant. Under the same prefix, so a profile deletion or a
  /// [sweep] drops it with the rest.
  static String discoveryDismissedKey(String profileId) =>
      '${prefix(profileId)}discoveryDismissed';

  /// How long a dismissed discovery offer stays hidden (02-ux §1.3).
  static const discoveryDismissalTtl = Duration(days: 30);

  /// Which view (`list` / `graph`) the run detail's Work tab last showed
  /// for [runId]. Under the profile prefix so [sweep] drops it too.
  static String workViewKey(String profileId, String runId) =>
      '${prefix(profileId)}workView.$runId';

  /// The Start-a-run requests (TEAM-204) the person dismissed, as a JSON
  /// list of mutation keys under the profile prefix so [sweep] drops it.
  static String planningDismissedKey(String profileId) =>
      '${prefix(profileId)}planningDismissed';

  /// `oc.orchestration.<profileId>.phoneOfferDismissed`: how the optional
  /// on-device step ended for the Termux profile (TEAM-302, 03-onboarding
  /// §2). `skipped` after "Skip for now" (Settings re-offers once);
  /// `dismissed` after that re-offer was dismissed or the team was removed
  /// from the phone (never offered again). Absent: never offered.
  static String phoneOfferKey(String profileId) =>
      '${prefix(profileId)}phoneOfferDismissed';

  /// Keystore entries the plugin may hold for a profile. Nothing is written
  /// yet; the host-front grant (Sprint B) is reserved here so [sweep]
  /// already clears it.
  static List<String> secretKeys(String profileId) => [
    '${prefix(profileId)}grant',
  ];

  /// Every preference key the store currently holds for [profileId].
  Set<String> keysFor(String profileId) {
    if (profileId.isEmpty) return const {};
    final p = prefix(profileId);
    return {
      for (final key in prefs.getKeys())
        if (key.startsWith(p)) key,
    };
  }

  /// The cached snapshot, or null when none was saved or it is unreadable.
  OrchestrationSnapshotCache? readSnapshot(String profileId) {
    final raw = prefs.getString(snapshotKey(profileId));
    if (raw == null) return null;
    try {
      return OrchestrationSnapshotCache.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  /// The team as last read, or null when none was saved or it is
  /// unreadable.
  TeamLastKnown? readLastKnown(String profileId) {
    final raw = prefs.getString(lastKnownKey(profileId));
    if (raw == null) return null;
    try {
      return TeamLastKnown.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  /// Keeps [lastKnown] (redacted like the snapshot). A refused write is
  /// dropped: it is a convenience for a stopped team, never the truth.
  Future<void> saveLastKnown(String profileId, TeamLastKnown lastKnown) =>
      _write(profileId, () async {
        final String encoded;
        try {
          encoded = jsonEncode(redactTeamStoredValue(lastKnown.toJson()));
        } catch (_) {
          return;
        }
        await prefs.setString(lastKnownKey(profileId), encoded);
      });

  /// The persisted resume cursor, [EventCursor.none] when absent.
  EventCursor readCursor(String profileId) {
    final raw = prefs.getString(cursorKey(profileId));
    if (raw == null) return EventCursor.none;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return EventCursor.none;
      final seq = json['seq'];
      final id = json['lastEventId'];
      return EventCursor(
        seq: seq is int ? seq : null,
        lastEventId: id is String && id.isNotEmpty ? id : null,
      );
    } catch (_) {
      return EventCursor.none;
    }
  }

  /// How the on-device offer for [profileId] ended; [PhoneOffer.open] when
  /// it was never skipped.
  PhoneOffer phoneOffer(String profileId) =>
      PhoneOffer.parse(prefs.getString(phoneOfferKey(profileId)));

  /// Records how the on-device offer ended for [profileId].
  Future<void> setPhoneOffer(String profileId, PhoneOffer state) =>
      _write(profileId, () async {
        await prefs.setString(phoneOfferKey(profileId), state.name);
      });

  /// True while the discovery offer for [profileId] was dismissed less than
  /// [discoveryDismissalTtl] ago.
  bool isDiscoveryDismissed(String profileId, {DateTime? now}) {
    final raw = prefs.getString(discoveryDismissedKey(profileId));
    final at = raw == null ? null : DateTime.tryParse(raw);
    if (at == null) return false;
    return (now ?? DateTime.now()).difference(at) < discoveryDismissalTtl;
  }

  /// Remembers that the discovery offer was dismissed (or the plugin turned
  /// off) for [profileId]; the offer is not re-shown for
  /// [discoveryDismissalTtl].
  Future<void> dismissDiscovery(String profileId, {DateTime? now}) =>
      _write(profileId, () async {
        await prefs.setString(
          discoveryDismissedKey(profileId),
          (now ?? DateTime.now()).toUtc().toIso8601String(),
        );
      });

  /// Mutation keys of the Start-a-run requests dismissed on this profile.
  Set<String> readPlanningDismissed(String profileId) {
    final raw = prefs.getString(planningDismissedKey(profileId));
    if (raw == null) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return {for (final k in decoded) '$k'};
    } on FormatException {
      // A corrupt entry hides nothing.
    }
    return const {};
  }

  /// Remembers that the Start-a-run request [key] was dismissed.
  Future<void> savePlanningDismissed(String profileId, String key) =>
      _write(profileId, () async {
        final keys = readPlanningDismissed(profileId).toList()..add(key);
        await prefs.setString(
          planningDismissedKey(profileId),
          jsonEncode(keys.toSet().toList()),
        );
      });

  /// The remembered Work tab view for [runId], or null when none was saved.
  String? readWorkView(String profileId, String runId) =>
      prefs.getString(workViewKey(profileId, runId));

  /// Remembers the Work tab view for [runId]; null forgets it.
  Future<void> saveWorkView(String profileId, String runId, String? view) =>
      _write(profileId, () async {
        final key = workViewKey(profileId, runId);
        if (view == null) {
          await prefs.remove(key);
        } else {
          await prefs.setString(key, view);
        }
      });

  /// When the host last answered, or null before the first refresh.
  DateTime? lastRefreshedAt(String profileId) {
    final raw = prefs.getString(refreshedAtKey(profileId));
    return raw == null ? null : DateTime.tryParse(raw);
  }

  /// Persists [snapshot] and its `refreshedAt`. A refused write is dropped
  /// silently: the cache is a convenience, the host stays the truth.
  Future<void> saveSnapshot(
    String profileId,
    OrchestrationSnapshotCache snapshot,
  ) => _write(profileId, () async {
    final String encoded;
    try {
      encoded = jsonEncode(redactTeamStoredValue(snapshot.toJson()));
    } catch (_) {
      return;
    }
    await prefs.setString(snapshotKey(profileId), encoded);
    final at = snapshot.refreshedAt;
    if (at != null) {
      await prefs.setString(
        refreshedAtKey(profileId),
        at.toUtc().toIso8601String(),
      );
    }
  });

  /// Persists the resume cursor; [EventCursor.none] removes it.
  Future<void> saveCursor(String profileId, EventCursor cursor) =>
      _write(profileId, () async {
        if (cursor.isEmpty) {
          await prefs.remove(cursorKey(profileId));
          return;
        }
        await prefs.setString(
          cursorKey(profileId),
          jsonEncode({
            if (cursor.seq != null) 'seq': cursor.seq,
            if (cursor.lastEventId != null) 'lastEventId': cursor.lastEventId,
          }),
        );
      });

  /// Waits for the profile's in-flight writes; never throws.
  Future<void> drain(String profileId) async {
    try {
      await (_writes[profileId] ?? Future<void>.value());
    } catch (_) {}
  }

  /// Deletes every `oc.orchestration.<profileId>.` preference and every
  /// secret in [secretKeys], through the same stores the profiles use.
  /// Returns the keys that refused to go (empty on success); a Keystore
  /// failure is reported the same way rather than thrown.
  Future<Set<String>> sweep(String profileId) async {
    if (profileId.isEmpty) return const {};
    await drain(profileId);
    final failed = <String>{};
    for (final key in keysFor(profileId)) {
      try {
        if (!await prefs.remove(key)) failed.add(key);
      } catch (_) {
        failed.add(key);
      }
    }
    for (final key in secretKeys(profileId)) {
      try {
        await secure.delete(key: key);
      } catch (_) {
        failed.add(key);
      }
    }
    return failed;
  }

  Future<void> _write(String profileId, Future<void> Function() body) {
    if (profileId.isEmpty) return Future<void>.value();
    final previous = _writes[profileId] ?? Future<void>.value();
    final writing = previous.catchError((Object _) {}).then((_) => body());
    _writes[profileId] = writing;
    return writing.whenComplete(() {
      if (identical(_writes[profileId], writing)) _writes.remove(profileId);
    });
  }
}

/// The state of the optional "Also run an AI team on this phone" offer for
/// a Termux profile (03-onboarding §2; TEAM-302).
enum PhoneOffer {
  /// Never skipped: the onboarding block shows after step 3.
  open,

  /// Skipped in onboarding: Settings › Plugins re-offers it once.
  skipped,

  /// The re-offer was dismissed, or the team was removed: not offered again.
  dismissed;

  static PhoneOffer parse(String? raw) => switch (raw) {
    'skipped' => skipped,
    'dismissed' => dismissed,
    _ => open,
  };
}
