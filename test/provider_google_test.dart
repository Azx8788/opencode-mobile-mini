// Gemini speaks a different model-list shape: `models/...` resource names and
// `x-goog-api-key`. The requests themselves are made by the server now, so
// what is left to test here is how its answer is read.

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/custom_provider.dart';
import 'package:opencode_mobile/domain/provider_model_source.dart';

void main() {
  group('model list', () {
    test('strips the models/ prefix and reads displayName', () async {
      final source = ProviderModelSource(
        get: (url, headers, timeout) async => const ProviderHttpAnswer(
          statusCode: 200,
          body:
              '{"models":[{"name":"models/gemini-2.5-pro",'
              '"displayName":"Gemini 2.5 Pro"}]}',
        ),
      );
      final listing = await source.fetch(
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        protocol: ProviderProtocol.google,
        apiKey: 'k',
      );
      expect(listing.models.single.id, 'gemini-2.5-pro');
      expect(listing.models.single.label, 'Gemini 2.5 Pro');
    });

    test('asks for a page and sends the key plus custom headers', () async {
      Uri? seen;
      Map<String, String>? seenHeaders;
      final source = ProviderModelSource(
        get: (url, headers, timeout) async {
          seen = url;
          seenHeaders = headers;
          return const ProviderHttpAnswer(
            statusCode: 200,
            body: '{"models":[]}',
          );
        },
      );
      await expectLater(
        source.fetch(
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
          protocol: ProviderProtocol.google,
          apiKey: 'k',
          headers: const {'X-Title': 'mini'},
        ),
        throwsA(isA<ProviderModelFetchFailure>()),
      );
      expect(seen.toString(), contains('/models?pageSize=100'));
      expect(seenHeaders?['x-goog-api-key'], 'k');
      expect(seenHeaders?['X-Title'], 'mini');
    });
  });
}
