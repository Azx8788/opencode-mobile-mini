import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../state/profiles.dart';
import 'widget_action_runner.dart';
import 'widget_v2_contract.dart';
import 'widget_snapshot.dart';

/// A scheduled check has no command API: one bounded read of the original turn.
/// The private ticket contains opaque identity only, never endpoint or credentials.
class WidgetStatusRunner {
  WidgetStatusRunner({
    required this.loadProfile,
    required this.loadTarget,
    required this.isCurrent,
    WidgetActionTransportFactory? createTransport,
    DateTime Function()? now,
  }) : createTransport = createTransport ?? createWidgetActionTransport,
       now = now ?? DateTime.now;

  final Future<ServerProfile?> Function(String) loadProfile;
  final Future<Map<String, dynamic>?> Function(WidgetAction, String) loadTarget;
  final Future<bool> Function(Map<String, dynamic>) isCurrent;
  final WidgetActionTransportFactory createTransport;
  final DateTime Function() now;
  WidgetActionTransport? _transport;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    unawaited(_transport?.close());
  }

  Future<Map<String, Object?>> check(
    Map<String, dynamic> ticket,
    int deadlineEpochMs,
  ) async {
    try {
      if (!const [
        'profileID',
        'scopeToken',
        'sessionID',
        'fingerprint',
        'runMarker',
        'token',
      ].every(
        (key) => ticket[key] is String && (ticket[key] as String).isNotEmpty,
      )) {
        return const {'status': 'stale'};
      }
      Future<void> guard() async {
        if (_cancelled || now().millisecondsSinceEpoch >= deadlineEpochMs) {
          throw const _StatusUnavailable();
        }
        if (!await isCurrent(ticket)) throw const _StatusStale();
        if (_cancelled || now().millisecondsSinceEpoch >= deadlineEpochMs) {
          throw const _StatusUnavailable();
        }
      }

      Future<T> read<T>(Future<T> Function() fn) async {
        await guard();
        final value = await fn().timeout(
          Duration(
            milliseconds: deadlineEpochMs - now().millisecondsSinceEpoch,
          ),
        );
        await guard();
        return value;
      }

      final profile = await read(
        () => loadProfile(ticket['profileID'] as String),
      );
      if (profile == null ||
          widgetProfileFingerprint(profile) != ticket['fingerprint']) {
        throw const _StatusStale();
      }
      final action = WidgetAction(
        id: ticket['token'] as String,
        action: 'stop',
        profileID: ticket['profileID'] as String,
        scopeToken: ticket['scopeToken'] as String,
        sessionID: ticket['sessionID'] as String,
      );
      final target = await read(
        () => loadTarget(action, ticket['fingerprint'] as String),
      );
      if (target == null ||
          target['profileID'] != ticket['profileID'] ||
          target['scopeToken'] != ticket['scopeToken'] ||
          target['fingerprint'] != ticket['fingerprint']) {
        throw const _StatusStale();
      }
      final transport = _transport = createTransport(profile, target, false);
      final gateway = transport.gateway;
      if (gateway == null) throw const _StatusUnavailable();
      if (!(await read(gateway.health)).healthy) {
        throw const _StatusUnavailable();
      }
      final messages = await read(() => gateway.messages(action.sessionID));
      if (widgetRunMarker(messages) != ticket['runMarker']) {
        throw const _StatusStale();
      }
      final statuses = await read(gateway.sessionStatuses);
      final pending = await read(gateway.pendingPermissions);
      if (pending.any((p) => p.sessionID == action.sessionID)) {
        throw const _StatusStale();
      }
      // Recheck server turn identity after the status read too. A new server
      // turn can start while the app remains closed and its snapshot unchanged.
      final finalMessages = await read(
        () => gateway.messages(action.sessionID),
      );
      if (widgetRunMarker(finalMessages) != ticket['runMarker']) {
        throw const _StatusStale();
      }
      await guard();
      final status = statuses[action.sessionID];
      if (status == null || status == 'idle') {
        final preview = safeWidgetAssistantPreview(finalMessages);
        return {'status': 'idle', if (preview.isNotEmpty) 'preview': preview};
      }
      if (status == 'busy' || status == 'retry') {
        return const {'status': 'busy'};
      }
      return const {'status': 'unavailable'};
    } on _StatusStale {
      return const {'status': 'stale'};
    } catch (_) {
      return const {'status': 'unavailable'};
    } finally {
      await _transport?.close();
      _transport = null;
    }
  }
}

class _StatusStale implements Exception {
  const _StatusStale();
}

class _StatusUnavailable implements Exception {
  const _StatusUnavailable();
}

Future<bool> widgetStatusIsCurrent(
  SharedPreferences prefs,
  Map<String, dynamic> ticket,
) async {
  await prefs.reload();
  if (prefs.getString('oc.activeProfile') != ticket['profileID']) return false;
  final profiles = jsonDecode(prefs.getString('oc.profiles') ?? '[]');
  if (profiles is! List) return false;
  final metadata = profiles
      .whereType<Map>()
      .where((p) => p['id'] == ticket['profileID'])
      .firstOrNull;
  if (metadata == null ||
      widgetProfileFingerprint(
            ServerProfile.fromJson(Map<String, dynamic>.from(metadata)),
          ) !=
          ticket['fingerprint']) {
    return false;
  }
  final saved = jsonDecode(
    prefs.getString('oc.widgetFollowup.${ticket['profileID']}') ?? '{}',
  );
  if (saved is! Map ||
      (saved[ticket['sessionID']] as Map?)?['token'] != ticket['token']) {
    return false;
  }
  final current = jsonDecode(prefs.getString('oc.widgetSessions') ?? '{}');
  if (current is! Map ||
      current['version'] != 2 ||
      current['profileID'] != ticket['profileID'] ||
      current['scopeToken'] != ticket['scopeToken'] ||
      (current['onDemand'] as Map?)?['fingerprint'] != ticket['fingerprint']) {
    return false;
  }
  final row = (current['sessions'] as List?)
      ?.whereType<Map>()
      .where((row) => row['id'] == ticket['sessionID'])
      .firstOrNull;
  return row != null &&
      row['busy'] == true &&
      (row['requestID'] == null || row['requestID'] == '') &&
      row['runMarker'] == ticket['runMarker'] &&
      (row['startedAt'] ?? 0) == ticket['startedAt'];
}
