/// Per-server transport consent and certificate identity, without Flutter.
library;

import 'dart:io';

import 'package:crypto/crypto.dart';

import 'loopback_host.dart';

/// Canonical origin only: trust never follows a path, redirect, or port change.
String serverOrigin(String baseUrl) {
  final uri = Uri.tryParse(baseUrl.trim());
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException('Enter an HTTP or HTTPS server address.');
  }
  final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
  return '${uri.scheme}://$host:${uri.port}';
}

bool isCleartextChoiceRequired(String baseUrl) {
  serverOrigin(baseUrl);
  final uri = Uri.parse(baseUrl.trim());
  return uri.scheme == 'http' && !isLoopbackHost(uri.host);
}

/// Error tags that keep a refused connection's reason after the transport
/// turns it into a generic request error, so callers can say what happened.
const serverCertificateChangedTag = 'ClientCertificateChanged';
const serverCertificateInvalidTag = 'ClientCertificateInvalid';
const serverCleartextConsentTag = 'ClientCleartextNotAllowed';
const serverOriginChangedTag = 'ClientOriginChanged';

/// The tag for a trust refusal, or null when [error] is not one.
String? serverTrustErrorTag(Object? error) => switch (error) {
  ServerCertificateChangedException() => serverCertificateChangedTag,
  ServerCertificateValidityException() => serverCertificateInvalidTag,
  ServerCleartextConsentException() => serverCleartextConsentTag,
  ServerOriginChangedException() => serverOriginChangedTag,
  _ => null,
};

class ServerCleartextConsentException implements Exception {
  const ServerCleartextConsentException();
  @override
  String toString() => 'Confirm unencrypted HTTP for this server first.';
}

class ServerCertificateChangedException implements Exception {
  const ServerCertificateChangedException();
  @override
  String toString() =>
      'The server certificate changed. Check it before reconnecting.';
}

class ServerCertificateValidityException implements Exception {
  const ServerCertificateValidityException();
  @override
  String toString() => 'The server certificate is expired or not yet valid.';
}

class ServerOriginChangedException implements Exception {
  const ServerOriginChangedException();
  @override
  String toString() => 'The request does not match the trusted server address.';
}

String normalizeCertificateFingerprint(String fingerprint) {
  final normalized = fingerprint.replaceAll(':', '').toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(normalized)) {
    throw const FormatException('Invalid SHA-256 certificate fingerprint.');
  }
  return normalized;
}

String certificateFingerprintSha256(X509Certificate certificate) =>
    sha256.convert(certificate.der).toString();

void validateServerTrust({
  required String baseUrl,
  String? cleartextConfirmedOrigin,
  String? certificatePinSha256,
}) {
  final origin = serverOrigin(baseUrl);
  if (isCleartextChoiceRequired(baseUrl) &&
      cleartextConfirmedOrigin != origin) {
    throw const ServerCleartextConsentException();
  }
  if (certificatePinSha256 != null) {
    if (Uri.parse(baseUrl.trim()).scheme != 'https') {
      throw const FormatException('A certificate pin requires HTTPS.');
    }
    normalizeCertificateFingerprint(certificatePinSha256);
  }
}

class ServerCertificateInfo {
  final String fingerprintSha256;
  final String subject;
  final String issuer;
  final DateTime startValidity;
  final DateTime endValidity;

  const ServerCertificateInfo({
    required this.fingerprintSha256,
    required this.subject,
    required this.issuer,
    required this.startValidity,
    required this.endValidity,
  });

  ServerCertificateInfo.fromCertificate(X509Certificate certificate)
    : fingerprintSha256 = certificateFingerprintSha256(certificate),
      subject = certificate.subject,
      issuer = certificate.issuer,
      startValidity = certificate.startValidity,
      endValidity = certificate.endValidity;

  String get displayFingerprint => RegExp(r'.{2}')
      .allMatches(fingerprintSha256.toUpperCase())
      .map((match) => match.group(0))
      .join(':');
}

/// Performs only a TLS handshake. No HTTP bytes, headers or credentials are
/// sent. The returned identity is untrusted until the user verifies it.
Future<ServerCertificateInfo> inspectServerCertificate(String baseUrl) async {
  serverOrigin(baseUrl);
  final uri = Uri.parse(baseUrl.trim());
  if (uri.scheme != 'https') {
    throw const FormatException('Certificate inspection requires HTTPS.');
  }
  final socket = await SecureSocket.connect(
    uri.host,
    uri.port,
    context: SecurityContext(withTrustedRoots: false),
    onBadCertificate: (_) => true,
    timeout: const Duration(seconds: 8),
  );
  try {
    final certificate = socket.peerCertificate;
    if (certificate == null) {
      throw const HandshakeException('The server provided no certificate.');
    }
    return ServerCertificateInfo.fromCertificate(certificate);
  } finally {
    socket.destroy();
  }
}

/// Builds a client whose trust belongs only to this server origin. Callers
/// must disable redirects on requests (the OC2 transport does this globally).
///
/// With a pin, an empty root store makes EVERY certificate untrusted by PKI,
/// including a replacement signed by a public CA. The handshake callback
/// therefore verifies the exact leaf DER fingerprint before any HTTP header
/// can leave. Dio's validateCertificate is deliberately not used: it runs
/// after the response and would be too late to protect credentials.
///
/// A pin is an explicit identity override for PKI chain and hostname because
/// private self-signed servers often lack public DNS names. Certificate validity
/// dates are still enforced. The exact
/// host and port are still bound here; renewing even the same key requires the
/// user to verify a new fingerprint. Unpinned clients retain normal PKI rules.
HttpClient createServerHttpClient({
  required String baseUrl,
  String? cleartextConfirmedOrigin,
  String? certificatePinSha256,
  void Function()? onCertificateChanged,
  void Function()? onCertificateInvalid,
}) {
  validateServerTrust(
    baseUrl: baseUrl,
    cleartextConfirmedOrigin: cleartextConfirmedOrigin,
    certificatePinSha256: certificatePinSha256,
  );
  final origin = serverOrigin(baseUrl);
  final uri = Uri.parse(baseUrl.trim());
  final pin = certificatePinSha256 == null
      ? null
      : normalizeCertificateFingerprint(certificatePinSha256);
  final context = pin == null ? null : SecurityContext(withTrustedRoots: false);
  bool verifyPinnedCertificate(X509Certificate certificate) {
    if (certificateFingerprintSha256(certificate) != pin) {
      onCertificateChanged?.call();
      return false;
    }
    final now = DateTime.now();
    if (now.isBefore(certificate.startValidity) ||
        now.isAfter(certificate.endValidity)) {
      onCertificateInvalid?.call();
      return false;
    }
    return true;
  }

  final client = HttpClient(context: context);
  client.connectionTimeout = const Duration(seconds: 8);
  client.idleTimeout = const Duration(seconds: 15);
  // No ambient proxy can change the endpoint on which this consent relies.
  client.findProxy = (_) => 'DIRECT';
  client.connectionFactory = (target, proxyHost, proxyPort) {
    if (serverOrigin(target.origin) != origin ||
        target.host != uri.host ||
        target.port != uri.port ||
        proxyHost != null ||
        proxyPort != null) {
      throw const ServerOriginChangedException();
    }
    // A custom connectionFactory owns TLS too: HttpClient does not wrap a
    // returned plain Socket or call its badCertificateCallback afterwards.
    // Never return a raw socket for HTTPS, even for unpinned PKI connections.
    if (target.scheme == 'https') {
      return SecureSocket.startConnect(
        target.host,
        target.port,
        context: context,
        onBadCertificate: pin == null ? null : verifyPinnedCertificate,
      );
    }
    return Socket.startConnect(target.host, target.port);
  };
  return client;
}
