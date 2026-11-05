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

  test('ModelScope asks its OpenAI-compatible root', () {
    final modelscope = providerTemplateFor('modelscope');
    expect(modelscope, isNotNull);
    expect(modelscope!.protocol, ProviderProtocol.chatCompletions);
    expect(modelscope.baseUrl, 'https://api-inference.modelscope.cn/v1');
  });

  test('AgentRouter keeps one root for both protocols', () {
    // The docs give two addresses — no `/v1` for the Anthropic SDK, `/v1` for
    // OpenAI-compatible — because the Anthropic SDK adds `/v1` itself. The
    // config carries what the app appends, so one root serves both: switching
    // to Anthropic keeps `/v1` and the request lands on `/v1/messages`.
    final agentRouter = providerTemplateFor('agentrouter');
    expect(agentRouter, isNotNull);
    expect(agentRouter!.baseUrl, 'https://agentrouter.org/v1');
    expect(
      CustomProviderDraft.convertBaseUrl(
        agentRouter.baseUrl,
        from: ProviderProtocol.chatCompletions,
        to: ProviderProtocol.anthropic,
      ),
      'https://agentrouter.org/v1',
    );
  });

  test('书生·端砚 is a Responses provider', () {
    final intern = providerTemplateFor('intern');
    expect(intern, isNotNull);
    expect(intern!.protocol, ProviderProtocol.responses);
    expect(intern.baseUrl, 'https://discovery-api.intern-ai.org.cn/v1');
  });
}
