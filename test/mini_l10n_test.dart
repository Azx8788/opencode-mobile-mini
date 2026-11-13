// Mini smoke tests for the two shipped locales.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/l10n/app_localizations.dart';
import 'package:opencode_mobile/l10n/app_localizations_en.dart';
import 'package:opencode_mobile/l10n/app_localizations_zh.dart';

void main() {
  test('supported locales are English and Chinese', () {
    expect(
          AppLocalizations.delegate.isSupported(const Locale('ar')),
          isFalse,
        );
        expect(
          AppLocalizations.delegate.isSupported(const Locale('zh')),
          isTrue,
        );
    expect(
      AppLocalizations.delegate.isSupported(const Locale('zh')),
      isTrue,
    );
  });

  test('both locales carry the Mini product name', () {
    expect(AppLocalizationsEn().appTitle, 'OpenCode Plus');
    expect(AppLocalizationsZh().appTitle, 'OpenCode Plus');
  });

  testWidgets('localizations wire into a MaterialApp', (tester) async {
    for (final locale in <Locale>[const Locale('en'), const Locale('zh')]) {
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) =>
                Text(AppLocalizations.of(context).appTitle),
          ),
        ),
      );
      expect(find.text('OpenCode Plus'), findsOneWidget);
    }
  });
}