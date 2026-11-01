// Guards the Mini reduction to two catalogues.
//
// `lookupAppLocalizations` throws for a language code without an ARB, and a
// throw inside `BuiltinSetupFinisher` (it used to build profile names for
// Arabic) failed the setup job's last step *before* OpenCode was started, so
// every install ended with "could not start" and the localization error as the
// only log line. The picker and the stored preference had the same mismatch:
// both accepted `ar`, `es`, `ja`, `pt` and `ru` while only `en` and `zh` ship.
//
// These tests fail as soon as a screen, a stored choice or a picker entry can
// name a language this build cannot load.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/l10n/app_localizations.dart';
import 'package:opencode_mobile/state/app_locale.dart';

void main() {
  final shipped = {
    for (final locale in AppLocalizations.supportedLocales) locale.languageCode,
  };

  test('the stored-choice list matches the shipped catalogues', () {
    expect(AppLocaleStore.supportedLanguages, shipped);
    expect(AppLocaleStore.pickerLanguages.toSet(), shipped);
  });

  test('every shipped language loads without throwing', () {
    for (final locale in AppLocalizations.supportedLocales) {
      expect(() => lookupAppLocalizations(locale), returnsNormally);
    }
  });

  test('a language without a catalogue can never be stored or offered', () {
    for (final code in const ['ar', 'es', 'ja', 'pt', 'ru']) {
      expect(AppLocalizations.delegate.isSupported(Locale(code)), isFalse);
      expect(AppLocaleStore.supportedLanguages, isNot(contains(code)));
      expect(AppLocaleStore.pickerLanguages, isNot(contains(code)));
    }
  });
}
