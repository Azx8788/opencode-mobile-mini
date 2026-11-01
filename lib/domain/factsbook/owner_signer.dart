import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';

import 'device_auth.dart';
import 'ed25519.dart';
import 'jcs.dart';

/// Signs owner-only changes (review decisions, policy, areas, settings) the
/// way the node verifies them (`api/README.md`): the Ed25519 signature of the
/// RFC 8785 canonical `{vault, client, method, path, body, nonce,
/// authenticated_at}`, with the body as sent but without `proof`, an
/// upper-case method, the path without its query, a fresh nonce, and an
/// authentication time no older than five minutes. A stolen bearer token
/// alone cannot produce this.
///
/// With an [authenticator] the device asks for the person's fingerprint, face
/// or PIN right before signing and `authenticated_at` is the time it
/// succeeded.
class OwnerSigner {
  OwnerSigner({
    required Uint8List seed,
    required this.deviceId,
    required this.vault,
    required this.clientId,
    this.authenticator,
    this.reason = _defaultReason,
    Random? random,
  }) : _seed = seed,
       _random = random ?? Random.secure();

  /// Asked right before signing. Without one the time of signing is used.
  final DeviceAuthenticator? authenticator;

  /// The prompt's words, read when it is shown.
  final String Function() reason;

  static String _defaultReason() => 'Approve this change';

  final Uint8List _seed;
  final Random _random;

  /// The owner device id the console returned when it enrolled the key.
  final String deviceId;
  final String vault;
  final String clientId;

  /// The public key as hex: what the console's `--owner-key` takes.
  Future<String> publicKeyHex() async => hexOf(await Ed25519.publicKey(_seed));

  /// The `proof` object for [body] sent with [method] to [path].
  Future<Map<String, Object?>> proof({
    required String method,
    required String path,
    required Map<String, Object?> body,
  }) async {
    final nonce = hexOf([for (var i = 0; i < 16; i++) _random.nextInt(256)]);
    final asked = authenticator;
    final now =
        (asked == null
                ? clock.now()
                : await asked.authenticate(reason: reason()))
            .toUtc();
    final at =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}T'
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}Z';
    final unsigned = {...body}..remove('proof');
    final envelope = <String, Object?>{
      'vault': vault,
      'client': clientId,
      'method': method.toUpperCase(),
      'path': path,
      'body': unsigned,
      'nonce': nonce,
      'authenticated_at': at,
    };
    final sig = hexOf(await Ed25519.sign(_seed, Jcs.bytes(envelope)));
    return {
      'signer': deviceId,
      'nonce': nonce,
      'authenticated_at': at,
      'sig': sig,
    };
  }
}

/// A fresh random 32-byte seed for a new owner key.
Uint8List newOwnerSeed([Random? random]) {
  final source = random ?? Random.secure();
  return Uint8List.fromList([for (var i = 0; i < 32; i++) source.nextInt(256)]);
}
