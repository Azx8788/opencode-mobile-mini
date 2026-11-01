import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/session_handoff.dart';
import '../domain/session_address_link.dart';
import '../domain/team_link.dart';

/// A session handoff link (`opencode-mobile://session?…`) opened on this
/// phone, typically by scanning the QR another phone shows, or an AI Team
/// link (`opencode-mobile://team/…`, TEAM-203). The Kotlin side captures
/// the VIEW intent and hands the URI text over here; [pending] holds the
/// parsed [SessionLink] and [pendingTeam] the parsed [TeamLink] until the
/// app shell routes them. Mirrors
/// LaunchShortcut: one consume on start for the link that launched the app,
/// a live `linked` push for links opened while the engine is already
/// running. Parsing is strict ([SessionLink.parse]); anything malformed is
/// dropped here; recognizable versioned session links retain only a safe error
/// category for the shell. This class never connects,
/// creates a session or sends anything. Off Android the class is inert.
class SessionLinkIntent {
  SessionLinkIntent({@visibleForTesting MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('oc/link');

  final MethodChannel _channel;

  /// The most recent valid link that nothing has consumed yet.
  final ValueNotifier<SessionLink?> pending = ValueNotifier<SessionLink?>(null);

  /// The most recent valid AI Team link that nothing has consumed yet.
  final ValueNotifier<TeamLink?> pendingTeam = ValueNotifier<TeamLink?>(null);

  /// Parsed only, never automatically connected. The app must gate reception
  /// on verified v2 support and obtain contact consent before any I/O.
  final ValueNotifier<SessionAddressLink?> pendingAddress =
      ValueNotifier<SessionAddressLink?>(null);

  /// A recognizable versioned link failed local parsing. Retains only the
  /// category, never the input or an exception carrying host/session metadata.
  final ValueNotifier<SessionAddressFailureCode?> pendingAddressFailure =
      ValueNotifier<SessionAddressFailureCode?>(null);

  bool _started = false;
  bool _disposed = false;
  int _acceptGeneration = 0;

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Registers for links delivered while the app is running and drains the
  /// link that may have launched it. Safe to call once; later calls no-op.
  Future<void> start() async {
    if (_started || _disposed || !supported) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (!_disposed && call.method == 'linked') _accept(call.arguments);
      return null;
    });
    final consumeGeneration = _acceptGeneration;
    try {
      final value = await _channel.invokeMethod<String>('consumeSessionLink');
      // A live link can arrive while the cold-start consume is in flight;
      // keep the newer value rather than replacing it with the stale one.
      if (!_disposed && consumeGeneration == _acceptGeneration) {
        _accept(value);
      }
    } on MissingPluginException {
      // Tests and desktop hosts have no channel implementation.
    } on PlatformException {
      // A capture failure must never block startup.
    }
  }

  void _accept(Object? value) {
    if (_disposed) return;
    final address = SessionAddressLink.parse(value);
    if (address != null) {
      _acceptGeneration++;
      pending.value = null;
      pendingTeam.value = null;
      pendingAddressFailure.value = null;
      pendingAddress.value = address;
      return;
    }
    if (value is String &&
        value.toLowerCase().startsWith('opencode-mobile://session/v')) {
      try {
        SessionAddressLink.require(value);
      } on SessionAddressFailure catch (failure) {
        _acceptGeneration++;
        pending.value = null;
        pendingTeam.value = null;
        pendingAddress.value = null;
        pendingAddressFailure.value = failure.code;
      }
      return;
    }
    final link = SessionLink.parse(value);
    if (link != null) {
      _acceptGeneration++;
      pendingTeam.value = null;
      pendingAddress.value = null;
      pendingAddressFailure.value = null;
      pending.value = link;
      return;
    }
    final team = TeamLink.parse(value);
    if (team == null) return;
    _acceptGeneration++;
    pending.value = null;
    pendingAddress.value = null;
    pendingAddressFailure.value = null;
    pendingTeam.value = team;
  }

  /// Takes the pending link, leaving nothing behind.
  SessionLink? take() {
    if (_disposed) return null;
    final link = pending.value;
    pending.value = null;
    return link;
  }

  /// Takes the pending AI Team link, leaving nothing behind.
  TeamLink? takeTeam() {
    if (_disposed) return null;
    final link = pendingTeam.value;
    pendingTeam.value = null;
    return link;
  }

  /// Consumes or dismisses the locator without contacting its host.
  SessionAddressLink? takeAddress() {
    if (_disposed) return null;
    final link = pendingAddress.value;
    pendingAddress.value = null;
    return link;
  }

  /// Consumes or dismisses a local parsing failure without retaining its input.
  SessionAddressFailureCode? takeAddressFailure() {
    if (_disposed) return null;
    final code = pendingAddressFailure.value;
    pendingAddressFailure.value = null;
    return code;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_started) _channel.setMethodCallHandler(null);
    pending.dispose();
    pendingTeam.dispose();
    pendingAddress.dispose();
    pendingAddressFailure.dispose();
  }
}
