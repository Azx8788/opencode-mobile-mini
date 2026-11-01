import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../builtin/factsbook_node_host.dart';
import '../../domain/factsbook/factsbook_types.dart';
import '../../domain/factsbook/http_factsbook_gateway.dart';
import '../connection.dart' show connProvider;
import 'factsbook_controller.dart' show factsBookSessionProvider;
import 'factsbook_session.dart';
import 'phone_zone.dart';

/// Where the FactsBook node on this phone is, in the words a person uses.
enum PhoneNodeState {
  /// Not asked yet.
  checking,

  /// This runner has no built-in Linux (not an Android phone).
  unsupported,

  /// The built-in Linux is not set up yet.
  linuxNotSetUp,

  /// The built-in Linux is ready but there is no node build to install.
  noBuild,

  /// Ready to be installed here.
  notInstalled,

  /// Installing, preparing, starting and pairing: one run, see [PhoneNodeStep].
  installing,
  starting,
  running,
  stopping,
  stopped,
  removing,

  /// A step failed; [FactsBookPhoneNode.failure] and [problem] say which.
  failed,
}

/// The step an install or a start is on, for the progress line.
enum PhoneNodeStep { copying, preparing, starting, pairing }

/// What [FactsBookPhoneNode.failure] was about.
enum PhoneNodeProblem { install, start, pair, stop, remove }

/// FactsBook running on this phone, inside the built-in Linux: install the
/// node, start it on the loopback address, pair this app with it by itself,
/// stop it, and remove it with its data. One run does it all; each step can
/// be asked again, and a vault that exists is never made twice.
///
/// Technical text (the node's exit, a checksum) is kept in [failure] for
/// Details only. The passphrase and the pairing code are never kept, shown
/// or logged.
class FactsBookPhoneNode extends ChangeNotifier {
  FactsBookPhoneNode(
    this.session, {
    required this.host,
    Future<bool> Function(Uri address)? probe,
    Future<void> Function({
      required String address,
      required String code,
      String? ownerDeviceId,
    })?
    pairWith,
    this.probeAttempts = 30,
    this.probeDelay = const Duration(seconds: 1),
    this.linuxWaitAttempts = 30,
    this.linuxWaitDelay = const Duration(seconds: 3),
    this.prefs,
  }) : _probe = probe ?? _defaultProbe,
       _pairWith = pairWith ?? session.pair;

  final FactsBookSession session;
  final FactsBookNodeHost host;
  final Future<bool> Function(Uri address) _probe;
  final Future<void> Function({
    required String address,
    required String code,
    String? ownerDeviceId,
  })
  _pairWith;
  final int probeAttempts;
  final Duration probeDelay;

  /// How long [ensureRunning] waits for the built-in Linux, which is still
  /// starting when the app opens (always right after an update).
  final int linuxWaitAttempts;
  final Duration linuxWaitDelay;

  /// Where "the person stopped it" is kept (app-wide, like the developer
  /// flag, so a profile sweep does not touch it).
  final SharedPreferences? prefs;

  static const personStoppedKey = 'oc.factsbook-node.stopped';

  /// The person pressed Stop and has not started it since: the app does not
  /// start it by itself then.
  bool get personStopped => prefs?.getBool(personStoppedKey) ?? false;

  Future<void> _rememberStop(bool stopped) async {
    final store = prefs;
    if (store == null) return;
    if (stopped) {
      await store.setBool(personStoppedKey, true);
    } else {
      await store.remove(personStoppedKey);
    }
  }

  PhoneNodeState state = PhoneNodeState.checking;
  PhoneNodeStep step = PhoneNodeStep.copying;
  PhoneNodeProblem? problem;
  String? failure;
  NodeHostFacts facts = const NodeHostFacts();

  var _busy = false;

  /// [ensureRunning] is under way, including its waits for the built-in
  /// Linux: the memory is coming up, not failed.
  var _ensuring = false;
  var _disposed = false;

  bool get busy => _busy || _ensuring;

  static Future<bool> _defaultProbe(Uri address) async {
    try {
      await FactsBookPairing.info(address);
      return true;
    } on FactsBookException {
      return false;
    }
  }

  Uri get _baseUrl => Uri.parse('http://${host.address}');

  /// This app is paired with the node on this phone.
  bool get pairedHere =>
      session.paired &&
      session.link?.baseUrl.host == _baseUrl.host &&
      session.link?.baseUrl.port == _baseUrl.port;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _set(PhoneNodeState next, {PhoneNodeStep? on}) {
    state = next;
    if (on != null) step = on;
    if (next != PhoneNodeState.failed) {
      problem = null;
      failure = null;
    }
    if (!_disposed) notifyListeners();
  }

  void _fail(PhoneNodeProblem why, Object error) {
    problem = why;
    failure = error is NodeHostException
        ? (error.detail ?? error.failure.name)
        : error.runtimeType.toString();
    state = PhoneNodeState.failed;
    if (!_disposed) notifyListeners();
  }

  /// Reads how things are now.
  Future<void> refresh() async {
    if (_busy) return;
    if (!host.supported) {
      _set(PhoneNodeState.unsupported);
      return;
    }
    try {
      facts = await host.inspect();
    } on Object catch (error) {
      _fail(PhoneNodeProblem.start, error);
      return;
    }
    if (!facts.linuxReady) {
      _set(PhoneNodeState.linuxNotSetUp);
    } else if (facts.serviceRunning) {
      _set(PhoneNodeState.running);
    } else if (facts.dataExists) {
      _set(PhoneNodeState.stopped);
    } else if (facts.binaryAvailable) {
      _set(PhoneNodeState.notInstalled);
    } else {
      _set(PhoneNodeState.noBuild);
    }
  }

  /// "Run memory on this phone": install the node, make its vault, start it
  /// and pair this app with it. Safe to run again after a failure or after a
  /// stop: finished steps are skipped.
  Future<void> runHere() async {
    if (_busy) return;
    _busy = true;
    try {
      await _rememberStop(false);
      _set(PhoneNodeState.installing, on: PhoneNodeStep.copying);
      facts = await host.inspect();
      if (!facts.linuxReady) {
        _set(PhoneNodeState.linuxNotSetUp);
        return;
      }
      if (!facts.binaryInstalled) {
        try {
          await host.installBinary();
        } on NodeHostException catch (error) {
          if (error.failure == NodeHostFailure.noBinary) {
            _set(PhoneNodeState.noBuild);
          } else {
            _fail(PhoneNodeProblem.install, error);
          }
          return;
        }
      }
      _set(PhoneNodeState.installing, on: PhoneNodeStep.preparing);
      try {
        await host.createVault();
      } on Object catch (error) {
        _fail(PhoneNodeProblem.install, error);
        return;
      }
      if (!await _start()) return;
      await _pair();
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Starts the node and waits until it answers. False after a failure.
  Future<bool> _start() async {
    _set(PhoneNodeState.installing, on: PhoneNodeStep.starting);
    try {
      if (!(await host.inspect()).serviceRunning) await host.startNode();
      for (var i = 0; i < probeAttempts; i++) {
        if (await _probe(_baseUrl)) return true;
        await Future<void>.delayed(probeDelay);
      }
    } on Object catch (error) {
      _fail(PhoneNodeProblem.start, error);
      return false;
    }
    String? log;
    try {
      log = await host.log();
    } on Object {
      // The log is a help, not a need.
    }
    _fail(
      PhoneNodeProblem.start,
      NodeHostException(
        NodeHostFailure.start,
        (log == null || log.trim().isEmpty)
            ? 'The node did not answer in time.'
            : log,
      ),
    );
    return false;
  }

  Future<void> _pair() async {
    if (pairedHere) {
      _set(PhoneNodeState.running);
      return;
    }
    _set(PhoneNodeState.installing, on: PhoneNodeStep.pairing);
    try {
      final key = await session.ownerPublicKeyHex();
      final pairing = await host.pairingCode(ownerKeyHex: key);
      await _pairWith(
        address: host.address,
        code: pairing.code,
        ownerDeviceId: pairing.ownerDevice,
      );
    } on Object catch (error) {
      _fail(
        PhoneNodeProblem.pair,
        error is NodeHostException
            ? error
            : NodeHostException(
                NodeHostFailure.pair,
                error is FactsBookException
                    ? 'The node refused the pairing (${error.code}).'
                    : 'Pairing did not finish.',
              ),
      );
      return;
    }
    _set(PhoneNodeState.running);
    unawaited(_adoptPhoneZone());
  }

  /// A new node keeps reminders in UTC. Right after pairing, while the person
  /// is here to approve, its home time zone becomes this phone's. Quiet: if it
  /// does not happen, Memory settings still offers it.
  Future<void> _adoptPhoneZone() async {
    try {
      final gateway = session.gateway;
      final zone = await phoneTimeZone();
      if (gateway == null || zone == null || !session.canApprove) return;
      final settings = await gateway.settings();
      if (settings.vaultZone == zone || settings.revision != 1) return;
      await gateway.setHomeZone(settings, zone);
    } on Object {
      // Declined or failed: Memory settings offers the phone's zone.
    }
  }

  /// When the app opens: a node that is set up on this phone, paired with
  /// this app and stopped is started, unless the person stopped it. Same rule
  /// as the app's own in-app server. Quiet: a failure shows on the Memory
  /// row, not as a popup.
  ///
  /// The built-in Linux is often still starting at that moment (always just
  /// after an update), so a paired node waits for it instead of giving up
  /// on the one look.
  Future<void> ensureRunning() async {
    if (_busy || _ensuring || !host.supported) return;
    _ensuring = true;
    if (!_disposed) notifyListeners();
    try {
      await _ensureRunning();
    } finally {
      _ensuring = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _ensureRunning() async {
    await refresh();
    for (
      var i = 0;
      i < linuxWaitAttempts &&
          pairedHere &&
          !personStopped &&
          // Still starting: either not ready yet, or ready enough to answer
          // "status" but not yet to run a command (the look itself failed).
          (state == PhoneNodeState.linuxNotSetUp ||
              state == PhoneNodeState.failed);
      i++
    ) {
      await Future<void>.delayed(linuxWaitDelay);
      if (_disposed) return;
      await refresh();
    }
    if (state != PhoneNodeState.stopped) return;
    if (!pairedHere || personStopped) return;
    await start();
    // The start can still trip over a Linux that is busy finishing its own
    // start (seen right after an update): a few more tries, then the row's
    // Try again.
    for (
      var i = 0;
      i < startRetries && state == PhoneNodeState.failed && !personStopped;
      i++
    ) {
      await Future<void>.delayed(linuxWaitDelay);
      if (_disposed) return;
      await refresh();
      if (state == PhoneNodeState.stopped || state == PhoneNodeState.failed) {
        await start();
      }
    }
  }

  /// Further whole start attempts [ensureRunning] makes after a failure.
  static const startRetries = 3;

  /// Starts a stopped node and pairs again if the pairing was lost.
  Future<void> start() async {
    if (_busy) return;
    _busy = true;
    try {
      await _rememberStop(false);
      if (!await _start()) return;
      await _pair();
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> stop() async {
    if (_busy) return;
    _busy = true;
    try {
      _set(PhoneNodeState.stopping);
      await _rememberStop(true);
      await host.stopNode();
      _set(PhoneNodeState.stopped);
    } on Object catch (error) {
      _fail(PhoneNodeProblem.stop, error);
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> restart() async {
    if (_busy) return;
    _busy = true;
    try {
      await _rememberStop(false);
      _set(PhoneNodeState.stopping);
      await host.stopNode();
      if (!await _start()) return;
      await _pair();
    } on Object catch (error) {
      _fail(PhoneNodeProblem.stop, error);
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// "Remove memory from this phone": stops the node, deletes its data, and
  /// forgets the pairing on this phone. The caller has already asked.
  Future<void> remove() async {
    if (_busy) return;
    _busy = true;
    try {
      _set(PhoneNodeState.removing);
      await host.removeData();
      if (pairedHere) await session.disconnect();
      await refresh0();
    } on Object catch (error) {
      _fail(PhoneNodeProblem.remove, error);
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// [refresh] without the busy guard, for after our own work.
  Future<void> refresh0() async {
    facts = await host.inspect();
    if (!facts.linuxReady) {
      _set(PhoneNodeState.linuxNotSetUp);
    } else if (facts.dataExists) {
      _set(PhoneNodeState.stopped);
    } else if (facts.binaryAvailable) {
      _set(PhoneNodeState.notInstalled);
    } else {
      _set(PhoneNodeState.noBuild);
    }
  }

  Future<String> log() => host.log();
}

/// The node on this phone for the current pairing; null host on a runner
/// without the built-in Linux still gives a controller that says
/// "unsupported".
final factsBookPhoneNodeHostProvider = Provider<FactsBookNodeHost>(
  (ref) => BuiltinLinuxNodeHost(),
);

final factsBookPhoneNodeProvider = Provider<FactsBookPhoneNode>((ref) {
  final node = FactsBookPhoneNode(
    ref.watch(factsBookSessionProvider),
    host: ref.watch(factsBookPhoneNodeHostProvider),
    prefs: _prefsOrNull(ref),
  );
  ref.onDispose(node.dispose);
  return node;
});

SharedPreferences? _prefsOrNull(Ref ref) {
  try {
    return ref.watch(connProvider).store.prefs;
  } on Exception {
    return null;
  } on UnimplementedError {
    return null;
  }
}
