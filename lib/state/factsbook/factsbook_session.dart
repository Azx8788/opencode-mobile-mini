import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../domain/factsbook/device_auth.dart';
import '../../domain/factsbook/factsbook_address.dart';
import '../../domain/factsbook/factsbook_capabilities.dart';
import '../../domain/factsbook/factsbook_gateway.dart';
import '../../domain/factsbook/factsbook_types.dart';
import '../../domain/factsbook/http_factsbook_gateway.dart';
import '../../domain/factsbook/owner_signer.dart';
import 'device_authenticator.dart';
import 'factsbook_outbox.dart';
import 'factsbook_store.dart';

/// Which node this server profile talks to, and how: the pairing, the real
/// gateway built from it, and the outbox. Unpaired, [gateway] is null and
/// the Memory section offers setup.
///
/// A pairing belongs to the connected server profile, so deleting that
/// profile deletes the token, the owner key and the outbox with it
/// ([FactsBookStore.secureKeys], `ProfileStore.remove`).
class FactsBookSession extends ChangeNotifier {
  FactsBookSession({
    required FactsBookStore store,
    required String profileId,
    Dio? dio,
    DeviceAuthenticator? authenticator,
  }) : _store = store,
       _profileId = profileId,
       _dio = dio,
       _authenticator = authenticator ?? LocalAuthDeviceAuthenticator(),
       outbox = FactsBookOutbox(_SecureOutbox(store, profileId));

  /// A session with no node and nothing to load (no connection yet).
  FactsBookSession.unpaired()
    : _store = null,
      _profileId = null,
      _dio = null,
      _authenticator = null,
      outbox = FactsBookOutbox(MemoryOutboxStore()),
      _loaded = true;

  /// A session that is already paired to [gateway] (tests, previews).
  FactsBookSession.fixed(
    FactsBookGateway this.gateway, {
    FactsBookOutboxStore? outboxStore,
    this.link,
    this.canApprove = true,
  }) : _store = null,
       _profileId = null,
       _dio = null,
       _authenticator = null,
       outbox = FactsBookOutbox(outboxStore ?? MemoryOutboxStore()),
       _loaded = true;

  final FactsBookStore? _store;
  final String? _profileId;
  final Dio? _dio;
  final DeviceAuthenticator? _authenticator;
  final FactsBookOutbox outbox;

  /// What the node's milestone supports; features outside it say "not
  /// available yet".
  FactsBookCapabilities capabilities = FactsBookCapabilities.b5;

  /// Asks the node for its own capability matrix and uses it from now on. A
  /// node that has none (older than B5) keeps the shipped one: its missing
  /// routes still answer "not found", which the pages read as unavailable.
  Future<void> refreshCapabilities() async {
    final node = gateway;
    if (node == null) return;
    try {
      capabilities = await node.capabilities();
      notifyListeners();
    } on FactsBookException {
      // Keep what is shipped.
    }
  }

  /// The words the device's authentication prompt shows before an approval
  /// is signed; the screens set it from their copy.
  String approvalReason = 'Approve this change';

  var _loaded = false;
  bool get loaded => _loaded;

  FactsBookLink? link;
  FactsBookGateway? gateway;

  /// Whether this phone can sign approvals (an owner device id is set).
  bool canApprove = false;

  bool get paired => gateway != null;

  Future<void>? _loading;

  /// Reads the pairing and builds the gateway. Safe to call again.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final store = _store;
    final profileId = _profileId;
    if (store != null && profileId != null) {
      try {
        await _build(store, profileId, store.link(profileId));
        await outbox.load();
        unawaited(refreshCapabilities());
      } on Object {
        // Unreadable secure storage reads as unpaired; setup can run again.
        link = null;
        gateway = null;
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _build(
    FactsBookStore store,
    String profileId,
    FactsBookLink? saved,
  ) async {
    link = saved;
    if (saved == null) {
      gateway = null;
      canApprove = false;
      return;
    }
    final token = await store.token(profileId);
    if (token == null) {
      gateway = null;
      canApprove = false;
      return;
    }
    OwnerSigner? signer;
    final deviceId = saved.ownerDeviceId;
    if (deviceId != null) {
      signer = OwnerSigner(
        seed: await store.ownerSeed(profileId),
        deviceId: deviceId,
        vault: saved.vault,
        clientId: saved.clientId,
        authenticator: _authenticator,
        reason: () => approvalReason,
      );
    }
    canApprove = signer != null;
    gateway = HttpFactsBookGateway(
      baseUrl: saved.baseUrl,
      token: token,
      owner: signer,
      dio: _dio,
    );
  }

  /// The public key this phone signs approvals with, for the node's console
  /// (`--owner-key`). Made on first use; the private key never leaves secure
  /// storage.
  Future<String> ownerPublicKeyHex() async {
    final store = _store;
    final profileId = _profileId;
    if (store == null || profileId == null) return '';
    final seed = await store.ownerSeed(profileId);
    return OwnerSigner(
      seed: seed,
      deviceId: 'dev_unset',
      vault: '',
      clientId: '',
    ).publicKeyHex();
  }

  /// One-time code to a token. [address] is what the person typed; only a
  /// private address is accepted. Throws [FactsBookException] with
  /// `address_not_allowed` for any other, or the node's own code.
  Future<void> pair({
    required String address,
    required String code,
    String? ownerDeviceId,
  }) async {
    final store = _store;
    final profileId = _profileId;
    if (store == null || profileId == null) {
      throw const FactsBookException('unauthorized');
    }
    final base = FactsBookAddress.parse(address);
    if (base == null) throw const FactsBookException('address_not_allowed');
    final owner = ownerDeviceId?.trim();
    final result = await FactsBookPairing.pair(
      base,
      code: code,
      clientName: 'OpenCode Plus',
      scopes: [
        'read',
        'write',
        if (owner != null && owner.isNotEmpty) ...['admin', 'owner'],
      ],
      dio: _dio,
    );
    await store.savePairing(
      profileId,
      FactsBookLink(
        baseUrl: base,
        clientId: result.clientId,
        vault: result.vault,
        rootFingerprint: result.rootFingerprint,
        node: result.node,
        scopes: result.scopes,
        ownerDeviceId: owner == null || owner.isEmpty ? null : owner,
      ),
      result.token,
    );
    await _build(store, profileId, store.link(profileId));
    notifyListeners();
    unawaited(refreshCapabilities());
  }

  /// Forgets the node on this phone: the token, the owner key and the
  /// pairing. The node's data and the outbox stay.
  Future<void> disconnect() async {
    final store = _store;
    final profileId = _profileId;
    if (store == null || profileId == null) return;
    await store.forget(profileId);
    link = null;
    gateway = null;
    canApprove = false;
    notifyListeners();
  }
}

class _SecureOutbox implements FactsBookOutboxStore {
  _SecureOutbox(this._store, this._profileId);

  final FactsBookStore _store;
  final String _profileId;

  @override
  Future<String?> read() => _store.readOutbox(_profileId);

  @override
  Future<void> write(String? value) => _store.writeOutbox(_profileId, value);
}
