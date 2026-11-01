import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as pkg;

/// Ed25519 for the owner key a FactsBook client signs review, policy and
/// settings changes with, by the vetted `cryptography` package (Apache-2.0,
/// pure Dart): no cryptography is written here. The private key is a 32-byte
/// seed that lives only in Keystore-backed secure storage and is never
/// logged; only the 32-byte public key is shown, for the console to enrol.
/// The RFC 8032 vectors run against the package in
/// `test/factsbook/ed25519_test.dart`.
abstract final class Ed25519 {
  static final _algorithm = pkg.Ed25519();

  static void _check(Uint8List seed) {
    if (seed.length != 32) throw ArgumentError('An Ed25519 seed is 32 bytes');
  }

  /// The 32-byte public key of [seed].
  static Future<Uint8List> publicKey(Uint8List seed) async {
    _check(seed);
    final pair = await _algorithm.newKeyPairFromSeed(seed);
    return Uint8List.fromList((await pair.extractPublicKey()).bytes);
  }

  /// Whether [signature] is [publicKey]'s signature of [message].
  static Future<bool> verify(
    List<int> publicKey,
    List<int> message,
    List<int> signature,
  ) => _algorithm.verify(
    message,
    signature: pkg.Signature(
      signature,
      publicKey: pkg.SimplePublicKey(publicKey, type: pkg.KeyPairType.ed25519),
    ),
  );

  /// The 64-byte signature of [message] by [seed].
  static Future<Uint8List> sign(Uint8List seed, List<int> message) async {
    _check(seed);
    final pair = await _algorithm.newKeyPairFromSeed(seed);
    final signature = await _algorithm.sign(message, keyPair: pair);
    return Uint8List.fromList(signature.bytes);
  }
}

/// Lower-case hex of [bytes].
String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// The bytes of a hex string; throws [FormatException] on bad input.
Uint8List bytesOfHex(String hex) {
  if (hex.length.isOdd) throw const FormatException('odd hex length');
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}
