// The balance query: the path walk, the placeholders, and what the app sends.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/provider_balance.dart';

void main() {
  group('json path', () {
    final answer = {
      'balance_infos': [
        {'currency': 'CNY', 'total_balance': '12.34'},
        {'currency': 'USD', 'total_balance': '1.00'},
      ],
      'data': {
        'total_credits': 42,
      },
      'ok': true,
    };

    test('walks arrays and maps', () {
      expect(
        ProviderBalanceClient.walkBalanceJson(
          answer,
          'balance_infos[0].total_balance',
        ),
        '12.34',
      );
      expect(
        ProviderBalanceClient.walkBalanceJson(answer, 'data.total_credits'),
        42,
      );
    });

    test('returns null for a path the answer does not have', () {
      expect(
        ProviderBalanceClient.walkBalanceJson(answer, 'balance_infos[5].x'),
        isNull,
      );
      expect(ProviderBalanceClient.walkBalanceJson(answer, 'nope'), isNull);
    });

    test('renders numbers without a trailing .0', () {
      expect(ProviderBalanceClient.renderBalanceValue(42), '42');
      expect(ProviderBalanceClient.renderBalanceValue(42.0), '42');
      expect(ProviderBalanceClient.renderBalanceValue(1.5), '1.5');
      expect(ProviderBalanceClient.renderBalanceValue(' 9.9 '), '9.9');
    });
  });

  group('fetch', () {
    test('substitutes the placeholders and sends the key', () async {
      Uri? seenUrl;
      Map<String, String>? seenHeaders;
      final client = ProviderBalanceClient(
        get: (url, headers, timeout) async {
          seenUrl = url;
          seenHeaders = headers;
          return const ProviderBalanceAnswer(
            statusCode: 200,
            body: '{"balance_infos":[{"total_balance":"7.50"}]}',
          );
        },
      );
      final reading = await client.fetch(
        balance: const ProviderBalance(
          enabled: true,
          url: '{{baseUrl}}/user/balance',
          resultPath: 'balance_infos[0].total_balance',
        ),
        baseUrl: 'https://api.deepseek.com/v1/',
        apiKey: 'sk-1',
        headers: const {'X-Title': 'mini'},
      );
      expect(reading.value, '7.50');
      expect(seenUrl.toString(), 'https://api.deepseek.com/v1/user/balance');
      expect(seenHeaders?['authorization'], 'Bearer sk-1');
      expect(seenHeaders?['X-Title'], 'mini');
    });

    test('a non-2xx answer carries the status', () async {
      final client = ProviderBalanceClient(
        get: (url, headers, timeout) async => const ProviderBalanceAnswer(
          statusCode: 401,
          body: '{"error":"invalid key"}',
        ),
      );
      await expectLater(
        client.fetch(
          balance: const ProviderBalance(
            enabled: true,
            url: '{{baseUrl}}/balance',
            resultPath: 'balance',
          ),
          baseUrl: 'https://api.example.com/v1',
          apiKey: 'bad',
        ),
        throwsA(
          isA<ProviderBalanceFailure>().having(
            (error) => error.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
    });

    test('an unconfigured balance refuses before any request', () async {
      final client = ProviderBalanceClient(
        get: (url, headers, timeout) async =>
            throw StateError('must not be called'),
      );
      await expectLater(
        client.fetch(
          balance: const ProviderBalance(),
          baseUrl: 'https://api.example.com/v1',
        ),
        throwsA(isA<ProviderBalanceFailure>()),
      );
    });
  });

  group('json shape', () {
    test('round-trips through the local store', () {
      const balance = ProviderBalance(
        enabled: true,
        url: '{{baseUrl}}/credits',
        resultPath: 'data.total_credits',
      );
      final back = ProviderBalance.fromJson(
        jsonDecode(jsonEncode(balance.toJson())),
      );
      expect(back.enabled, isTrue);
      expect(back.url, '{{baseUrl}}/credits');
      expect(back.resultPath, 'data.total_credits');
    });

    test('an empty value is not configured', () {
      expect(const ProviderBalance().isConfigured, isFalse);
      expect(
        const ProviderBalance(url: 'x', resultPath: '').isConfigured,
        isFalse,
      );
    });
  });
}
