import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../domain/server_probe.dart';
import '../api2/transport.dart';
import '../domain/server_trust.dart';
import 'profiles.dart';

/// Test-only response injection, after the same consent gate as real setup.
/// Production leaves this null and uses the origin-bound native TLS client.
@visibleForTesting
HttpClientAdapter Function()? trustedServerProbeAdapterFactory;

/// Shared setup probe for OpenCode 2. Consent is checked before credentials
/// enter any transport; the same trust policy is used after Save/restart.
/// Kept outside lib/api while that generation is being retired.
Future<ServerProbeResult> probeTrustedServerConnection({
  required String baseUrl,
  String? username,
  String? password,
  String? cleartextConfirmedOrigin,
  String? certificatePinSha256,
}) async {
  final invalid = validateServerProfileUrl(baseUrl);
  if (invalid != null) return ServerProbeResult.failure(invalid);
  if (serverUrlNeedsCleartextConfirmation(baseUrl) &&
      cleartextConfirmedOrigin != cleartextOriginOf(baseUrl)) {
    return const ServerProbeResult.failure(cleartextUnconfirmedMessage);
  }
  // Retain the existing injected setup-probe seam, after enforcing consent.
  if (!identical(serverProbe, probeServerConnection)) {
    return serverProbe(
      baseUrl: baseUrl,
      username: username,
      password: password,
    );
  }
  final transport = Api2Transport(
    baseUrl: baseUrl,
    password: password ?? '',
    username: username == null || username.isEmpty ? 'opencode' : username,
    cleartextConfirmedOrigin: cleartextConfirmedOrigin,
    certificatePinSha256: certificatePinSha256,
  );
  try {
    final adapterFactory = trustedServerProbeAdapterFactory;
    if (adapterFactory != null) {
      transport.dio.httpClientAdapter = adapterFactory();
    }
    final health = await transport.checkServer();
    return ServerProbeResult.success(health.version, flavor: ServerFlavor.v2);
  } on Api2AuthRequired {
    return ServerProbeResult.failure(
      (password ?? '').isEmpty
          ? 'This server requires its serve password.'
          : 'Password rejected. Check the server password and try again.',
      flavor: ServerFlavor.v2,
      needsPassword: true,
    );
  } on ServerCertificateChangedException {
    return const ServerProbeResult.failure('The server certificate changed.');
  } catch (error) {
    // Only fixed app-authored explanations leave this boundary. In particular
    // a server response, URL, or credential must not become the verdict.
    final text = error.toString().toLowerCase();
    if (text.contains('expired or not yet valid')) {
      return const ServerProbeResult.failure(
        'The server certificate is expired or not yet valid.',
      );
    }
    if (text.contains('certificate changed')) {
      return const ServerProbeResult.failure('The server certificate changed.');
    }
    if (text.contains('certificate') || text.contains('handshake')) {
      return const ServerProbeResult.failure(
        'The server certificate is not trusted. Review its fingerprint.',
      );
    }
    return const ServerProbeResult.failure(
      'The server could not be checked. Check the address and try again.',
    );
  } finally {
    transport.close();
  }
}
