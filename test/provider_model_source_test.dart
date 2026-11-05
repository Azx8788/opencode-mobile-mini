import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/custom_provider.dart';
import 'package:opencode_mobile/domain/provider_model_source.dart';

/// The exact envelope a NewAPI-style gateway returns, taken from
/// `codexfree.xiaotuxp.com` — including the `display_name` this app shows as
/// the row title. The key is not part of the test: the transport is faked.
const _gatewayBody =
    '{"data":[{"id":"gpt-5.6-luna","object":"model","created":1780876800,'
    '"owned_by":"openai","type":"model","display_name":"GPT-5.6 Luna"},'
    '{"id":"gpt-6-luna","object":"model","created":1790035200,'
    '"owned_by":"openai","type":"model","display_name":"GPT-6 Luna"}],'
    '"object":"list"}';

ProviderHttpAnswer _ok(String body) =>
    ProviderHttpAnswer(statusCode: 200, body: body);

void main() {
  group('a bare host', () {
    test('reads the list at /models and keeps the display name', () async {
      Uri? asked;
      final source = ProviderModelSource(
        get: (url, headers, timeout) async {
          asked = url;
          return _ok(_gatewayBody);
        },
      );
      final listing = await source.fetch(
        baseUrl: 'https://codexfree.example.com',
        protocol: ProviderProtocol.chatCompletions,
        apiKey: 'sk-test',
      );
      expect(asked.toString(), 'https://codexfree.example.com/models');
      expect(listing.models.map((model) => model.id), [
        'gpt-5.6-luna',
        'gpt-6-luna',
      ]);
      expect(listing.models.first.label, 'GPT-5.6 Luna');
      expect(listing.url.path, '/models');
      expect(listing.statusCode, 200);
    });

    test('falls through to /v1/models when the host has no /models', () async {
      final asked = <String>[];
      final source = ProviderModelSource(
        get: (url, headers, timeout) async {
          asked.add(url.path);
          if (url.path == '/models') {
            return const ProviderHttpAnswer(statusCode: 404, body: '');
          }
          return _ok(_gatewayBody);
        },
      );
      final listing = await source.fetch(
        baseUrl: 'https://gw.example.com',
        protocol: ProviderProtocol.chatCompletions,
        apiKey: 'sk-test',
      );
      expect(listing.models, hasLength(2));
      expect(asked, ['/models', '/v1/models']);
    });

    test('adds https when the scheme was left out', () async {
      Uri? asked;
      final source = ProviderModelSource(
        get: (url, headers, timeout) async {
          asked = url;
          return _ok(_gatewayBody);
        },
      );
      await source.fetch(
        baseUrl: '  codexfree.example.com  ',
        protocol: ProviderProtocol.chatCompletions,
      );
      expect(asked.toString(), 'https://codexfree.example.com/models');
    });
  });

  group('a 200 that is not a list', () {
    test('tries the next spelling when the first answers a web page', () async {
      final asked = <String>[];
      final source = ProviderModelSource(
        get: (url, headers, timeout) async {
          asked.add(url.path);
          if (url.path == '/models') {
            return _ok('<!DOCTYPE html><html><body>Sign in</body></html>');
          }
          return _ok(_gatewayBody);
        },
      );
      final listing = await source.fetch(
        baseUrl: 'https://gw.example.com',
        protocol: ProviderProtocol.chatCompletions,
        apiKey: 'sk-test',
      );
      expect(listing.models, hasLength(2));
      expect(asked, ['/models', '/v1/models']);
    });

    test('a page everywhere says so instead of "no models"', () async {
      final source = ProviderModelSource(
        get: (url, headers, timeout) async =>
            _ok('<html><body>Cloudflare</body></html>'),
      );
      await expectLater(
        source.fetch(
          baseUrl: 'https://gw.example.com',
          protocol: ProviderProtocol.chatCompletions,
          apiKey: 'sk-test',
        ),
        throwsA(
          isA<ProviderModelFetchFailure>().having(
            (failure) => failure.kind,
            'kind',
            ProviderModelFetchKind.notJson,
          ),
        ),
      );
    });
  });

  group('auth', () {
    test('an Anthropic host: x-api-key first, bearer when it is not read', () async {
      final seen = <Map<String, String>>[];
      final source = ProviderModelSource(
        get: (url, headers, timeout) async {
          seen.add(headers);
          if (headers.containsKey('x-api-key')) {
            return const ProviderHttpAnswer(statusCode: 401, body: '');
          }
          return _ok('{"data":[{"id":"claude-sonnet-4"}]}');
        },
      );
      final listing = await source.fetch(
        baseUrl: 'https://api.anthropic.com/v1',
        protocol: ProviderProtocol.anthropic,
        apiKey: 'sk-ant',
      );
      expect(listing.models.single.id, 'claude-sonnet-4');
      expect(seen.first['x-api-key'], 'sk-ant');
      expect(seen.first['anthropic-version'], '2023-06-01');
      expect(seen[1]['Authorization'], 'Bearer sk-ant');
    });

    test('a refused key is reported with the status and the trace', () async {
      final source = ProviderModelSource(
        get: (url, headers, timeout) async =>
            const ProviderHttpAnswer(statusCode: 401, body: ''),
      );
      await expectLater(
        source.fetch(
          baseUrl: 'https://gw.example.com/v1',
          protocol: ProviderProtocol.chatCompletions,
          apiKey: 'bad',
        ),
        throwsA(
          isA<ProviderModelFetchFailure>()
              .having((f) => f.kind, 'kind', ProviderModelFetchKind.refusedKey)
              .having((f) => f.statusCode, 'statusCode', 401)
              .having((f) => f.canRetryWithoutKey, 'canRetryWithoutKey', true)
              .having((f) => f.trace, 'trace', isNotEmpty),
        ),
      );
    });

    test('no key at all is its own reason', () async {
      final source = ProviderModelSource(
        get: (url, headers, timeout) async =>
            const ProviderHttpAnswer(statusCode: 401, body: ''),
      );
      await expectLater(
        source.fetch(
          baseUrl: 'https://gw.example.com',
          protocol: ProviderProtocol.chatCompletions,
        ),
        throwsA(
          isA<ProviderModelFetchFailure>().having(
            (f) => f.kind,
            'kind',
            ProviderModelFetchKind.missingKey,
          ),
        ),
      );
    });
  });

  group('what is sent', () {
    test('a key pasted with line breaks is cleaned, not rejected', () async {
      Map<String, String>? seen;
      final source = ProviderModelSource(
        get: (url, headers, timeout) async {
          seen = headers;
          return _ok(_gatewayBody);
        },
      );
      await source.fetch(
        baseUrl: 'https://gw.example.com',
        protocol: ProviderProtocol.chatCompletions,
        // A wrapped paste: 20 characters plus a newline and a space.
        apiKey: '  sk-9c64 c2407c697e20f1\n49fa8677  ',
      );
      expect(seen!['Authorization'], 'Bearer sk-9c64c2407c697e20f149fa8677');
    });

    test('a custom header the platform cannot send is dropped, not fatal', () async {
      Map<String, String>? seen;
      final source = ProviderModelSource(
        get: (url, headers, timeout) async {
          seen = headers;
          return _ok(_gatewayBody);
        },
      );
      final listing = await source.fetch(
        baseUrl: 'https://gw.example.com',
        protocol: ProviderProtocol.chatCompletions,
        apiKey: 'sk-test',
        headers: {
          'HTTP-Referer': 'https://app.example',
          'X-Title': '我的应用', // not Latin-1: HttpClient would throw
          'X-Broken': 'a\r\nb',
        },
      );
      expect(listing.models, hasLength(2));
      expect(seen!['HTTP-Referer'], 'https://app.example');
      expect(seen!.containsKey('X-Title'), isFalse);
      expect(seen!.containsKey('X-Broken'), isFalse);
    });

    test('a custom header overrides the default of the same name', () async {
      Map<String, String>? seen;
      final source = ProviderModelSource(
        get: (url, headers, timeout) async {
          seen = headers;
          return _ok(_gatewayBody);
        },
      );
      await source.fetch(
        baseUrl: 'https://gw.example.com',
        protocol: ProviderProtocol.chatCompletions,
        apiKey: 'sk-test',
        headers: {'Authorization': 'Token abc'},
      );
      expect(seen!['Authorization'], 'Token abc');
    });
  });

  group('failures keep what was tried', () {
    test('every spelling 404s: notFound, with one trace line per request', () async {
      final source = ProviderModelSource(
        get: (url, headers, timeout) async =>
            const ProviderHttpAnswer(statusCode: 404, body: ''),
      );
      await expectLater(
        source.fetch(
          baseUrl: 'https://gw.example.com',
          protocol: ProviderProtocol.chatCompletions,
          apiKey: 'sk-test',
        ),
        throwsA(
          isA<ProviderModelFetchFailure>()
              .having((f) => f.kind, 'kind', ProviderModelFetchKind.notFound)
              .having((f) => f.trace, 'trace', [
                'gw.example.com/models · 404',
                'gw.example.com/v1/models · 404',
              ]),
        ),
      );
    });

    test('a timeout stops at once instead of trying every URL', () async {
      var calls = 0;
      final source = ProviderModelSource(
        get: (url, headers, timeout) async {
          calls++;
          throw TimeoutException('slow');
        },
      );
      await expectLater(
        source.fetch(
          baseUrl: 'https://gw.example.com',
          protocol: ProviderProtocol.chatCompletions,
          apiKey: 'sk-test',
        ),
        throwsA(
          isA<ProviderModelFetchFailure>().having(
            (f) => f.kind,
            'kind',
            ProviderModelFetchKind.timeout,
          ),
        ),
      );
      expect(calls, 1);
    });

    test('a socket that will not open is a network failure', () async {
      final source = ProviderModelSource(
        get: (url, headers, timeout) async =>
            throw const SocketException('no route'),
      );
      await expectLater(
        source.fetch(
          baseUrl: 'https://gw.example.com',
          protocol: ProviderProtocol.chatCompletions,
        ),
        throwsA(
          isA<ProviderModelFetchFailure>().having(
            (f) => f.kind,
            'kind',
            ProviderModelFetchKind.network,
          ),
        ),
      );
    });

    test('an unusable address is refused before any request', () async {
      var calls = 0;
      final source = ProviderModelSource(
        get: (url, headers, timeout) async {
          calls++;
          return _ok(_gatewayBody);
        },
      );
      for (final bad in ['', '   ', 'ftp://gw.example.com', 'https://']) {
        await expectLater(
          source.fetch(
            baseUrl: bad,
            protocol: ProviderProtocol.chatCompletions,
          ),
          throwsA(
            isA<ProviderModelFetchFailure>().having(
              (f) => f.kind,
              'kind',
              ProviderModelFetchKind.badUrl,
            ),
          ),
          reason: bad,
        );
      }
      expect(calls, 0);
    });
  });

  group('candidates', () {
    test('a bare host asks /models first, then /v1/models', () {
      expect(
        ProviderModelSource.candidateUrls(
          'https://gw.example.com',
          ProviderProtocol.chatCompletions,
        ).map((url) => url.toString()),
        [
          'https://gw.example.com/models',
          'https://gw.example.com/v1/models',
        ],
      );
    });

    test('a base that already ends in /v1 is not doubled', () {
      expect(
        ProviderModelSource.candidateUrls(
          'https://gw.example.com/v1',
          ProviderProtocol.chatCompletions,
        ).map((url) => url.toString()),
        ['https://gw.example.com/v1/models'],
      );
    });

    test('Gemini asks /v1beta with a page size', () {
      expect(
        ProviderModelSource.candidateUrls(
          'https://generativelanguage.googleapis.com',
          ProviderProtocol.google,
        ).map((url) => url.toString()),
        [
          'https://generativelanguage.googleapis.com/models',
          'https://generativelanguage.googleapis.com/v1/models',
          'https://generativelanguage.googleapis.com/v1beta/models?pageSize=100',
          'https://generativelanguage.googleapis.com/models?pageSize=100',
        ],
      );
    });

    test('a path in the base is kept', () {
      expect(
        ProviderModelSource.candidateUrls(
          'https://gw.example.com/openai',
          ProviderProtocol.chatCompletions,
        ).map((url) => url.path),
        ['/openai/models', '/openai/v1/models'],
      );
    });
  });

  group('parsing', () {
    test('reads the label field some gateways use', () {
      final models = ProviderModelSource.parseModelList(
        '{"data":[{"id":"m","label":"Model M"}]}',
      );
      expect(models.single.label, 'Model M');
    });

    test('an HTML body never parses into a model named <html>', () {
      expect(
        ProviderModelSource.parseModelList(
          '<!DOCTYPE html><html><body><a href="/m">m</a></body></html>',
        ),
        isEmpty,
      );
    });

    test('a duplicate id is kept once, in the first position', () {
      final models = ProviderModelSource.parseModelList(
        '{"data":[{"id":"a"},{"id":"b"},{"id":"a"}]}',
      );
      expect(models.map((model) => model.id), ['a', 'b']);
    });
  });

  group('the root a model list implies', () {
    test('a bare host adopts the /v1 the list answered on', () {
      expect(
        CustomProviderDraft.adoptModelRoot(
          'https://gw.example.com',
          Uri.parse('https://gw.example.com/v1/models'),
          ProviderProtocol.chatCompletions,
        ),
        'https://gw.example.com/v1',
      );
    });

    test('a root that already answered is left alone', () {
      for (final typed in [
        'https://gw.example.com',
        'https://gw.example.com/',
      ]) {
        expect(
          CustomProviderDraft.adoptModelRoot(
            typed,
            Uri.parse('https://gw.example.com/models'),
            ProviderProtocol.chatCompletions,
          ),
          isNull,
          reason: typed,
        );
      }
      expect(
        CustomProviderDraft.adoptModelRoot(
          'https://gw.example.com/v1',
          Uri.parse('https://gw.example.com/v1/models'),
          ProviderProtocol.chatCompletions,
        ),
        isNull,
      );
    });

    test('the port survives', () {
      expect(
        CustomProviderDraft.adoptModelRoot(
          'http://192.168.1.9:8080',
          Uri.parse('http://192.168.1.9:8080/v1/models'),
          ProviderProtocol.chatCompletions,
        ),
        'http://192.168.1.9:8080/v1',
      );
    });

    test('Gemini adopts /v1beta', () {
      expect(
        CustomProviderDraft.adoptModelRoot(
          'https://generativelanguage.googleapis.com',
          Uri.parse('https://generativelanguage.googleapis.com/v1beta/models'),
          ProviderProtocol.google,
        ),
        'https://generativelanguage.googleapis.com/v1beta',
      );
    });
  });
}
