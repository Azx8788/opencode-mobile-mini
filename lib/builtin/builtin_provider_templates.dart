/// The providers the app already knows how to describe.
///
/// Picking one fills the form's name, address and protocol; it does not
/// write anything. That is the same promise the screen makes everywhere
/// else — a template is a head start, and every field stays the person's.
///
/// A template's address is the one its docs print. Nothing is guessed: a
/// gateway whose root differs is edited by hand in the form, which is
/// exactly what the fields are for.
library;

import '../domain/custom_provider.dart';
import '../domain/provider_balance.dart';

/// What kind of provider a template adds, in words a list can group by.
enum ProviderTemplateKind { official, gateway, china, custom }

class BuiltinProviderTemplate {
  const BuiltinProviderTemplate({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.protocol,
    required this.kind,
    this.balance,
  });

  /// The provider id the entry will get unless the person changes it.
  final String id;

  final String name;
  final String baseUrl;
  final ProviderProtocol protocol;
  final ProviderTemplateKind kind;

  /// A balance endpoint worth prefilling, when the provider documents one.
  final ProviderBalance? balance;
}

const builtinProviderTemplates = <BuiltinProviderTemplate>[
  BuiltinProviderTemplate(
    id: 'openai',
    name: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.official,
  ),
  BuiltinProviderTemplate(
    id: 'anthropic',
    name: 'Anthropic',
    baseUrl: 'https://api.anthropic.com/v1',
    protocol: ProviderProtocol.anthropic,
    kind: ProviderTemplateKind.official,
  ),
  BuiltinProviderTemplate(
    id: 'gemini',
    name: 'Gemini',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    protocol: ProviderProtocol.google,
    kind: ProviderTemplateKind.official,
  ),
  BuiltinProviderTemplate(
    id: 'deepseek',
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com/v1',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.china,
    balance: ProviderBalance(
      url: '{{baseUrl}}/user/balance',
      resultPath: 'balance_infos[0].total_balance',
    ),
  ),
  BuiltinProviderTemplate(
    id: 'moonshot',
    name: 'Moonshot Kimi',
    baseUrl: 'https://api.moonshot.cn/v1',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.china,
  ),
  BuiltinProviderTemplate(
    id: 'zhipu',
    name: '智谱 GLM',
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.china,
  ),
  BuiltinProviderTemplate(
    id: 'openrouter',
    name: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.gateway,
  ),
  BuiltinProviderTemplate(
    id: 'siliconflow',
    name: '硅基流动',
    baseUrl: 'https://api.siliconflow.cn/v1',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.china,
  ),
  BuiltinProviderTemplate(
    id: 'custom',
    name: '',
    baseUrl: '',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.custom,
  ),
];

/// The template matching [id], if any. Used to restore a base URL's default
/// after it was changed.
BuiltinProviderTemplate? providerTemplateFor(String id) {
  for (final template in builtinProviderTemplates) {
    if (template.id == id) return template;
  }
  return null;
}
