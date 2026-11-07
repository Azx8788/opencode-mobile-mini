/// Certificate identity for provider endpoints.
///
/// A provider is not the app's own server: it is reached directly from the
/// phone, and many gateways sit behind a certificate the phone cannot chain
/// to a root it knows — a self-signed certificate, an incomplete chain, or a
/// proxy that signs traffic with a private CA. Browsers often paper over the
/// first two; `dart:io` does not, so the model list stops at "the certificate
/// could not be verified" with nothing a person can do about it.
///
/// The answer here is the same one the app already uses for its own server:
/// show the certificate, let the person compare its SHA-256 fingerprint, and
/// remember *that exact certificate* for *that exact origin*. Nothing is
/// disabled globally, and a different certificate is refused even if a public
/// CA signed it.
///
/// [createProviderHttpClient] keeps the normal root store: a certificate that
/// validates is accepted without any stored trust, and one that does not is
/// accepted only when its DER fingerprint equals the stored value. Trust is
/// therefore an exception for one broken certificate, not a pin on the host.
library;

import 'dart:io';

import 'server_trust.dart'
    show
        ServerCertificateInfo,
        certificateFingerprintSha256,
        normalizeCertificateFingerprint;

/// Why a certificate was refused, in the terms the form can explain.
enum ProviderTlsProblem {
  /// The endpoint signed its own certificate.
  selfSigned,

  /// A chain that does not reach a root this device knows: a missing
  /// intermediate, a private CA, or a proxy's certificate.
  unknownIssuer,

  /// Outside its validity window: usually a wrong device clock, otherwise an
  /// expired certificate.
  expired,
  notYetValid,

  /// The certificate names a different host than the address typed.
  hostnameMismatch,

  /// Anything else the handshake reported.
  other,
}

/// The canonical origin a stored trust belongs to: scheme, host and port.
///
/// Trust never follows a path, a query or a redirect: the same host on
/// another port is another origin, and so is the same host over http.
String providerOrigin(String baseUrl) {
  final raw = baseUrl.trim();
  final uri = Uri.tryParse(raw);
  if (uri == null || !uri.hasAuthority || uri.host.isEmpty) {
    return raw.toLowerCase();
  }
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  final port = uri.hasPort ? uri.port : (scheme == 'https' ? 443 : 80);
  return '$scheme://$host:$port';
}

/// Reads the reason out of the handshake's text.
///
/// `dart:io` has one exception type for every certificate failure, and its
/// message is the only place the cause appears (BoringSSL's
/// `CERTIFICATE_VERIFY_FAILED: …`). The order matters: "expired" also
/// contains "certificate".
ProviderTlsProblem classifyProviderTlsFailure(HandshakeException error) {
  final text = '${error.message} ${error.osError?.message ?? ''}'.toLowerCase();
  if (text.contains('expired')) return ProviderTlsProblem.expired;
  if (text.contains('not yet valid') || text.contains('not yet')) {
    return ProviderTlsProblem.notYetValid;
  }
  if (text.contains('self signed') || text.contains('self-signed')) {
    return ProviderTlsProblem.selfSigned;
  }
  if (text.contains('hostname') ||
      text.contains('host name') ||
      text.contains('does not match') ||
      text.contains('ip address mismatch')) {
    return ProviderTlsProblem.hostnameMismatch;
  }
  if (text.contains('unable to get local issuer') ||
      text.contains('unable to get issuer') ||
      text.contains('unknown ca') ||
      text.contains('certificate verify failed')) {
    return ProviderTlsProblem.unknownIssuer;
  }
  return ProviderTlsProblem.other;
}

/// True when trusting the presented certificate could make the connection
/// work. An expired certificate is never offered: the pin check refuses it
/// too, so the only honest answer is to fix the clock or the certificate.
bool providerTlsProblemCanBeTrusted(ProviderTlsProblem problem) =>
    problem != ProviderTlsProblem.expired &&
    problem != ProviderTlsProblem.notYetValid;

/// One line for a diagnostic row, in the language the probe details use
/// (English, like the rest of that list).
String describeProviderTlsProblem(ProviderTlsProblem problem) =>
    switch (problem) {
      ProviderTlsProblem.selfSigned => 'self-signed certificate',
      ProviderTlsProblem.unknownIssuer => 'unknown certificate issuer',
      ProviderTlsProblem.expired => 'expired certificate',
      ProviderTlsProblem.notYetValid => 'certificate not yet valid',
      ProviderTlsProblem.hostnameMismatch =>
        'certificate does not match the address',
      ProviderTlsProblem.other => 'certificate could not be verified',
    };

/// A failed handshake that still carries the certificate the endpoint sent.
///
/// `HttpClient` throws a bare [HandshakeException] after calling
/// `badCertificateCallback`, so the callback stores the certificate and the
/// transport rethrows it as this type. That keeps the reason and the identity
/// together without a second connection (which would also bypass a proxy).
class ProviderTlsException extends HandshakeException {
  ProviderTlsException(
    super.message, {
    required this.certificate,
    required this.problem,
  });

  final X509Certificate certificate;
  final ProviderTlsProblem problem;

  ServerCertificateInfo get info =>
      ServerCertificateInfo.fromCertificate(certificate);
}

/// An HTTP client that accepts a previously trusted certificate and nothing
/// else beyond the normal root store.
///
/// [onUntrustedCertificate] receives every certificate that failed
/// verification, whether or not it matched a stored fingerprint, so a caller
/// can report the identity it saw.
HttpClient createProviderHttpClient({
  String? trustedFingerprint,
  Duration? connectionTimeout,
  void Function(X509Certificate certificate)? onUntrustedCertificate,
}) {
  final trimmed = trustedFingerprint?.trim() ?? '';
  final pin = trimmed.isEmpty ? null : normalizeCertificateFingerprint(trimmed);
  final client = HttpClient();
  if (connectionTimeout != null) {
    client.connectionTimeout = connectionTimeout;
  }
  // The environment's proxy, not DIRECT: a person on a phone may only reach
  // a gateway through the proxy they configured, and these calls are made by
  // the app rather than by the server.
  client.findProxy = HttpClient.findProxyFromEnvironment;
  client.badCertificateCallback = (certificate, host, port) {
    onUntrustedCertificate?.call(certificate);
    if (pin == null) return false;
    if (certificateFingerprintSha256(certificate) != pin) return false;
    final now = DateTime.now();
    return !now.isBefore(certificate.startValidity) &&
        !now.isAfter(certificate.endValidity);
  };
  return client;
}
