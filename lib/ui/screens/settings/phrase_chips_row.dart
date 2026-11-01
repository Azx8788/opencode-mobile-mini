part of '../settings_screen.dart';

/// Settings › Conversations › Phrase suggestions: the switch for the row of
/// the person's own short phrases above the message box, and, when some were
/// hidden, a row that brings them back. Both read the phone's own store, so
/// an open chat redraws its row when this changes.
class PhraseChipsSettingsRow extends StatelessWidget {
  const PhraseChipsSettingsRow({super.key, required this.controller});

  final ConnectionController controller;

  @override
  Widget build(BuildContext context) {
    final copy = _settingsCopy(context);
    return ValueListenableBuilder<int>(
      valueListenable: PhraseChipStore.changes,
      builder: (context, _, _) {
        final prefs = controller.store.prefs;
        final profileID = controller.profile?.id ?? '';
        final hidden = profileID.isEmpty
            ? 0
            : PhraseChipStore.forProfile(prefs, profileID).hiddenCount;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KitSwitchRow(
              key: const ValueKey('settings-phrase-chips'),
              leading: KitRow.icon(context, AppIconography.chat),
              title: copy.settingsPhraseChipsTitle,
              value: PhraseChipStore.enabled(prefs),
              onChanged: (value) =>
                  unawaited(PhraseChipStore.setEnabled(prefs, value)),
            ),
            if (hidden > 0) ...[
              const KitDivider(inset: KitDividerInset.text),
              KitRow(
                key: const ValueKey('settings-phrase-chips-show-hidden'),
                leading: KitRow.icon(context, AppIconography.hidden),
                title: copy.settingsPhraseChipsShowHidden,
                supporting: TextSpan(
                  text: copy.settingsPhraseChipsHiddenCount(hidden),
                ),
                onTap: () => unawaited(
                  PhraseChipStore.forProfile(prefs, profileID).showHidden(),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
