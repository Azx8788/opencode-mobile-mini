/// The providers the app itself ships.
///
/// Five entries, each taken from the provider's own integration docs:
/// AgentRouter, 书生·端砚, 魔搭 ModelScope, AMD and OpenRouter. The rest of the
/// catalogue the app used to carry is gone; these are ordinary entries, and
/// nothing is written until one is filled in and saved. Every field — name,
/// address, protocol, key, models — stays the person's.
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
    id: 'agentrouter',
    name: 'AgentRouter',
    baseUrl: 'https://agentrouter.org/v1',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.gateway,
  ),
  BuiltinProviderTemplate(
    id: 'intern',
    name: '书生·端砚',
    baseUrl: 'https://discovery-api.intern-ai.org.cn/v1',
    protocol: ProviderProtocol.anthropic,
    kind: ProviderTemplateKind.china,
  ),
  BuiltinProviderTemplate(
    id: 'modelscope',
    name: '魔搭 ModelScope',
    baseUrl: 'https://api-inference.modelscope.cn/v1',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.china,
  ),
  BuiltinProviderTemplate(
    id: 'amd',
    name: 'AMD',
    baseUrl: 'https://developer.amd.com.cn/radeon/api/v1',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.official,
  ),
  BuiltinProviderTemplate(
    id: 'openrouter',
    name: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    protocol: ProviderProtocol.chatCompletions,
    kind: ProviderTemplateKind.gateway,
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
