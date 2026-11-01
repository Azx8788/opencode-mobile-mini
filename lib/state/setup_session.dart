import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api2/gateway.dart';
import '../api2/setup_config_adapter.dart';
import '../domain/server_gateway.dart';
import '../domain/setup_assistant.dart';
import 'connection.dart';
import 'setup_controller.dart';

/// Builds the read-only setup adapter for a live transport, or null when the
/// server has no verified setup adapter (Codex and Claude Code via Paseo).
/// Gated on [ServerCapabilities.setupConfigRead], never on the flavor enum;
/// the transport type only picks which protocol adapter speaks to it.
typedef SetupGatewayFactory = SetupConfigGateway? Function(ServerGateway api);

SetupConfigGateway? setupGatewayFor(ServerGateway api) {
  if (!api.capabilities.setupConfigRead) return null;
  if (api is Api2Gateway) {
    return OpenCode2SetupConfigGateway(client: api.client);
  }
  return null;
}

/// Composition owner of the review-only AI setup page (AI setup assistant
/// contract, 2026-09-28): it constructs the [SetupController] outside the
/// UI, for the connection's current profile, location and transport, and
/// recreates it (awaiting the old one's disposal) whenever any of them
/// changes, including an away-and-back switch. It follows the connection's
/// online state: offline keeps the last safe data; reconnecting reads again.
///
/// Review only: this owner exposes [refresh] and nothing that proposes,
/// applies or undoes a change.
class SetupSession extends ChangeNotifier {
  SetupSession(this.connection, {SetupGatewayFactory? gatewayFor})
    : _gatewayFor = gatewayFor ?? setupGatewayFor {
    connection.addListener(_sync);
    connection.profileDataChanges.addListener(_profileDataChanged);
    _sync();
  }

  final ConnectionController connection;
  final SetupGatewayFactory _gatewayFor;

  SetupController? _controller;
  StreamSubscription<SetupSnapshot>? _subscription;
  SetupSnapshot _snapshot = const SetupSnapshot(phase: SetupPhase.loading);
  Object? _key;
  bool _supported = false;
  bool _online = false;
  bool _disposed = false;
  int _generation = 0;
  Future<void> _lifecycle = Future.value();

  /// The latest redacted snapshot. `loading` until the first read answers.
  SetupSnapshot get snapshot => _snapshot;

  /// False when this server has no verified setup adapter: the page shows
  /// its unavailable state instead of reading anything.
  bool get supported => _supported;

  /// Whether the connection is live. Offline keeps [snapshot]'s data.
  bool get online => _online;

  /// Reads the server's setup again. No-op while a read is running.
  Future<void> refresh() async {
    final controller = _controller;
    if (controller == null || !_online) return;
    try {
      await controller.refresh();
    } on SetupFailure {
      // The controller publishes the failure as a phase with safe copy.
    }
    // The broadcast stream delivers a microtask later; publish the settled
    // snapshot now so a finished read never shows as still loading.
    if (!_disposed && identical(controller, _controller)) {
      _snapshot = controller.snapshot;
      notifyListeners();
    }
  }

  bool get _connected => connection.status == StreamStatus.connected;

  Object? _currentKey() {
    final profile = connection.profile;
    final api = connection.api;
    if (profile == null || api == null) return null;
    return (profile.id, connection.directory, connection.workspace, api);
  }

  bool _sameKey(Object? a, Object? b) {
    if (a is! (String, String?, String?, ServerGateway) ||
        b is! (String, String?, String?, ServerGateway)) {
      return a == null && b == null;
    }
    return a.$1 == b.$1 &&
        a.$2 == b.$2 &&
        a.$3 == b.$3 &&
        identical(a.$4, b.$4);
  }

  void _profileDataChanged() {
    if (_disposed) return;
    // A deletion or reset is about to touch this profile's local data:
    // release the owner now, then rebuild for whatever remains selected.
    _key = const Object();
    _sync();
  }

  void _sync() {
    if (_disposed) return;
    final key = _currentKey();
    if (!_sameKey(key, _key)) {
      _key = key;
      _rebuild(key);
      return;
    }
    final online = _connected;
    if (online == _online) return;
    _online = online;
    final controller = _controller;
    if (controller == null) return;
    controller.setOnline(online);
    if (online) unawaited(refresh());
    notifyListeners();
  }

  void _rebuild(Object? key) {
    final generation = ++_generation;
    final previous = _controller;
    final subscription = _subscription;
    _controller = null;
    _subscription = null;
    _online = _connected;
    final gateway = key is (String, String?, String?, ServerGateway)
        ? _gatewayFor(key.$4)
        : null;
    // No live transport yet: say offline when the server can share its
    // setup once connected, unavailable when it never can.
    final waiting = key == null && connection.capabilities.setupConfigRead;
    _supported = gateway != null || waiting;
    _snapshot = SetupSnapshot(
      phase: waiting
          ? SetupPhase.offline
          : gateway == null
          ? SetupPhase.unsupported
          : SetupPhase.loading,
    );
    notifyListeners();
    _lifecycle = _lifecycle.then((_) async {
      await subscription?.cancel();
      await previous?.dispose();
      if (_disposed || generation != _generation || gateway == null) return;
      if (key is! (String, String?, String?, ServerGateway)) return;
      final (profileId, directory, workspace, api) = key;
      final controller = SetupController(
        gateway: gateway,
        prefs: connection.store.prefs,
        profileId: profileId,
        locationId: '${directory ?? ''}\u0000${workspace ?? ''}',
        isCurrent: () =>
            !_disposed &&
            generation == _generation &&
            connection.profile?.id == profileId &&
            connection.directory == directory &&
            connection.workspace == workspace &&
            identical(connection.api, api),
      );
      _controller = controller;
      _subscription = controller.changes.listen((value) {
        if (_disposed || generation != _generation) return;
        _snapshot = value;
        notifyListeners();
      });
      if (!_online) {
        controller.setOnline(false);
        _snapshot = controller.snapshot;
        notifyListeners();
        return;
      }
      await refresh();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    connection.removeListener(_sync);
    connection.profileDataChanges.removeListener(_profileDataChanged);
    final controller = _controller;
    final subscription = _subscription;
    _controller = null;
    _subscription = null;
    _lifecycle = _lifecycle.then((_) async {
      await subscription?.cancel();
      await controller?.dispose();
    });
    super.dispose();
  }

  /// Completes once every earlier controller has been disposed and the
  /// current one has finished its first read (tests and deletion await it).
  @visibleForTesting
  Future<void> get settled => _lifecycle;
}
