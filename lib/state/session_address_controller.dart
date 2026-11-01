import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/server_gateway.dart' show Session;
import '../domain/session_address_handoff.dart';
import '../domain/session_address_link.dart';
import '../platform/session_address_transport.dart';
import 'connection.dart' show connProvider;
import 'profiles.dart';
import 'session_link_bindings.dart';

export '../domain/session_address_handoff.dart';
export '../domain/session_address_link.dart';

enum SessionAddressPhase {
  idle,
  awaitingConsent,
  checkingServer,
  addServer,
  chooseProfile,
  bindingRequired,
  readyToOpen,
  openingSession,
  opened,
  failed,
}

/// One in-memory handoff. No default networking, credential lookup, retries or
/// persistence of the link. Production is closed until the host + UI gate passes.
class SessionAddressController extends ChangeNotifier {
  SessionAddressController({
    required this.store,
    required this.descriptors,
    required this.deploymentForOrigin,
    required this.lookupForProfile,
  }) : _enabled = false;

  @visibleForTesting
  SessionAddressController.verifiedTestHarness({
    required this.store,
    required this.descriptors,
    required this.deploymentForOrigin,
    required this.lookupForProfile,
  }) : _enabled = true;

  final ProfileStore store;
  final SessionAddressDescriptorReader descriptors;
  final SessionAddressDeployment Function(String origin) deploymentForOrigin;

  /// Called ONLY after contact consent, descriptor verification and a persisted
  /// matching binding. An implementation may now use existing credential paths.
  /// No current protocol provides this verified gateway; return null there.
  final Future<SessionAddressLookupGateway?> Function(String profileId)
  lookupForProfile;
  final bool _enabled;
  bool _disposed = false;
  int _generation = 0;
  SessionAddressPhase phase = SessionAddressPhase.idle;
  SessionAddressFailureCode? failure;
  SessionAddressLink? _pending;
  SessionAddressDescriptor? _descriptor;
  SessionLinkBindings? _bindingOwner;
  final _watchedOwners = <SessionLinkBindings>[];
  String? _profileId;
  Session? _session;
  List<String> _candidates = const [];

  SessionAddressLink? get pending => _pending;
  String? get profileId => _profileId;
  List<String> get candidateProfileIds => List.unmodifiable(_candidates);
  Session? get openedSession =>
      phase == SessionAddressPhase.opened ? _session : null;
  bool get available => _enabled;

  void _emit(SessionAddressPhase next, [SessionAddressFailureCode? code]) {
    if (_disposed) return;
    phase = next;
    failure = code;
    notifyListeners();
  }

  void _detach() {
    for (final owner in _watchedOwners) {
      owner.removeListener(_bindingChanged);
    }
    _watchedOwners.clear();
    _bindingOwner = null;
  }

  void _bindingChanged() {
    for (final owner in _watchedOwners) {
      if (owner.isAvailable) continue;
      try {
        owner.read();
      } on SessionAddressFailure catch (error) {
        if (error.code == SessionAddressFailureCode.profileMissing) {
          cancel();
        } else {
          ++_generation;
          _session = null;
          _emit(SessionAddressPhase.failed, error.code);
        }
        return;
      }
    }
  }

  void cancel() {
    ++_generation;
    _detach();
    _pending = null;
    _descriptor = null;
    _profileId = null;
    _session = null;
    _candidates = const [];
    _emit(SessionAddressPhase.idle);
  }

  /// Scanning/intent receipt is local and network-silent, including saved hosts.
  void receive(Object? input) {
    if (_disposed) return;
    SessionAddressLink link;
    try {
      link = SessionAddressLink.require(input);
    } on SessionAddressFailure catch (e) {
      cancel();
      _emit(SessionAddressPhase.failed, e.code);
      return;
    }
    if (_pending == link) return;
    cancel();
    _pending = link;
    if (_enabled) {
      try {
        for (final profile in store.profiles.where(
          (p) => _sameOrigin(p.baseUrl, link.origin),
        )) {
          final owner = SessionLinkBindings.forProfile(store.prefs, profile.id);
          _watchedOwners.add(owner);
          owner.addListener(_bindingChanged);
        }
      } catch (error) {
        _emit(SessionAddressPhase.failed, _code(error));
        return;
      }
    }
    _emit(
      _enabled
          ? SessionAddressPhase.awaitingConsent
          : SessionAddressPhase.failed,
      _enabled ? null : SessionAddressFailureCode.unavailable,
    );
  }

  /// Explicit Check again grants one new bounded discovery attempt. There are
  /// no timers/background retries; dismissal cannot be retried.
  Future<void> checkAgain() async {
    if (_disposed ||
        !_enabled ||
        _pending == null ||
        phase != SessionAddressPhase.failed) {
      return;
    }
    ++_generation;
    _detach();
    _descriptor = null;
    _profileId = null;
    _session = null;
    _emit(SessionAddressPhase.awaitingConsent);
    await approveContact();
  }

  bool _current(int generation) =>
      !_disposed && generation == _generation && _pending != null;

  SessionAddressFailureCode _code(Object error) =>
      error is SessionAddressFailure
      ? error.code
      : SessionAddressFailureCode.unreachable;

  void _verifiedDeployment(String origin) {
    if (!_enabled) {
      throw const SessionAddressFailure(SessionAddressFailureCode.unavailable);
    }
    if (!deploymentForOrigin(origin).verified) {
      throw const SessionAddressFailure(SessionAddressFailureCode.unsafeLookup);
    }
  }

  /// A tap grants ONLY bounded, anonymous discovery. It never connects a saved
  /// profile or builds an authenticated client, even if the origin matches.
  Future<void> approveContact() async {
    if (_disposed || phase != SessionAddressPhase.awaitingConsent) return;
    final link = _pending!;
    final generation = _generation;
    _emit(SessionAddressPhase.checkingServer);
    try {
      _verifiedDeployment(link.origin);
      final descriptor = await descriptors.discover(link.origin);
      if (!_current(generation)) return;
      if (descriptor.origin != link.origin ||
          descriptor.instanceId != link.instanceId) {
        throw const SessionAddressFailure(
          SessionAddressFailureCode.instanceMismatch,
        );
      }
      _descriptor = descriptor;
      _candidates = [
        for (final profile in store.profiles)
          if (_sameOrigin(profile.baseUrl, link.origin)) profile.id,
      ];
      if (_candidates.isEmpty) {
        _emit(SessionAddressPhase.addServer);
      } else if (_candidates.length > 1) {
        _emit(SessionAddressPhase.chooseProfile);
      } else {
        selectProfile(_candidates.single);
      }
    } catch (error) {
      if (_current(generation)) _emit(SessionAddressPhase.failed, _code(error));
    }
  }

  bool _sameOrigin(String raw, String origin) {
    try {
      return SessionAddressLink.normalizeOrigin(raw) == origin;
    } catch (_) {
      return false;
    }
  }

  /// After Add server saves through the existing credential flow, explicitly
  /// select that profile. Never match by name, sender ID, flavor or session ID.
  void selectProfile(String id) {
    if (_disposed ||
        _descriptor == null ||
        _pending == null ||
        !_enabled ||
        !{
          SessionAddressPhase.checkingServer,
          SessionAddressPhase.chooseProfile,
          SessionAddressPhase.addServer,
          SessionAddressPhase.bindingRequired,
          SessionAddressPhase.readyToOpen,
        }.contains(phase)) {
      return;
    }
    try {
      _checkProfile(id);
      _detach();
      final owner = SessionLinkBindings.forProfile(store.prefs, id);
      final binding = owner.read();
      if (!owner.isAvailable) {
        throw const SessionAddressFailure(
          SessionAddressFailureCode.profileMissing,
        );
      }
      if (binding != null &&
          (binding.origin != _pending!.origin ||
              binding.instanceId != _pending!.instanceId)) {
        throw const SessionAddressFailure(
          SessionAddressFailureCode.instanceMismatch,
        );
      }
      _profileId = id;
      _bindingOwner = owner;
      _watchedOwners.add(owner);
      owner.addListener(_bindingChanged);
      _emit(
        binding == null
            ? SessionAddressPhase.bindingRequired
            : SessionAddressPhase.readyToOpen,
      );
    } catch (error) {
      _emit(SessionAddressPhase.failed, _code(error));
    }
  }

  void _checkProfile(String id) {
    if (_bindingOwner != null && !_bindingOwner!.isAvailable) {
      throw const SessionAddressFailure(
        SessionAddressFailureCode.profileMissing,
      );
    }
    final matches = store.profiles.where((p) => p.id == id);
    if (matches.length != 1) {
      throw const SessionAddressFailure(
        SessionAddressFailureCode.profileMissing,
      );
    }
    if (!_sameOrigin(matches.single.baseUrl, _pending!.origin)) {
      throw const SessionAddressFailure(
        SessionAddressFailureCode.instanceMismatch,
      );
    }
  }

  /// Explicit verification approval for a previously unbound saved profile.
  /// This is not automatic sign-in, pairing or credential reuse.
  Future<void> approveBinding() async {
    if (phase != SessionAddressPhase.bindingRequired || _bindingOwner == null) {
      return;
    }
    final generation = _generation;
    try {
      _checkProfile(_profileId!);
      await _bindingOwner!.save(
        SessionLinkBinding(
          origin: _descriptor!.origin,
          instanceId: _descriptor!.instanceId,
          verifiedAt: DateTime.now().toUtc(),
        ),
      );
      if (_current(generation)) _emit(SessionAddressPhase.readyToOpen);
    } catch (error) {
      if (_current(generation)) _emit(SessionAddressPhase.failed, _code(error));
    }
  }

  /// Explicit Open after own sign-in. Rechecks descriptor immediately before
  /// creating the scoped gateway; no generic session(id), create, resume or scan.
  Future<void> open() async {
    if (_disposed || phase != SessionAddressPhase.readyToOpen) return;
    final generation = _generation;
    final link = _pending!;
    final id = _profileId!;
    _emit(SessionAddressPhase.openingSession);
    try {
      _verifiedDeployment(link.origin);
      _checkProfile(id);
      final currentDescriptor = await descriptors.discover(link.origin);
      if (!_current(generation)) return;
      if (currentDescriptor.origin != link.origin ||
          currentDescriptor.instanceId != link.instanceId) {
        throw const SessionAddressFailure(
          SessionAddressFailureCode.instanceMismatch,
        );
      }
      _checkProfile(id);
      final binding = _bindingOwner!.read();
      if (binding?.origin != link.origin ||
          binding?.instanceId != link.instanceId) {
        throw const SessionAddressFailure(
          SessionAddressFailureCode.bindingRequired,
        );
      }
      final gateway = await lookupForProfile(id);
      if (!_current(generation)) return;
      _checkProfile(id);
      if (gateway == null) {
        throw const SessionAddressFailure(
          SessionAddressFailureCode.unavailable,
        );
      }
      if (!gateway.deployment.verified) {
        throw const SessionAddressFailure(
          SessionAddressFailureCode.unsafeLookup,
        );
      }
      if (gateway.origin != link.origin ||
          gateway.instanceId != link.instanceId) {
        throw const SessionAddressFailure(
          SessionAddressFailureCode.instanceMismatch,
        );
      }
      final session = await gateway.lookupAuthorizedSession(link.sessionId);
      if (!_current(generation)) return;
      _checkProfile(id);
      if (session.id != link.sessionId) {
        throw const SessionAddressFailure(
          SessionAddressFailureCode.sessionMissing,
        );
      }
      _session = session;
      _emit(SessionAddressPhase.opened);
    } catch (error) {
      if (_current(generation)) _emit(SessionAddressPhase.failed, _code(error));
    }
  }

  /// App-facing sender builder. No link leaves this owner without disclosure,
  /// verified deployment and an exact current saved origin/instance binding.
  String buildForProfile(
    String id,
    String sessionId, {
    required bool includeServerAddress,
  }) {
    if (!_enabled || _disposed) {
      throw const SessionAddressFailure(SessionAddressFailureCode.unavailable);
    }
    if (!includeServerAddress) {
      throw const SessionAddressFailure(
        SessionAddressFailureCode.consentRequired,
      );
    }
    final profiles = store.profiles.where((p) => p.id == id);
    if (profiles.length != 1) {
      throw const SessionAddressFailure(
        SessionAddressFailureCode.profileMissing,
      );
    }
    final origin = SessionAddressLink.normalizeOrigin(profiles.single.baseUrl);
    _verifiedDeployment(origin);
    final binding = SessionLinkBindings.forProfile(store.prefs, id).read();
    if (binding == null) {
      throw const SessionAddressFailure(
        SessionAddressFailureCode.bindingRequired,
      );
    }
    if (binding.origin != origin) {
      throw const SessionAddressFailure(
        SessionAddressFailureCode.instanceMismatch,
      );
    }
    return SessionAddressLink.build(
      origin: origin,
      instanceId: binding.instanceId,
      sessionId: sessionId,
      includeServerAddress: true,
    ).encode();
  }

  @override
  void dispose() {
    cancel();
    _disposed = true;
    super.dispose();
  }
}

/// The app's one address-link coordinator, shared by the Open on another
/// phone sheet (sender) and the incoming-link sheet (receiver). Built with the
/// closed production constructor: generation and reception stay unavailable
/// until the host deployment is verified (docs/qa/codex-sessionlink-2026-09-28).
/// Tests override it with [SessionAddressController.verifiedTestHarness].
final sessionAddressProvider = Provider<SessionAddressController>((ref) {
  final controller = SessionAddressController(
    store: ref.watch(connProvider).store,
    descriptors: PrivateSessionDescriptorReader(),
    // Default-closed evidence: nothing here is verified yet.
    deploymentForOrigin: (_) => const SessionAddressDeployment(),
    lookupForProfile: (_) async => null,
  );
  ref.onDispose(controller.dispose);
  return controller;
});
