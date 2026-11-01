import 'package:flutter/material.dart';

import '../../kit/kit.dart';
import 'usage_text.dart';

/// "Add a subscription": the providers never used, each with its logo. A pick
/// closes this page and hands the provider on; the caller then asks where to
/// sign it in.
class UsageAddPickerScreen extends StatelessWidget {
  const UsageAddPickerScreen({
    super.key,
    required this.providerIds,
    required this.onPick,
  });

  final List<String> providerIds;
  final void Function(String providerId) onPick;

  @override
  Widget build(BuildContext context) {
    final l10n = usageStrings(context);
    final tokens = KitTokens.of(context);
    return KitScreen(
      topBar: KitTopBar(title: l10n.usageAddSection),
      width: KitScreenWidth.reading,
      body: ListView(
        key: const ValueKey('usage-add-picker'),
        padding: EdgeInsetsDirectional.only(
          top: tokens.space2,
          bottom: KitScreen.endPadding(context),
        ),
        children: [
          KitRowGroup(
            children: [
              for (final id in providerIds)
                KitRow(
                  key: ValueKey('usage-add-$id'),
                  leading: UsageText.logo(id),
                  title: UsageText.provider(l10n, id, id),
                  trailing: const KitChevron(),
                  onTap: () {
                    Navigator.of(context).pop();
                    onPick(id);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}
