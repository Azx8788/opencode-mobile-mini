import 'package:crypto/crypto.dart' show sha256;

import 'ed25519.dart';
import 'factsbook_types.dart';
import 'jcs.dart';

/// What checking the node's signed control chain found
/// (`GET /v1/control`, `api/fixtures/control.json`).
class ControlVerification {
  const ControlVerification({
    required this.fingerprintMatches,
    required this.pinMatches,
    required this.signaturesValid,
    required this.chainLinked,
    required this.forked,
  });

  /// The root public key hashes to the fingerprint the node reports.
  final bool fingerprintMatches;

  /// ... and to the fingerprint pinned when this phone was paired. A
  /// replacement fingerprint offered by the node itself is never accepted.
  final bool pinMatches;

  /// Every record is the root key's signature over its canonical bytes
  /// (without `sig`).
  final bool signaturesValid;

  /// Each record's `prev` is the hash of the one before it, in order.
  final bool chainLinked;

  /// Competing records at one position: authority is paused.
  final bool forked;

  bool get trusted =>
      fingerprintMatches &&
      pinMatches &&
      signaturesValid &&
      chainLinked &&
      !forked;
}

/// Verifies a control chain against the fingerprint pinned at pairing.
abstract final class ControlVerifier {
  static Future<ControlVerification> verify(
    ControlChain chain, {
    required String pinnedFingerprint,
  }) async {
    List<int> key;
    try {
      key = bytesOfHex(chain.rootPublicKey);
    } on FormatException {
      return const ControlVerification(
        fingerprintMatches: false,
        pinMatches: false,
        signaturesValid: false,
        chainLinked: false,
        forked: false,
      );
    }
    final fingerprint = sha256.convert(key).toString();
    var signatures = chain.records.isNotEmpty;
    var linked = chain.records.isNotEmpty;
    String? previousHash;
    for (var i = 0; i < chain.records.length; i++) {
      final record = chain.records[i];
      final unsigned = {...record.raw}..remove('sig');
      try {
        if (!await Ed25519.verify(
          key,
          Jcs.bytes(unsigned),
          bytesOfHex(record.sig),
        )) {
          signatures = false;
        }
      } on Object {
        signatures = false;
      }
      if (i == 0 ? record.prev != null : record.prev != previousHash) {
        linked = false;
      }
      previousHash = sha256.convert(Jcs.bytes(record.raw)).toString();
    }
    return ControlVerification(
      fingerprintMatches: fingerprint == chain.rootFingerprint,
      pinMatches: fingerprint == pinnedFingerprint,
      signaturesValid: signatures,
      chainLinked: linked,
      forked: chain.forked,
    );
  }
}
