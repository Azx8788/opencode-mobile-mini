// The provider flow makes its requests inside the server, with the key the
// config already holds. These tests pin the two things that can go wrong
// silently:
//
//  * the identity the request carries — `opencode/<version>`, because some
//    gateways answer anything else with a 200 and a refusal;
//  * the key — it must never be in the script, the payload or the answer.
//
// The scripts themselves run in the server's rootfs, which no unit test can
// reach; what is checked here is the payload they are given and how their
// answers are read back.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/api2/models.dart';
import 'package:opencode_mobile/api2/provider_session_probe.dart';
import 'package:opencode_mobile/builtin/builtin_linux.dart';
import 'package:opencode_mobile/builtin/provider_server_models.dart';
import 'package:opencode_mobile/builtin/provider_server_scripts.dart';
import 'package:opencode_mobile/domain/custom_provider.dart';
import 'package:opencode_mobile/domain/provider_model_source.dart';

/// The payload a generated script carries, decoded.
Map<String, Object?> payloadOf(String script) {
  final start = script.indexOf("python3 - '");
  expect(start, greaterThan(0), reason: 'the script passes a payload');
  final from = start + "python3 - '".length;
  final to = script.indexOf("'", from);
  return jsonDecode(utf8.decode(base64Decode(script.substring(from, to))))
      as Map<String, Object?>;
}

/// What the script prints for a decoded answer.
String resultLine(Object payload) =>
    '${ProviderServerScripts.marker}'
    '${base64Encode(utf8.encode(jsonEncode(payload)))}';

void main() {
  group('the identity the server sends', () {
    test('is the running server version', () {
      expect(ProviderServerScripts.userAgent('2.1.1'), 'opencode/2.1.1');
      expect(ProviderServerScripts.userAgent(' 2.0.29 '), 'opencode/2.0.29');
    });

    test('falls back instead of passing a version through', () {
      // The value reaches a shell command and an HTTP header: anything that is
      // not a plain version is replaced, never escaped and hoped for.
      for (final bad in <String?>[
        null,
        '',
        '2.1.1; rm -rf /',
        '../../etc/passwd',
        '2.1.1\r\nX-Evil: 1',
      ]) {
        expect(
          ProviderServerScripts.userAgent(bad),
          'opencode/${ProviderServerScripts.fallbackVersion}',
        );
      }
    });
  });

  group('the request script', () {
    test('names the config, the provider and the auth scheme, no key', () {
      final script = ProviderServerScripts.get(
        configPath: '/root/.oc-opencode2/config/opencode/opencode.json',
        providerID: 'hiyo',
        userAgent: 'opencode/2.1.1',
        url: Uri.parse('https://free.hiyo.top/v1/models'),
        auth: 'bearer',
        timeout: const Duration(seconds: 20),
      );
      final payload = payloadOf(script);
      expect(payload['action'], 'get');
      expect(payload['provider'], 'hiyo');
      expect(payload['url'], 'https://free.hiyo.top/v1/models');
      expect(payload['auth'], 'bearer');
      expect(payload['userAgent'], 'opencode/2.1.1');
      expect(payload['timeout'], 20);
      // The key is read by the script from the config; it is never an
      // argument, a payload field or a header the app builds.
      expect(script.contains('sk-'), isFalse);
      expect(payload.containsKey('apiKey'), isFalse);
      expect(script.contains('RESULT:'), isTrue);
      expect(script.contains("<<'OC_PROVIDER_MODELS'"), isTrue);
    });

    test('asks the script for the entry before fetching anything', () {
      final payload = payloadOf(
        ProviderServerScripts.describe(
          configPath: '/root/.oc-opencode2/config/opencode/opencode.json',
          providerID: 'hiyo',
          userAgent: 'opencode/2.1.1',
        ),
      );
      expect(payload['action'], 'describe');
      expect(payload.containsKey('url'), isFalse);
    });

    test('the scheme follows the header names the reader builds', () {
      expect(providerServerAuthScheme(const {'x-api-key': 'x'}), 'x-api-key');
      expect(
        providerServerAuthScheme(const {'x-goog-api-key': 'x'}),
        'x-goog-api-key',
      );
      expect(providerServerAuthScheme(const {'Authorization': 'x'}), 'bearer');
      expect(providerServerAuthScheme(const {'Accept': 'x'}), 'none');
      expect(providerServerAuthScheme(const {}), 'none');
    });
  });

  group('reading the answer', () {
    ProviderServerModelSource source(
      List<Map<String, Object?>> answers, {
      List<int>? exits,
      List<Map<String, Object?>>? payloads,
    }) {
      var index = 0;
      return ProviderServerModelSource(
        userAgent: 'opencode/2.1.1',
        run: (script, timeout) async {
          payloads?.add(payloadOf(script));
          final code = exits != null && index < exits.length ? exits[index] : 0;
          final answer = index < answers.length ? answers[index] : null;
          index++;
          return BuiltinLinuxRunResult(
            exitCode: code,
            output: answer == null ? '' : resultLine(answer),
          );
        },
      );
    }

    test('a list from the endpoint becomes models', () async {
      final payloads = <Map<String, Object?>>[];
      final listing = await source(
        [
          {'ok': true, 'baseUrl': 'https://gw.test/v1', 'hasKey': true, 'keySource': 'config'},
          {
            'ok': true,
            'status': 200,
            'body': '{"data":[{"id":"gpt-5.6-luna"},{"id":"glm-5.3-flash"}]}',
          },
        ],
        payloads: payloads,
      ).fetch(
        configPath: '/root/opencode.json',
        providerID: 'gw',
        baseUrl: 'https://gw.test/v1',
        protocol: ProviderProtocol.chatCompletions,
      );
      expect(listing.models.map((model) => model.id), [
        'gpt-5.6-luna',
        'glm-5.3-flash',
      ]);
      // The fetch asked the config first, then one URL with one scheme.
      expect(payloads.first['action'], 'describe');
      expect(payloads.last['action'], 'get');
      expect(payloads.last['auth'], 'bearer');
    });

    test('a config without a key tries no auth at all', () async {
      final payloads = <Map<String, Object?>>[];
      final listing = await source(
        [
          {'ok': true, 'baseUrl': 'https://gw.test/v1', 'hasKey': false, 'keySource': 'none'},
          {'ok': true, 'status': 200, 'body': '{"data":[{"id":"local-model"}]}'},
        ],
        payloads: payloads,
      ).fetch(
        configPath: '/root/opencode.json',
        providerID: 'gw',
        baseUrl: 'https://gw.test/v1',
        protocol: ProviderProtocol.chatCompletions,
      );
      expect(listing.models.single.id, 'local-model');
      expect(payloads.last['auth'], 'none');
    });

    test('a refused key keeps its status', () async {
      final failure = await expectFailure(
        source([
          {'ok': true, 'baseUrl': 'https://gw.test/v1', 'hasKey': true, 'keySource': 'config'},
          {'ok': true, 'status': 401, 'body': '{"error":"invalid key"}'},
          {'ok': true, 'status': 401, 'body': '{"error":"invalid key"}'},
          {'ok': true, 'status': 401, 'body': '{"error":"invalid key"}'},
          {'ok': true, 'status': 401, 'body': '{"error":"invalid key"}'},
        ]).fetch(
          configPath: '/root/opencode.json',
          providerID: 'gw',
          baseUrl: 'https://gw.test/v1',
          protocol: ProviderProtocol.chatCompletions,
        ),
      );
      expect(failure.kind, ProviderModelFetchKind.refusedKey);
      expect(failure.statusCode, 401);
    });

    test('a certificate the server cannot verify is its own reason', () async {
      final failure = await expectFailure(
        source([
          {'ok': true, 'baseUrl': 'https://gw.test/v1', 'hasKey': true, 'keySource': 'config'},
          {'ok': false, 'error': 'tls'},
        ]).fetch(
          configPath: '/root/opencode.json',
          providerID: 'gw',
          baseUrl: 'https://gw.test/v1',
          protocol: ProviderProtocol.chatCompletions,
        ),
      );
      expect(failure.kind, ProviderModelFetchKind.tls);
    });

    test('no python, or no provider, never becomes a phone request', () async {
      final noPython = await expectFailure(
        source(const [], exits: const [20]).fetch(
          configPath: '/root/opencode.json',
          providerID: 'gw',
          baseUrl: 'https://gw.test/v1',
          protocol: ProviderProtocol.chatCompletions,
        ),
      );
      expect(noPython.kind, ProviderModelFetchKind.serverUnavailable);

      final missing = await expectFailure(
        source(const [], exits: const [22]).fetch(
          configPath: '/root/opencode.json',
          providerID: 'gw',
          baseUrl: 'https://gw.test/v1',
          protocol: ProviderProtocol.chatCompletions,
        ),
      );
      expect(missing.kind, ProviderModelFetchKind.notConfigured);
    });

    test('a silent failure is reported, not guessed at', () async {
      final failure = await expectFailure(
        source(const [], exits: const [1]).fetch(
          configPath: '/root/opencode.json',
          providerID: 'gw',
          baseUrl: 'https://gw.test/v1',
          protocol: ProviderProtocol.chatCompletions,
        ),
      );
      expect(failure.kind, ProviderModelFetchKind.serverUnavailable);
    });
  });

  group('judging a real turn', () {
    Api2AssistantMessage assistant({
      String? text,
      Api2StructuredError? error,
      String model = 'gpt-5.6-luna',
    }) => Api2AssistantMessage(
      id: 'msg_1',
      time: Api2MessageTime(created: 1),
      model: Api2ModelRef(id: model, providerID: 'hiyo'),
      content: [if (text != null) Api2TextContent(text: text)],
      error: error,
    );

    test('text is a pass, and the reply is kept', () {
      final result = judgeProviderSession(
        [assistant(text: 'OK')],
        elapsed: const Duration(seconds: 2),
      );
      expect(result.passed, isTrue);
      expect(result.reply, 'OK');
      expect(result.model, 'gpt-5.6-luna');
    });

    test("the server's own error is the reason", () {
      final result = judgeProviderSession([
        assistant(error: Api2StructuredError(message: 'provider returned 401')),
      ], elapsed: Duration.zero);
      expect(result.passed, isFalse);
      expect(result.outcome, ProviderSessionOutcome.failed);
      expect(result.detail, 'provider returned 401');
    });

    test('a turn with no text is not a pass', () {
      final result = judgeProviderSession([
        assistant(),
      ], elapsed: Duration.zero);
      expect(result.passed, isFalse);
      expect(result.outcome, ProviderSessionOutcome.emptyReply);
    });

    test('no assistant message at all is not a pass', () {
      final result = judgeProviderSession(
        const [],
        elapsed: Duration.zero,
      );
      expect(result.passed, isFalse);
      expect(result.outcome, ProviderSessionOutcome.emptyReply);
    });
  });

  group('a failed model read is repeated', () {
    final listing = ProviderModelListing(
      models: const [CustomProviderModel(id: 'gpt-6-luna')],
      url: Uri.parse('https://gw.example.com/v1/models'),
      statusCode: 200,
    );

    test('three times, a second, two, then four', () async {
      final waits = <Duration>[];
      final attempts = <int>[];
      var calls = 0;
      await expectLater(
        readProviderModelsWithRetry(
          () async {
            calls++;
            throw const ProviderModelFetchFailure(
              'The server did not answer',
              kind: ProviderModelFetchKind.network,
            );
          },
          onRetry: (attempt, wait) {
            attempts.add(attempt);
            waits.add(wait);
          },
          wait: (duration) async {},
        ),
        throwsA(isA<ProviderModelFetchFailure>()),
      );
      expect(calls, 4, reason: 'one try and three retries');
      expect(attempts, [1, 2, 3]);
      expect(waits, [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);
    });

    test('a refusal is not repeated', () async {
      var calls = 0;
      final failure = await expectFailure(
        readProviderModelsWithRetry(
          () async {
            calls++;
            throw const ProviderModelFetchFailure(
              'The API key was refused (401)',
              kind: ProviderModelFetchKind.refusedKey,
              statusCode: 401,
            );
          },
          wait: (duration) async {},
        ),
      );
      expect(calls, 1, reason: 'the same key will be refused again');
      expect(failure.kind, ProviderModelFetchKind.refusedKey);
    });

    test('a second attempt can succeed', () async {
      var calls = 0;
      final result = await readProviderModelsWithRetry(
        () async {
          calls++;
          if (calls == 1) {
            throw const ProviderModelFetchFailure(
              'The endpoint did not answer in time',
              kind: ProviderModelFetchKind.timeout,
            );
          }
          return listing;
        },
        wait: (duration) async {},
      );
      expect(calls, 2);
      expect(result.models.single.id, 'gpt-6-luna');
    });

    test('only failures that can change are transient', () {
      const transient = [
        ProviderModelFetchKind.network,
        ProviderModelFetchKind.timeout,
        ProviderModelFetchKind.serverError,
        ProviderModelFetchKind.serverUnavailable,
        ProviderModelFetchKind.unknown,
      ];
      const settled = [
        ProviderModelFetchKind.badUrl,
        ProviderModelFetchKind.missingKey,
        ProviderModelFetchKind.refusedKey,
        ProviderModelFetchKind.notFound,
        ProviderModelFetchKind.notJson,
        ProviderModelFetchKind.emptyList,
        ProviderModelFetchKind.tls,
        ProviderModelFetchKind.notConfigured,
      ];
      for (final kind in transient) {
        expect(providerModelFetchIsTransient(kind), isTrue, reason: '$kind');
      }
      for (final kind in settled) {
        expect(providerModelFetchIsTransient(kind), isFalse, reason: '$kind');
      }
    });
  });
}

/// The failure a call throws, with its kind intact.
Future<ProviderModelFetchFailure> expectFailure(
  Future<Object?> call,
) async {
  try {
    await call;
  } on ProviderModelFetchFailure catch (error) {
    return error;
  }
  fail('the read was expected to fail');
}
