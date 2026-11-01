import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/models.dart';
import '../api2/client.dart';
import '../api2/gateway.dart';
import '../domain/server_gateway.dart';
import '../domain/team_project_gateway.dart';
import '../orchestration/adapters/inapp/phone_engine_gateway.dart';
import '../state/profiles.dart';
import 'widget_v2_contract.dart';
import 'widget_snapshot.dart';

/// Metadata only. An edited endpoint, routing identity or Team configuration
/// invalidates the old launcher target without ever copying credentials.
String widgetProfileFingerprint(ServerProfile profile) => sha256
    .convert(utf8.encode(jsonEncode(profile.toJson()..remove('name'))))
    .toString();

/// Stable server user-message identity, never the text of that message.
String? widgetRunMarker(Iterable<MessageWithParts> messages) {
  // OC2 timeline records (including stable's terminal `idle` record) use
  // role=user in the protocol-neutral transcript, distinguished by v2: parts.
  // They are not new prompts and must not invalidate a completed turn.
  final users = messages
      .where(
        (m) =>
            m.info.role == 'user' &&
            !m.parts.any((part) => part.type.startsWith('v2:')),
      )
      .toList();
  if (users.isEmpty) return null;
  users.sort(
    (a, b) => (a.info.time?.created ?? 0).compareTo(b.info.time?.created ?? 0),
  );
  return users.last.info.id.isEmpty ? null : users.last.info.id;
}

class WidgetActionTransport {
  WidgetActionTransport({this.gateway, this.team});
  final ServerGateway? gateway;
  final OrchestrationProjectGateway? team;
  Future<void> close() async {
    try {
      gateway?.close();
    } catch (_) {}
    try {
      await team?.close().timeout(const Duration(seconds: 1));
    } catch (_) {}
  }
}

typedef WidgetActionTransportFactory =
    WidgetActionTransport Function(
      ServerProfile profile,
      Map<String, dynamic> descriptor,
      bool team,
    );

WidgetActionTransport createWidgetActionTransport(
  ServerProfile p,
  Map<String, dynamic> descriptor,
  bool team,
) {
  if (team) {
    if (p.orchestration?.provider != OrchestrationProvider.phoneEngine ||
        p.teamEngineAuth.isEmpty) {
      throw const _Refused('unsupported');
    }
    return WidgetActionTransport(
      team: PhoneEngineGateway(
        baseUrl: p.orchestration!.url,
        profileId: p.id,
        bearerToken: p.teamEngineAuth,
      ),
    );
  }
  // Socket approvals are scoped to the original connection, and their cached
  // busy state cannot establish a cold run identity. Do not reconstruct them.
  if (p.backend != ServerBackend.openCode ||
      p.requiresOpenCode2Migration ||
      p.transientTransport ||
      p.requiresPasswordReentry ||
      p.cleartextUnconfirmed) {
    throw const _Refused('unsupported');
  }
  final ServerGateway gateway = Api2Gateway(
    client: Api2Client.connect(
      baseUrl: p.baseUrl,
      password: p.password,
      username: 'opencode',
      cleartextConfirmedOrigin: p.cleartextConfirmedOrigin,
      certificatePinSha256:
          p.certificatePinOrigin == cleartextOriginOf(p.baseUrl)
          ? p.certificatePinSha256
          : null,
    ),
  );
  gateway.setLocation(
    directory: descriptor['directory'] as String?,
    workspace: descriptor['workspace'] as String?,
  );
  return WidgetActionTransport(gateway: gateway);
}

/// One explicit launcher tap, including bounded status reconciliation. No
/// controller, runtime start, reconnect retry or background preference write.
class WidgetActionRunner {
  WidgetActionRunner({
    required this.loadProfile,
    required this.loadTarget,
    required this.isCurrent,
    WidgetActionTransportFactory? createTransport,
    DateTime Function()? now,
    this.statusSettleTimeout = const Duration(seconds: 5),
    this.statusPollInterval = const Duration(milliseconds: 250),
  }) : createTransport = createTransport ?? createWidgetActionTransport,
       now = now ?? DateTime.now;
  final Future<ServerProfile?> Function(String) loadProfile;
  final Future<Map<String, dynamic>?> Function(WidgetAction, String) loadTarget;
  final Future<bool> Function(WidgetAction, String) isCurrent;
  final WidgetActionTransportFactory createTransport;
  final DateTime Function() now;
  final Duration statusSettleTimeout;
  final Duration statusPollInterval;
  final Map<String, Future<Map<String, Object?>>> _requests = {};
  bool _cancelled = false;
  WidgetActionTransport? _transport;

  void cancel() {
    _cancelled = true;
    unawaited(_transport?.close());
  }

  Future<Map<String, Object?>> execute(
    WidgetAction action,
    Map<String, dynamic> snapshot,
    int deadlineEpochMs,
  ) => _requests.putIfAbsent(
    action.id,
    () => _execute(action, snapshot, deadlineEpochMs),
  );

  Future<Map<String, Object?>> _execute(
    WidgetAction action,
    Map<String, dynamic> snapshot,
    int deadlineEpochMs,
  ) async {
    var dispatched = false;
    WidgetActionResult result(String status, [String? error]) =>
        WidgetActionResult(action.id, action.action, status, error);
    try {
      final descriptor = snapshot['onDemand'];
      if (descriptor is! Map ||
          descriptor['fingerprint'] is! String ||
          snapshot['profileID'] != action.profileID ||
          snapshot['scopeToken'] != action.scopeToken) {
        throw const _Refused('staleRequest');
      }
      final fingerprint = descriptor['fingerprint'] as String;
      Future<void> guard() async {
        if (_cancelled || now().millisecondsSinceEpoch >= deadlineEpochMs) {
          throw const _Refused('unavailable');
        }
        if (!await isCurrent(action, fingerprint)) {
          throw const _Refused('staleRequest');
        }
        if (_cancelled || now().millisecondsSinceEpoch >= deadlineEpochMs) {
          throw const _Refused('unavailable');
        }
      }

      Future<T> read<T>(Future<T> Function() fn) async {
        await guard();
        final remaining = deadlineEpochMs - now().millisecondsSinceEpoch;
        if (remaining <= 0) throw const _Refused('unavailable');
        final value = await fn().timeout(Duration(milliseconds: remaining));
        await guard();
        return value;
      }

      final rows =
          (snapshot['sessions'] as List?)?.whereType<Map>().toList() ??
          const <Map>[];
      final row = rows
          .where(
            (r) => action.runID.isNotEmpty
                ? (r['team'] is Map &&
                      (r['team'] as Map)['runID'] == action.runID)
                : r['id'] == action.sessionID,
          )
          .firstOrNull;
      if (row == null ||
          row['onDemandActions'] is! List ||
          !(row['onDemandActions'] as List).contains(action.action)) {
        throw const _Refused('unsupported');
      }
      final profile = await read(() => loadProfile(action.profileID));
      if (profile == null ||
          profile.transientTransport ||
          widgetProfileFingerprint(profile) != fingerprint) {
        throw const _Refused('staleRequest');
      }
      final target = await read(() => loadTarget(action, fingerprint));
      if (target == null ||
          target['profileID'] != action.profileID ||
          target['scopeToken'] != action.scopeToken ||
          target['fingerprint'] != fingerprint) {
        throw const _Refused('staleRequest');
      }
      final teamAction =
          action.action == 'approvePlan' || action.action == 'resume';
      final transport = _transport = createTransport(
        profile,
        target,
        teamAction,
      );
      Future<T> mutate<T>(Future<T> Function() fn) async {
        await guard();
        final remaining = deadlineEpochMs - now().millisecondsSinceEpoch;
        if (remaining <= 0) throw const _Refused('unavailable');
        dispatched = true;
        return fn().timeout(Duration(milliseconds: remaining));
      }

      bool? serverBusy;
      String? runMarker = row['runMarker'] as String?;
      if (teamAction) {
        final team = transport.team;
        if (team is PhoneEngineGateway) team.beforeCommand = guard;
        if (team == null) throw const _Refused('unsupported');
        final workspace = await read(team.teamWorkspace);
        final project = workspace.projects
            .where((p) => p.id == action.runID)
            .firstOrNull;
        final oldTeam = row['team'] as Map;
        if (workspace.simulated ||
            project == null ||
            project.simulated ||
            oldTeam['revision'] != project.revision ||
            oldTeam['gateID'] != action.gateID ||
            oldTeam['action'] != action.action ||
            (action.action == 'resume'
                ? !project.planApproved ||
                      !const {'paused', 'interrupted'}.contains(project.status)
                : project.planApproved ||
                      !const {'plan', 'planned'}.contains(project.status) ||
                      project.tasks.isEmpty ||
                      project.specVersions.isEmpty)) {
          throw const _Refused('staleRequest');
        }
        await guard();
        final reply = await mutate(
          () => team.executeProject(
            TeamProjectCommand(
              requestId: action.id,
              projectId: action.runID,
              expectedRevision: project.revision,
              action: action.action == 'resume'
                  ? TeamProjectAction.resumeProject
                  : TeamProjectAction.approvePlan,
            ),
          ),
        );
        if (!reply.accepted) {
          final certain = const {
            'staleRevision',
            'revisionConflict',
            'unsupportedCommand',
            'boundaryUnverified',
            'protocolUnverified',
            'invalidState',
          }.contains(reply.code);
          return result(
            certain ? 'rejected' : 'uncertain',
            certain ? 'staleRequest' : 'uncertainDelivery',
          ).toJson();
        }
      } else {
        final gateway = transport.gateway;
        if (gateway == null) throw const _Refused('unsupported');
        // A fresh OpenCode 2 transport has not negotiated its API dialect.
        // The pending route works on both generations, but stable permission
        // replies require `decision` instead of `reply`. Health settles that
        // translation before any command, under the same deadline and guards.
        final health = await read(gateway.health);
        if (!health.healthy) throw const _Refused('unavailable');
        switch (action.action) {
          case 'allowOnce':
          case 'reject':
            if (row['requestID'] != action.requestID ||
                action.requestID.isEmpty) {
              throw const _Refused('staleRequest');
            }
            final pending = await read(gateway.pendingPermissions);
            if (!pending.any(
              (p) =>
                  p.id == action.requestID && p.sessionID == action.sessionID,
            )) {
              throw const _Refused('staleRequest');
            }
            // Capture a server turn identity before acknowledging permission;
            // delayed read-only checks must never settle a newer turn.
            runMarker = widgetRunMarker(
              await read(() => gateway.messages(action.sessionID)),
            );
            await guard();
            await mutate(
              () => gateway.respondPermission(
                action.requestID,
                action.action == 'allowOnce' ? 'once' : 'reject',
                legacySessionID: action.sessionID,
                legacyPermissionID: action.requestID,
              ),
            );
          case 'stop':
            if (row['busy'] != true ||
                row['startedAt'] != action.expectedStartedAt ||
                row['runMarker'] is! String) {
              throw const _Refused('staleRequest');
            }
            final messages = await read(
              () => gateway.messages(action.sessionID),
            );
            if (widgetRunMarker(messages) != row['runMarker']) {
              throw const _Refused('staleRequest');
            }
            final statuses = await read(gateway.sessionStatuses);
            if (!const {'busy', 'retry'}.contains(statuses[action.sessionID])) {
              throw const _Refused('staleRequest');
            }
            await guard();
            await mutate(() => gateway.abort(action.sessionID));
          default:
            throw const _Refused('unsupported');
        }
        // Acknowledgement does not mean the turn ended, even for abort. Read
        // server truth through the same gateway before closing the cold socket.
        // Leave time for native settlement within its existing 30-second lease.
        final budget = (deadlineEpochMs - now().millisecondsSinceEpoch - 500)
            .clamp(0, statusSettleTimeout.inMilliseconds);
        final elapsed = Stopwatch()..start();
        while (elapsed.elapsedMilliseconds < budget) {
          await guard();
          final remaining = budget - elapsed.elapsedMilliseconds;
          if (remaining <= 0) break;
          Map<String, String> statuses;
          try {
            statuses = await gateway.sessionStatuses().timeout(
              Duration(milliseconds: remaining),
            );
          } catch (_) {
            // The command was acknowledged. A failed read cannot make it
            // retryable, nor prove idle. Keep the last state, visibly detached.
            break;
          }
          await guard();
          final status = statuses[action.sessionID];
          if (status == null || status == 'idle') {
            serverBusy = false;
            break;
          }
          if (status != 'busy' && status != 'retry') break;
          serverBusy = true;
          final delay = (budget - elapsed.elapsedMilliseconds).clamp(
            0,
            statusPollInterval.inMilliseconds,
          );
          if (delay <= 0) break;
          await Future<void>.delayed(Duration(milliseconds: delay));
        }
      }
      await guard();
      final updated = Map<String, dynamic>.from(snapshot);
      updated['connected'] = false;
      updated['sessions'] = [
        for (final old in rows)
          if (identical(old, row))
            {
              for (final entry in old.entries)
                if (!(const {'allowOnce', 'reject'}.contains(action.action) &&
                    entry.key == 'requestID'))
                  entry.key: entry.value,
              'busy': ?serverBusy,
              'runMarker': ?runMarker,
              if (serverBusy == false) ...{
                'busy': false,
                'startedAt': 0,
                'step': '',
              },
              'onDemandActions': [
                if (const {'allowOnce', 'reject'}.contains(action.action) &&
                    (serverBusy ?? old['busy']) == true &&
                    old['runMarker'] is String &&
                    (old['onDemandActions'] as List).contains('stop'))
                  'stop',
              ],
              if (teamAction)
                'team': {
                  for (final entry in (old['team'] as Map).entries)
                    if (entry.key != 'action') entry.key: entry.value,
                },
            }
          else
            old,
      ];
      updated['runningCount'] = (updated['sessions'] as List)
          .where((r) => (r as Map)['busy'] == true)
          .length;
      if (action.action == 'allowOnce' || action.action == 'reject') {
        updated['pendingCount'] = ((snapshot['pendingCount'] as int? ?? 1) - 1)
            .clamp(0, 1000000);
      }
      return {...result('accepted').toJson(), 'snapshot': updated};
    } on _Refused catch (e) {
      return result(
        dispatched ? 'uncertain' : 'rejected',
        dispatched ? 'uncertainDelivery' : e.code,
      ).toJson();
    } catch (_) {
      // Never return server messages, credential errors, prompts or traces.
      return result(
        dispatched ? 'uncertain' : 'rejected',
        dispatched ? 'uncertainDelivery' : 'unavailable',
      ).toJson();
    } finally {
      await _transport?.close();
      _transport = null;
    }
  }
}

class _Refused implements Exception {
  const _Refused(this.code);
  final String code;
}

/// Re-reads durable ownership immediately before dispatch and after settlement.
/// A deleted profile or a foreground profile/scope switch invalidates the tap.
Future<bool> widgetActionIsCurrent(
  SharedPreferences prefs,
  WidgetAction action,
  String fingerprint, {
  Map<String, dynamic>? expectedSnapshot,
}) async {
  await prefs.reload();
  if (prefs.getString('oc.activeProfile') != action.profileID ||
      readWidgetActionTarget(prefs, action, fingerprint) == null) {
    return false;
  }
  final profiles = jsonDecode(prefs.getString('oc.profiles') ?? '[]');
  if (profiles is! List) return false;
  final metadata = profiles
      .whereType<Map>()
      .where((p) => p['id'] == action.profileID)
      .firstOrNull;
  if (metadata == null ||
      widgetProfileFingerprint(
            ServerProfile.fromJson(Map<String, dynamic>.from(metadata)),
          ) !=
          fingerprint) {
    return false;
  }
  final raw = prefs.getString('oc.widgetSessions');
  if (raw == null) return false;
  final current = jsonDecode(raw);
  if (current is! Map ||
      current['profileID'] != action.profileID ||
      current['scopeToken'] != action.scopeToken) {
    return false;
  }
  Map? target(Map source) => (source['sessions'] as List?)
      ?.whereType<Map>()
      .where(
        (r) => action.runID.isNotEmpty
            ? r['team'] is Map && (r['team'] as Map)['runID'] == action.runID
            : r['id'] == action.sessionID,
      )
      .firstOrNull;
  final row = target(current);
  if (row == null ||
      row['onDemandActions'] is! List ||
      !(row['onDemandActions'] as List).contains(action.action)) {
    return false;
  }
  final expected = expectedSnapshot == null ? null : target(expectedSnapshot);
  if (action.action == 'allowOnce' || action.action == 'reject') {
    return row['requestID'] == action.requestID;
  }
  if (action.action == 'stop') {
    return row['busy'] == true &&
        row['startedAt'] == action.expectedStartedAt &&
        (expected == null || row['runMarker'] == expected['runMarker']);
  }
  final team = row['team'];
  return team is Map &&
      team['gateID'] == action.gateID &&
      team['action'] == action.action &&
      (expected == null ||
          team['revision'] == (expected['team'] as Map?)?['revision']);
}

/// Read only app-private routing. Never fall back to paths from the snapshot.
Map<String, dynamic>? readWidgetActionTarget(
  SharedPreferences prefs,
  WidgetAction action,
  String fingerprint,
) {
  final raw = prefs.getString(
    WidgetSessionSnapshot.targetKey(action.profileID),
  );
  if (raw == null) return null;
  try {
    final target = jsonDecode(raw);
    if (target is! Map ||
        target['profileID'] != action.profileID ||
        target['scopeToken'] != action.scopeToken ||
        target['fingerprint'] != fingerprint ||
        (target['directory'] != null && target['directory'] is! String) ||
        (target['workspace'] != null && target['workspace'] is! String)) {
      return null;
    }
    return Map<String, dynamic>.from(target);
  } catch (_) {
    return null;
  }
}
