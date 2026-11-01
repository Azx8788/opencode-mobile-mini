import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/custom_provider.dart';

void main() {
  test('normalize URL trims trailing slash and /chat/completions', () {
    expect(normalizeCustomProviderUrl('http://x/v1/'), 'http://x/v1');
    expect(normalizeCustomProviderUrl('http://x/v1/chat/completions'), 'http://x/v1');
  });
  test('reserved IDs from v2.1.1 are blocked', () {
    expect(() => validateCustomProviderId('opencode'), throwsA(isA<CustomProviderException>()));
    expect(() => validateCustomProviderId('anthropic'), throwsA(isA<CustomProviderException>()));
    expect(() => validateCustomProviderId('my-relay'), returnsNormally);
  });
  test('model parsing supports data[] / models[] / bare array', () {
    expect(parseCustomModelsResponse({'data':[{'id':'m1'}]}), ['m1']);
    expect(parseCustomModelsResponse({'models':[{'name':'m2'}]}), ['m2']);
    expect(parseCustomModelsResponse(['m3']), ['m3']);
  });
  test('model IDs with slash preserved', () {
    expect(parseCustomModelsResponse({'data':[{'id':'p1/openrouter/a'}]}), ['p1/openrouter/a']);
  });
  test('bad JSON/c config rejected', () {
    expect(() => parseCustomModelsResponse('bad'), throwsA(isA<CustomProviderException>()));
  });
}
