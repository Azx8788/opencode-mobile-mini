import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/provider_balance.dart';
import 'package:opencode_mobile/domain/provider_tls.dart';
import 'package:opencode_mobile/domain/server_trust.dart';
import 'package:opencode_mobile/state/model_library.dart';

/// A real HTTPS server with a self-signed certificate, because the failure
/// this covers only exists at the handshake: a fake transport that throws
/// `HandshakeException` would prove the catch block, not that a trusted
/// fingerprint actually makes `dart:io` complete the connection.
///
/// What still connects from the phone is the balance lookup — the model list
/// and the provider test are made by the server now, with its own certificate
/// store, so their trust is not this app's to pin.
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

  /// The fingerprint the server presents, learned the way the app learns it:
  /// from a handshake it refused.
  Future<String> fingerprint() async {
    X509Certificate? rejected;
    final client = createProviderHttpClient(
      connectionTimeout: const Duration(seconds: 5),
      onUntrustedCertificate: (certificate) => rejected = certificate,
    );
    try {
      final request = await client.getUrl(Uri.parse('${base()}/models'));
      await request.close();
    } catch (_) {
      // The refusal is the point; the handshake already happened.
    } finally {
      client.close(force: true);
    }
    return certificateFingerprintSha256(rejected!);
  }

  group('the balance lookup uses the trust', () {
    test('with the pin it reads the value', () async {
      final client = ProviderBalanceClient();
      final reading = await client.fetch(
        balance: const ProviderBalance(
          enabled: true,
          url: '${ProviderBalance.baseUrlToken}/models',
          resultPath: 'data[0].id',
        ),
        baseUrl: base(),
        apiKey: 'sk-test',
        trustedFingerprint: await fingerprint(),
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
