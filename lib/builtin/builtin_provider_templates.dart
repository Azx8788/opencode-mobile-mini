/// The providers the app itself ships.
///
/// This is the whole list a person chooses from. The app no longer asks the
/// server which providers it knows: that list is the server's own, and its
/// entries could not be edited here — an OpenAI row you could not point at a
/// proxy was a dead end. Ours are ordinary entries: nothing is written until
/// one is filled in and saved, and every field — name, address, protocol,
/// key, models — stays the person's.
///
/// The order and the addresses follow rikkahub's `DEFAULT_PROVIDERS`, so the
/// list a person sees here is the one the reference app shows.
library;

import '../domain/custom_provider.dart';
import '../domain/custom_provider_record.dart';
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
    id: 'gemini',
    name: 'Gemini',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    protocol: ProviderProtocol.google,
    kind: ProviderTemplateKind.official,
  ),
  BuiltinProviderTemplate(
    id: 'aihubmix',
    name: 'AiHubMix',
    baseUrl: 'https://aihubmix.com/v1',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.gateway,
  ),
  BuiltinProviderTemplate(
    id: 'apimart',
    name: 'APIMart',
    baseUrl: 'https://api.apimart.ai/v1',
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
    name: '月之暗面',
    baseUrl: 'https://api.moonshot.cn/v1',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.china,
    balance: ProviderBalance(
      url: '{{baseUrl}}/users/me/balance',
      resultPath: 'data.available_balance',
    ),
  ),
  BuiltinProviderTemplate(
    id: 'openrouter',
    name: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.gateway,
  ),
  BuiltinProviderTemplate(
    id: 'vercel',
    name: 'Vercel AI Gateway',
    baseUrl: 'https://ai-gateway.vercel.sh/v1',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.gateway,
    balance: ProviderBalance(
      url: '{{baseUrl}}/credits',
      resultPath: 'balance',
    ),
  ),
  BuiltinProviderTemplate(
    id: 'dashscope',
    name: '阿里云百炼',
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.china,
  ),
  BuiltinProviderTemplate(
    id: 'volcengine',
    name: '火山引擎',
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.china,
  ),
  BuiltinProviderTemplate(
    id: 'zhipu',
    name: '智谱AI开放平台',
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.china,
  ),
  BuiltinProviderTemplate(
    id: 'stepfun',
    name: '阶跃星辰',
    baseUrl: 'https://api.stepfun.com/v1',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.china,
  ),
  BuiltinProviderTemplate(
    id: 'ai302',
    name: '302.AI',
    baseUrl: 'https://api.302.ai/v1',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.gateway,
  ),
  BuiltinProviderTemplate(
    id: 'hunyuan',
    name: '腾讯混元',
    baseUrl: 'https://tokenhub.tencentmaas.com/v1',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.china,
  ),
  BuiltinProviderTemplate(
    id: 'xai',
    name: 'xAI',
    baseUrl: 'https://api.x.ai/v1',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.official,
  ),
  BuiltinProviderTemplate(
    id: 'suixiang',
    name: '随想AI网关',
    baseUrl: 'https://sui-xiang.com/v1',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.gateway,
  ),
  BuiltinProviderTemplate(
    id: 'marucode',
    name: 'MaruCode',
    baseUrl: 'https://api.muteki.site/v1',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.gateway,
  ),
  BuiltinProviderTemplate(
    id: 'minimax',
    name: 'MiniMax',
    baseUrl: 'https://api.minimaxi.com/anthropic/v1',
    protocol: ProviderProtocol.anthropic,
    kind: ProviderTemplateKind.china,
  ),
  BuiltinProviderTemplate(
    id: 'mimo',
    name: 'MIMO',
    baseUrl: 'https://api.xiaomimimo.com/v1',
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

/// Every provider the app ships, without the blank one: what the list shows.
List<BuiltinProviderTemplate> get offeredProviderTemplates => [
  for (final template in builtinProviderTemplates)
    if (template.kind != ProviderTemplateKind.custom) template,
];

/// The template matching [id], if any. Used to restore a base URL's default
/// after it was changed.
BuiltinProviderTemplate? providerTemplateFor(String id) {
  for (final template in builtinProviderTemplates) {
    if (template.id == id) return template;
  }
  return null;
}

/// One row of the provider list.
///
/// The list is one list on purpose: a shipped provider and one the person
/// added are the same thing to configure, and the only difference the row
/// cares about is whether a configuration exists yet.
class ProviderListEntry {
  const ProviderListEntry({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.protocol,
    this.template,
    this.record,
    this.blocked = false,
  });

  final String id;
  final String name;
  final String baseUrl;
  final ProviderProtocol protocol;

  /// The shipped template this row came from, if any: what a first save
  /// starts from and what "restore default" restores.
  final BuiltinProviderTemplate? template;

  /// The configuration on disk, or null while the row is only a name and an
  /// address.
  final CustomProviderRecord? record;

  /// True when the config holds an entry under this id that the form cannot
  /// read. The row is then a signpost, not a form.
  final bool blocked;

  bool get configured => record != null;
}

/// The rows the provider list shows: every shipped provider in shipped
/// order, then anything else the config holds.
///
/// A shipped provider that has been saved keeps its place but takes the saved
/// name, address and protocol — that is what "the same window" means: the
/// entry is edited where it was created, not in a second list.
List<ProviderListEntry> providerListEntries(CustomProviderCatalogue catalogue) {
  final byID = {for (final record in catalogue.records) record.id: record};
  final entries = <ProviderListEntry>[];
  final seen = <String>{};
  for (final template in offeredProviderTemplates) {
    final record = byID[template.id];
    entries.add(
      ProviderListEntry(
        id: template.id,
        name: record?.name ?? template.name,
        baseUrl: record?.baseUrl ?? template.baseUrl,
        protocol: record?.protocol ?? template.protocol,
        template: template,
        record: record,
        blocked: record == null && catalogue.unreadableIDs.contains(template.id),
      ),
    );
    seen.add(template.id);
  }
  for (final record in catalogue.records) {
    if (seen.contains(record.id)) continue;
    entries.add(
      ProviderListEntry(
        id: record.id,
        name: record.name,
        baseUrl: record.baseUrl,
        protocol: record.protocol,
        record: record,
      ),
    );
  }
  return entries;
}
