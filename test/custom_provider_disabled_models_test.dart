import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/custom_provider.dart';
import 'package:opencode_mobile/domain/custom_provider_record.dart';

void main() {
  CustomProviderDraft draft({
    List<String> disabled = const [],
    List<String> selected = const ['gpt-4.1'],
    ProviderProtocol protocol = ProviderProtocol.chatCompletions,
  }) => CustomProviderDraft(
    name: 'OpenAI',
    id: 'openai',
    protocol: protocol,
    baseUrl: 'https://api.openai.com/v1',
    apiKey: 'sk-test',
    models: [for (final id in selected) CustomProviderModel(id: id)],
    disabledModelIDs: disabled,
  );

  group('v2 entry', () {
    test('模型表把没勾选的写成 disabled', () {
      final entry = draft(disabled: const ['gpt-4o', 'o3']).toProviderEntry(
        ProviderConfigFormat.v2,
      );
      final models = entry['models'] as Map<String, Object?>;
      expect(models['gpt-4.1'], isA<Map>());
      expect((models['gpt-4o'] as Map)['disabled'], isTrue);
      expect((models['o3'] as Map)['disabled'], isTrue);
    });

    test('勾选的模型不会被写成 disabled', () {
      final entry = draft(disabled: const ['gpt-4.1']).toProviderEntry(
        ProviderConfigFormat.v2,
      );
      final models = entry['models'] as Map<String, Object?>;
      expect((models['gpt-4.1'] as Map).containsKey('disabled'), isFalse);
      expect(models.length, 1);
    });

    test('空、重复、与勾选冲突的 id 不会写进去', () {
      final entry = draft(
        disabled: const ['', '  ', 'gpt-4o', 'gpt-4o', 'gpt-4.1'],
      ).toProviderEntry(ProviderConfigFormat.v2);
      final models = entry['models'] as Map<String, Object?>;
      expect(models.keys, unorderedEquals(['gpt-4.1', 'gpt-4o']));
      expect((models['gpt-4o'] as Map)['disabled'], isTrue);
    });
  });

  group('v1 entry', () {
    test('没勾选的模型写成 blacklist，模型条目里没有 disabled', () {
      final entry = draft(
        disabled: const ['gpt-4o', 'o3'],
        protocol: ProviderProtocol.chatCompletions,
      ).toProviderEntry(ProviderConfigFormat.v1);
      expect(entry['blacklist'], ['gpt-4o', 'o3']);
      final models = entry['models'] as Map<String, Object?>;
      expect((models['gpt-4.1'] as Map).containsKey('disabled'), isFalse);
    });

    test('没有停用的模型时不写空 blacklist', () {
      final entry = draft().toProviderEntry(ProviderConfigFormat.v1);
      expect(entry.containsKey('blacklist'), isFalse);
    });
  });

  group('读回配置', () {
    test('v2 的 disabled 条目不算已勾选模型', () {
      final document = draft(
        disabled: const ['gpt-4o'],
      ).toDocument(ProviderConfigFormat.v2);
      final catalogue = readCustomProviders(
        document,
        ProviderConfigFormat.v2,
      );
      final record = catalogue.records.single;
      expect(record.models.map((model) => model.id), ['gpt-4.1']);
      expect(record.disabledModels, ['gpt-4o']);
    });

    test('v1 的 blacklist 读成停用模型', () {
      final document = draft(
        disabled: const ['gpt-4o'],
      ).toDocument(ProviderConfigFormat.v1);
      final catalogue = readCustomProviders(
        document,
        ProviderConfigFormat.v1,
      );
      final record = catalogue.records.single;
      expect(record.models.map((model) => model.id), ['gpt-4.1']);
      expect(record.disabledModels, ['gpt-4o']);
    });

    test('保存 → 读回 → 再保存，停用集合不丢', () {
      final first = draft(disabled: const ['gpt-4o', 'o3']);
      final document = first.toDocument(ProviderConfigFormat.v2);
      final record = readCustomProviders(
        document,
        ProviderConfigFormat.v2,
      ).records.single;
      final second = record.toDraft();
      final entry = second.toProviderEntry(ProviderConfigFormat.v2);
      final models = entry['models'] as Map<String, Object?>;
      expect((models['gpt-4o'] as Map)['disabled'], isTrue);
      expect((models['o3'] as Map)['disabled'], isTrue);
      expect((models['gpt-4.1'] as Map).containsKey('disabled'), isFalse);
    });

    test('切换协议后停用集合跟着走', () {
      final switched = draft(
        disabled: const ['gpt-4o'],
      ).switchProtocol(ProviderProtocol.anthropic);
      expect(switched.disabledModelIDs, ['gpt-4o']);
    });
  });
}
