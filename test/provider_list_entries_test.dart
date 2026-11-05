import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/builtin/builtin_provider_templates.dart';
import 'package:opencode_mobile/domain/custom_provider.dart';
import 'package:opencode_mobile/domain/custom_provider_record.dart';

CustomProviderRecord _record({
  required String id,
  required String name,
  String baseUrl = 'https://proxy.example.com/v1',
  ProviderProtocol protocol = ProviderProtocol.chatCompletions,
  int models = 2,
}) => CustomProviderRecord(
  id: id,
  name: name,
  protocol: protocol,
  baseUrl: baseUrl,
  keyMode: ProviderKeyMode.plaintext,
  format: ProviderConfigFormat.v2,
  apiKey: 'sk-test',
  models: [
    for (var i = 0; i < models; i++) CustomProviderModel(id: 'model-$i'),
  ],
);

void main() {
  test('every shipped provider is a row, in shipped order', () {
    final entries = providerListEntries(CustomProviderCatalogue.empty);
    expect(
      [for (final entry in entries) entry.id],
      [for (final template in offeredProviderTemplates) template.id],
    );
    expect(entries.every((entry) => !entry.configured), isTrue);
    expect(entries.every((entry) => !entry.blocked), isTrue);
  });

  test('a saved entry keeps its row and takes the saved values', () {
    final entries = providerListEntries(
      CustomProviderCatalogue(
        records: [
          _record(
            id: 'agentrouter',
            name: 'AgentRouter 代理',
            baseUrl: 'https://proxy.example.com/v1',
            protocol: ProviderProtocol.anthropic,
          ),
        ],
        unreadable: 0,
      ),
    );
    final agentrouter = entries.firstWhere(
      (entry) => entry.id == 'agentrouter',
    );
    expect(agentrouter.configured, isTrue);
    expect(agentrouter.name, 'AgentRouter 代理');
    expect(agentrouter.baseUrl, 'https://proxy.example.com/v1');
    expect(agentrouter.protocol, ProviderProtocol.anthropic);
    // Still one row per provider: the shipped entry is not shown twice.
    expect(entries.where((entry) => entry.id == 'agentrouter').length, 1);
  });

  test('a provider the app did not ship is appended, not dropped', () {
    final entries = providerListEntries(
      CustomProviderCatalogue(
        records: [_record(id: 'my-gateway', name: 'My gateway')],
        unreadable: 0,
      ),
    );
    expect(entries.length, offeredProviderTemplates.length + 1);
    expect(entries.last.id, 'my-gateway');
    expect(entries.last.template, isNull);
  });

  test('an entry the form cannot read blocks its row', () {
    final entries = providerListEntries(
      const CustomProviderCatalogue(
        records: <CustomProviderRecord>[],
        unreadable: 1,
        unreadableIDs: {'agentrouter'},
      ),
    );
    final agentrouter = entries.firstWhere(
      (entry) => entry.id == 'agentrouter',
    );
    expect(agentrouter.blocked, isTrue);
    expect(agentrouter.configured, isFalse);
    // The rest of the list is unaffected.
    final modelscope = entries.firstWhere((entry) => entry.id == 'modelscope');
    expect(modelscope.blocked, isFalse);
  });

  test('the shipped list carries only the five documented providers', () {
    final ids = {for (final template in offeredProviderTemplates) template.id};
    expect(
      ids,
      equals(<String>{
        'agentrouter',
        'intern',
        'modelscope',
        'amd',
        'openrouter',
      }),
    );
    // The blank template is an action, not a row.
    expect(ids, isNot(contains('custom')));
  });

  test('a shipped entry keeps the address it is shipped with', () {
    final full = providerListEntries(CustomProviderCatalogue.empty);
    for (final entry in full) {
      expect(entry.baseUrl, entry.template!.baseUrl);
      expect(entry.protocol, entry.template!.protocol);
    }
  });
}