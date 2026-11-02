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
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/l10n/app_localizations.dart';
import 'package:opencode_mobile/state/app_locale.dart';

/// The message keys of an ARB file, without its `@` metadata entries.
Map<String, String> _messages(String path) {
  final raw = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final entry in raw.entries)
      if (!entry.key.startsWith('@')) entry.key: entry.value as String,
  };
}

/// The `{name}` / `{name, plural, …}` arguments a message reads.
///
/// A branch body that happens to be one word (`=1{once}`) is not an argument,
/// so the scan follows ICU structure instead of matching every `{word}`.
Set<String> _placeholders(String value) {
  final found = <String>{};
  void scan(String text) {
    var i = 0;
    while (true) {
      final open = text.indexOf('{', i);
      if (open < 0) return;
      final close = _closingBrace(text, open);
      if (close < 0) return;
      final inner = text.substring(open + 1, close);
      final icu = RegExp(
        r'^([a-z][a-zA-Z0-9_]*),\s*(plural|select),\s*([\s\S]*)$',
      ).firstMatch(inner);
      if (icu != null) {
        found.add(icu.group(1)!);
        var rest = icu.group(3)!;
        while (true) {
          final branch = RegExp(r'(?:^|[, ])(=?\w+)\s*\{').firstMatch(rest);
          if (branch == null) break;
          final bodyOpen = rest.indexOf('{', branch.end - 1);
          final bodyClose = _closingBrace(rest, bodyOpen);
          if (bodyOpen < 0 || bodyClose < 0) break;
          scan(rest.substring(bodyOpen + 1, bodyClose));
          rest = rest.substring(bodyClose + 1);
        }
      } else {
        final head = inner.split(',').first.trim();
        if (RegExp(r'^[a-z][a-zA-Z0-9_]*$').hasMatch(head)) found.add(head);
      }
      i = close + 1;
    }
  }

  scan(value);
  return found;
}

int _closingBrace(String text, int open) {
  var depth = 0;
  for (var i = open; i < text.length; i++) {
    if (text[i] == '{') depth++;
    if (text[i] == '}') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

/// The `=1{…}`, `other{…}` (and select) branches of an ICU message.
Set<String> _branchesOf(String value, String kind) {
  final head = RegExp('^.*?,\\s*(?:plural|select),\\s*').firstMatch(value);
  if (head == null) return const {};
  final labels = RegExp(r'(?:^|[, ])(=?\w+)\{')
      .allMatches(value.substring(head.end))
      .map((match) => match.group(1)!)
      .toSet();
  // Chinese has no plural category of its own, so a translation may keep only
  // `other`. Every select branch still has to be there: it carries meaning.
  return kind == 'plural'
      ? {...labels.where((label) => label != 'one' && label != '=1')}
      : labels;
}

String? _icuKind(String value) =>
    RegExp(r'^.*?,\s*(plural|select),\s*').firstMatch(value)?.group(1);

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

  // A missing Chinese message silently falls back to English in the generated
  // code: the screen reads as half translated, with no warning at build time.
  test('every English message has a Chinese one', () {
    final en = _messages('lib/l10n/app_en.arb');
    final zh = _messages('lib/l10n/app_zh.arb');
    expect(
      [
        for (final key in en.keys)
          if (!zh.containsKey(key)) key,
      ],
      isEmpty,
      reason: 'these keys would read in English on a Chinese phone',
    );
  });

  test('Chinese keeps every placeholder and every ICU branch', () {
    final en = _messages('lib/l10n/app_en.arb');
    final zh = _messages('lib/l10n/app_zh.arb');
    for (final key in en.keys) {
      final translated = zh[key];
      if (translated == null) continue;
      expect(
        _placeholders(translated),
        _placeholders(en[key]!),
        reason: '$key lost or gained a placeholder',
      );
      expect(
        _branchesOf(translated, _icuKind(en[key]!) ?? 'select'),
        _branchesOf(en[key]!, _icuKind(en[key]!) ?? 'select'),
        reason: '$key lost or gained a plural/select branch',
      );
    }
  });
}
