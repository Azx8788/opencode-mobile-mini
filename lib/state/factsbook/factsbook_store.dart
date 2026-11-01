import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/factsbook/ed25519.dart';
import '../../domain/factsbook/owner_signer.dart';

/// What the app remembers about the FactsBook node a server profile is
/// paired with: not secret, so it lives in preferences under
/// `oc.factsbookNode.<profileId>` (the profile deletion sweep finds it by its
/// shape).
class FactsBookLink {
  const FactsBookLink({
    required this.baseUrl,
    required this.clientId,
    required this.vault,
    required this.rootFingerprint,
    required this.node,
    required this.scopes,
    this.ownerDeviceId,
  });

  final Uri baseUrl;
  final String clientId;
  final String vault;
  final String rootFingerprint;
  final String node;
  final List<String> scopes;

  /// The owner device id the node's console returned when it enrolled this
  /// phone's owner key; without it the phone cannot approve changes.
  final String? ownerDeviceId;

  FactsBookLink withOwnerDevice(String? id) => FactsBookLink(
    baseUrl: baseUrl,
    clientId: clientId,
    vault: vault,
    rootFingerprint: rootFingerprint,
    node: node,
    scopes: scopes,
    ownerDeviceId: id,
  );

  String encode() => jsonEncode({
    'url': baseUrl.toString(),
    'client': clientId,
    'vault': vault,
    'fingerprint': rootFingerprint,
    'node': node,
    'scopes': scopes,
    'owner_device': ?ownerDeviceId,
  });

  static FactsBookLink? decode(String? raw) {
    if (raw == null) return null;
    try {
      final json = (jsonDecode(raw) as Map).cast<String, Object?>();
      return FactsBookLink(
        baseUrl: Uri.parse(json['url']! as String),
        clientId: json['client']! as String,
        vault: json['vault']! as String,
        rootFingerprint: json['fingerprint']! as String,
        node: json['node']! as String,
        scopes: [for (final s in json['scopes'] as List) '$s'],
        ownerDeviceId: json['owner_device'] as String?,
      );
    } on Object {
      return null;
    }
  }
}

/// Where FactsBook keeps things on this phone, per server profile
/// (`oc.<what>.<profileId>`, so the profile deletion sweep finds them).
///
/// - the pairing record in preferences (`oc.factsbookNode.<id>`);
/// - the bearer token, the owner key's seed and the outbox of unsent
///   captures in secure storage (`oc.factsbook.<id>`,
///   `oc.factsbookOwner.<id>`, `oc.factsbookOutbox.<id>`): a note's text is
///   private, and the token and seed are credentials.
///
/// Nothing here is logged.
class FactsBookStore {
  FactsBookStore({required this.prefs, FlutterSecureStorage? secure})
    : secure = secure ?? const FlutterSecureStorage();

  final SharedPreferences prefs;
  final FlutterSecureStorage secure;

  static String linkKey(String profileId) => 'oc.factsbookNode.$profileId';
  static String tokenKey(String profileId) => 'oc.factsbook.$profileId';
  static String ownerKey(String profileId) => 'oc.factsbookOwner.$profileId';
  static String outboxKey(String profileId) => 'oc.factsbookOutbox.$profileId';

  /// The secure-storage keys of [profileId]: deleted with the profile.
  static List<String> secureKeys(String profileId) => [
    tokenKey(profileId),
    ownerKey(profileId),
    outboxKey(profileId),
  ];

  FactsBookLink? link(String profileId) =>
      FactsBookLink.decode(prefs.getString(linkKey(profileId)));

  Future<String?> token(String profileId) =>
      secure.read(key: tokenKey(profileId));

  /// Saves a pairing: the token first, so a record never exists without it.
  Future<void> savePairing(
    String profileId,
    FactsBookLink link,
    String token,
  ) async {
    await secure.write(key: tokenKey(profileId), value: token);
    if (!await prefs.setString(linkKey(profileId), link.encode())) {
      await secure.delete(key: tokenKey(profileId));
      throw StateError('Could not save the FactsBook pairing');
    }
  }

  Future<void> saveLink(String profileId, FactsBookLink link) async {
    if (!await prefs.setString(linkKey(profileId), link.encode())) {
      throw StateError('Could not save the FactsBook pairing');
    }
  }

  /// The owner key's seed, made on first use.
  Future<Uint8List> ownerSeed(String profileId) async {
    final saved = await secure.read(key: ownerKey(profileId));
    if (saved != null) {
      try {
        return bytesOfHex(saved);
      } on FormatException {
        // A damaged seed is replaced; the console enrols the new key.
      }
    }
    final seed = newOwnerSeed();
    await secure.write(key: ownerKey(profileId), value: hexOf(seed));
    return seed;
  }

  Future<bool> hasOwnerSeed(String profileId) async =>
      await secure.read(key: ownerKey(profileId)) != null;

  Future<String?> readOutbox(String profileId) =>
      secure.read(key: outboxKey(profileId));

  Future<void> writeOutbox(String profileId, String? value) => value == null
      ? secure.delete(key: outboxKey(profileId))
      : secure.write(key: outboxKey(profileId), value: value);

  /// Forgets the node: the pairing, the token and the owner key. The outbox
  /// stays: its notes are kept until the person discards them.
  Future<void> forget(String profileId) async {
    await secure.delete(key: tokenKey(profileId));
    await secure.delete(key: ownerKey(profileId));
    await prefs.remove(linkKey(profileId));
  }
}
