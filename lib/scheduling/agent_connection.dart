import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../api2/client.dart';
import '../api2/gateway.dart';
import '../builtin/builtin_linux.dart';
import '../codex/gateway.dart';
import '../domain/server_gateway.dart';
import '../paseo/gateway.dart';
import '../state/profiles.dart';

/// Routing identity only. Credentials never enter schedule storage or history.
String scheduledProfileFingerprint(ServerProfile profile) => sha256
    .convert(utf8.encode(jsonEncode(profile.toJson()..remove('name'))))
    .toString();

class ScheduledRunFailure implements Exception {
  const ScheduledRunFailure(this.reason);
  final String reason;
}

/// A private transport and, where needed, one native runtime ownership token.
/// Native code owns the watchdog and exact process identity, including when
/// Dart times out or is killed before acquire returns.
class ScheduledAgentConnection {
  ScheduledAgentConnection({
    required this.gateway,
    this.startedPhoneServer = false,
    Future<void> Function()? release,
  }) : _release = release;

  final ServerGateway gateway;
  final bool startedPhoneServer;
  final Future<void> Function()? _release;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      gateway.close();
    } finally {
      await _release?.call();
    }
  }

  static const _channel = MethodChannel('oc/scheduled_prompts');

  static Future<ScheduledAgentConnection> open({
    required ServerProfile profile,
    required String projectPath,
    String? workspace,
    required int deadlineEpochMs,
  }) async {
    if (profile.transientTransport) {
      throw const ScheduledRunFailure('unsupported');
    }
    if (profile.cleartextUnconfirmed) {
      throw const ScheduledRunFailure('cleartext_unconfirmed');
    }
    if (profile.requiresPasswordReentry ||
        profile.requiresCodexTokenReentry ||
        (profile.backend == ServerBackend.codex &&
            profile.codexToken.isEmpty)) {
      throw const ScheduledRunFailure('auth_required');
    }
    if (profile.backend == ServerBackend.openCode &&
        profile.flavor != ServerFlavor.v2) {
      throw const ScheduledRunFailure('unsupported');
    }
    String? leaseToken;
    var started = false;
    ServerGateway? gateway;
    Future<void> release() async {
      if (leaseToken != null) {
        await _channel.invokeMethod<void>('releasePhoneServer', {
          'token': leaseToken,
        });
      }
    }

    try {
      if (profile.backend == ServerBackend.openCode &&
          BuiltinLinux.supported &&
          BuiltinLinux.managesServerUrl(profile.baseUrl)) {
        final lease = await _channel
            .invokeMapMethod<String, dynamic>('acquirePhoneServer', {
              'profileId': profile.id,
              'runtime': 'openCode2',
              'password': profile.password,
              'deadlineEpochMs': deadlineEpochMs,
            });
        if (lease == null || lease['token'] is! String) {
          throw const ScheduledRunFailure('unavailable');
        }
        leaseToken = lease['token'] as String;
        started = lease['started'] == true;
      }
      gateway = switch (profile.backend) {
        ServerBackend.openCode => Api2Gateway(
          // Same trust as the foreground connection: the person's plain-HTTP
          // consent and approved certificate travel with this transport, or
          // its request guard refuses every call to that server.
          client: Api2Client.connect(
            baseUrl: profile.baseUrl,
            username: 'opencode',
            password: profile.password,
            cleartextConfirmedOrigin: profile.cleartextConfirmedOrigin,
            certificatePinSha256:
                profile.certificatePinOrigin ==
                    cleartextOriginOf(profile.baseUrl)
                ? profile.certificatePinSha256
                : null,
          ),
        ),
        ServerBackend.codex => CodexGateway.connect(
          baseUrl: profile.baseUrl,
          token: profile.codexToken,
          directory: projectPath,
        ),
        ServerBackend.paseo => PaseoGateway.connect(
          baseUrl: profile.baseUrl,
          password: profile.codexToken,
          directory: projectPath,
        ),
      };
      gateway.setLocation(directory: projectPath, workspace: workspace);
      return ScheduledAgentConnection(
        gateway: gateway,
        startedPhoneServer: started,
        release: release,
      );
    } catch (_) {
      gateway?.close();
      await release();
      rethrow;
    }
  }
}
