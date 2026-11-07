import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/custom_provider.dart';
import 'package:opencode_mobile/domain/provider_balance.dart';
import 'package:opencode_mobile/domain/provider_model_source.dart';
import 'package:opencode_mobile/domain/provider_probe.dart';
import 'package:opencode_mobile/domain/provider_tls.dart';
import 'package:opencode_mobile/state/model_library.dart';

/// A real HTTPS server with a self-signed certificate, because the failure
/// this covers only exists at the handshake: a fake transport that throws
/// `HandshakeException` would prove the catch block, not that a trusted
/// fingerprint actually makes `dart:io` complete the connection.
void main() {
  late HttpServer server;
  late int port;

  setUpAll(() async {
    final context = SecurityContext()
      ..useCertificateChain('test/fixtures/provider_self_signed_cert.pem')
      ..usePrivateKey('test/fixtures/provider_self_signed_key.pem');
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    port = server.port;
    server.listen((request) async {
      if (request.uri.path == '/models') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'object': 'list',
            'data': [
              {'id': 'trusted-model', 'display_name': 'Trusted Model'},
            ],
          }),
        );
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  String base() => 'https://127.0.0.1:$port';

  Future<ProviderModelFetchFailure> failure({String? pin}) async {
    try {
      await ProviderModelSource().fetch(
        baseUrl: base(),
        protocol: ProviderProtocol.chatCompletions,
        apiKey: 'sk-test',
        trustedFingerprint: pin,
      );
    } on ProviderModelFetchFailure catch (error) {
      return error;
    }
    fail('the self-signed endpoint should have been refused');
  }

  group('a certificate the device cannot verify', () {
    test('fails with the certificate and its reason, not a dead end', () async {
      final error = await failure();
      expect(error.kind, ProviderModelFetchKind.tls);
      expect(error.certificate, isNotNull);
      expect(error.certificate!.subject, contains('provider-test'));
      expect(
        error.certificate!.fingerprintSha256,
        matches(RegExp(r'^[0-9a-f]{64}$')),
      );
      expect(error.certificate!.endValidity.isAfter(DateTime.now()), isTrue);
      expect(
        error.tlsProblem,
        anyOf(ProviderTlsProblem.selfSigned, ProviderTlsProblem.unknownIssuer),
      );
      expect(error.trustWasPinned, isFalse);
    });

    test('the stored fingerprint lets the same address answer', () async {
      final first = await failure();
      final listing = await ProviderModelSource().fetch(
        baseUrl: base(),
        protocol: ProviderProtocol.chatCompletions,
        apiKey: 'sk-test',
        trustedFingerprint: first.certificate!.fingerprintSha256,
      );
      expect(listing.models.map((model) => model.id), ['trusted-model']);
      expect(listing.url.path, '/models');
    });

    test('a different fingerprint is refused again', () async {
      final error = await failure(pin: '0' * 64);
      expect(error.kind, ProviderModelFetchKind.tls);
      expect(error.certificate, isNotNull);
      // A pin was in use: the form warns that the certificate changed rather
      // than presenting this as a first-time question.
      expect(error.trustWasPinned, isTrue);
    });
  });

  group('the other reads use the same trust', () {
    test(
      'a probe without the pin reports the certificate, not a stack',
      () async {
        final result = await ProviderProbe().runOne(
          kind: ProviderProbeKind.nonStreaming,
          protocol: ProviderProtocol.chatCompletions,
          baseUrl: base(),
          model: 'trusted-model',
          apiKey: 'sk-test',
        );
        expect(result.passed, isFalse);
        expect(result.detail, contains('certificate could not be verified'));
        expect(result.detail, isNot(contains('HandshakeException')));
      },
    );

    test('a probe with the pin reaches the endpoint', () async {
      final first = await failure();
      final result =
          await ProviderProbe(
            trustedFingerprint: first.certificate!.fingerprintSha256,
          ).runOne(
            kind: ProviderProbeKind.nonStreaming,
            protocol: ProviderProtocol.chatCompletions,
            baseUrl: base(),
            model: 'trusted-model',
            apiKey: 'sk-test',
          );
      // The test server answers 404 there; what matters is that the
      // handshake happened, so the detail is an HTTP status, not a
      // certificate complaint.
      expect(result.passed, isFalse);
      expect(result.detail, contains('404'));
    });

    test('a balance lookup with the pin reads the value', () async {
      final first = await failure();
      final client = ProviderBalanceClient();
      final reading = await client.fetch(
        balance: const ProviderBalance(
          enabled: true,
          url: '${ProviderBalance.baseUrlToken}/models',
          resultPath: 'data[0].id',
        ),
        baseUrl: base(),
        apiKey: 'sk-test',
        trustedFingerprint: first.certificate!.fingerprintSha256,
      );
      expect(reading.value, 'trusted-model');
    });
  });

  group('reasons are named', () {
    ProviderTlsProblem classify(String message) =>
        classifyProviderTlsFailure(HandshakeException(message));

    test('self-signed', () {
      expect(
        classify(
          'Handshake error in client (OS Error: '
          'CERTIFICATE_VERIFY_FAILED: self signed certificate(handshake.cc:1))',
        ),
        ProviderTlsProblem.selfSigned,
      );
    });

    test('unknown issuer', () {
      expect(
        classify(
          'CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate',
        ),
        ProviderTlsProblem.unknownIssuer,
      );
    });

    test('expired is not offered for trust', () {
      final problem = classify('certificate has expired');
      expect(problem, ProviderTlsProblem.expired);
      expect(providerTlsProblemCanBeTrusted(problem), isFalse);
    });

    test('hostname mismatch', () {
      expect(
        classify('Hostname mismatch: certificate does not match 10.0.0.2'),
        ProviderTlsProblem.hostnameMismatch,
      );
    });
  });

  group('origin', () {
    test('drops the path and fills the default port', () {
      expect(
        providerOrigin('HTTPS://GW.Example.com/v1/models?x=1'),
        'https://gw.example.com:443',
      );
      expect(providerOrigin('http://10.0.0.2:8080/v1'), 'http://10.0.0.2:8080');
    });

    test('trust is remembered per origin, not per provider', () {
      const fingerprint =
          '193f5e4093604d37beb5d426a2562e2d2e812d60adf26004ade45b0c1dc765b2';
      final library = const ModelLibrary().withProviderTrust(
        'https://gw.example.com:443',
        fingerprint.toUpperCase(),
      );
      expect(
        library.providerTrustFor('https://gw.example.com:443'),
        fingerprint,
      );
      expect(library.providerTrustFor('https://other.example.com:443'), isNull);

      final restored = ModelLibrary.fromJson(
        jsonDecode(jsonEncode(library.toJson())),
      );
      expect(
        restored.providerTrustFor('https://gw.example.com:443'),
        fingerprint,
      );

      expect(
        library
            .withProviderTrust('https://gw.example.com:443', null)
            .providerTrustFor('https://gw.example.com:443'),
        isNull,
      );
    });
  });
}
