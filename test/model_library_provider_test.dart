// The provider-level switch and the balance endpoint are local preferences:
// they survive a restart without ever being written into opencode.json.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/models.dart' show ModelRef;
import 'package:opencode_mobile/domain/provider_balance.dart';
import 'package:opencode_mobile/state/model_library.dart';

void main() {
  group('hidden providers', () {
    test('hiding and showing one is reversible', () {
      final hidden = const ModelLibrary().withProviderHidden('gateway', true);
      expect(hidden.isProviderHidden('gateway'), isTrue);
      expect(
        hidden.withProviderHidden('gateway', false).isProviderHidden('gateway'),
        isFalse,
      );
    });

    test('an empty id changes nothing', () {
      const library = ModelLibrary();
      expect(library.withProviderHidden('  ', true).hiddenProviders, isEmpty);
    });

    test('survives a save and a read', () {
      final library = const ModelLibrary()
          .withProviderHidden('gateway', true)
          .withBalance(
            'gateway',
            const ProviderBalance(
              enabled: true,
              url: '{{baseUrl}}/user/balance',
              resultPath: 'balance_infos[0].total_balance',
            ),
          );
      final back = ModelLibrary.fromJson(
        jsonDecode(jsonEncode(library.toJson())),
      );
      expect(back.isProviderHidden('gateway'), isTrue);
      expect(back.balanceFor('gateway')?.url, '{{baseUrl}}/user/balance');
      expect(
        back.balanceFor('gateway')?.resultPath,
        'balance_infos[0].total_balance',
      );
    });

    test('an unconfigured balance is dropped, not stored', () {
      final library = const ModelLibrary().withBalance(
        'gateway',
        const ProviderBalance(),
      );
      expect(library.balances, isEmpty);
      expect(library.toJson().containsKey('balances'), isFalse);
    });
  });

  test('a hidden provider keeps its per-model list intact', () {
    final library = const ModelLibrary()
        .withEnabled(ModelRef(providerID: 'gateway', modelID: 'a'), false)
        .withProviderHidden('gateway', true);
    final back = ModelLibrary.fromJson(
      jsonDecode(jsonEncode(library.toJson())),
    );
    expect(back.isProviderHidden('gateway'), isTrue);
    expect(back.disabled.single.modelID, 'a');
  });
}
