// Templates only prefill: an address that does not survive normalization
// would put a URL in the form the person did not type.
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/builtin/builtin_provider_templates.dart';
import 'package:opencode_mobile/domain/custom_provider.dart';

void main() {
  test('ids are unique', () {
    final ids = builtinProviderTemplates.map((template) => template.id).toSet();
    expect(ids.length, builtinProviderTemplates.length);
  });

  test('every template survives normalization unchanged', () {
    for (final template in builtinProviderTemplates) {
      final draft = CustomProviderDraft(
        name: template.name.isEmpty ? 'Custom' : template.name,
        id: template.id,
        protocol: template.protocol,
        baseUrl: template.baseUrl,
        models: const [CustomProviderModel(id: 'm')],
      );
      expect(
        draft.baseUrl,
        template.baseUrl,
        reason: 'template ${template.id} changes under normalization',
      );
    }
  });

  test('Gemini uses the Google protocol', () {
    final gemini = providerTemplateFor('gemini');
    expect(gemini, isNotNull);
    expect(gemini!.protocol, ProviderProtocol.google);
    expect(gemini.baseUrl, endsWith('/v1beta'));
  });

  test('the custom template starts empty', () {
    final custom = providerTemplateFor('custom');
    expect(custom, isNotNull);
    expect(custom!.baseUrl, isEmpty);
    expect(custom.name, isEmpty);
  });

  test('an unknown id has no template', () {
    expect(providerTemplateFor('nope'), isNull);
  });
}
