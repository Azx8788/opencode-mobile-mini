// Mini sanity tests for the trimmed package.
//
// These read the repository as checked in, so they catch the mistakes that trim
// work makes: an asset path left in pubspec.yaml after its file was deleted,
// a native library set that no longer matches the engine manifest, or a
// leftover x86_64 / non English-Chinese locale file.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

List<String> _assetPaths() {
  final pubspec = File('pubspec.yaml').readAsLinesSync();
  final paths = <String>[];
  var inAssets = false;
  for (final line in pubspec) {
    if (line.trimRight() == '  assets:') {
      inAssets = true;
      continue;
    }
    if (!inAssets) continue;
    if (line.trimRight() == '  fonts:') break;
    final trimmed = line.trim();
    if (trimmed.startsWith('- ')) {
      paths.add(trimmed.substring(2).trim());
    }
  }
  return paths;
}

void main() {
  test('every asset path in pubspec.yaml exists', () {
    final paths = _assetPaths();
    expect(paths, isNotEmpty);
    for (final path in paths) {
      expect(
        FileSystemEntity.typeSync(path),
        isNot(FileSystemEntityType.notFound),
        reason: 'missing asset: $path',
      );
    }
  });

  test('x86_64 native libraries and manifest are gone', () {
    expect(
      Directory('android/app/src/main/jniLibs/x86_64').existsSync(),
      isFalse,
    );
    expect(
      File('assets/aiteam/manifest-x86_64.json').existsSync(),
      isFalse,
    );
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle, contains('abiFilters.add("arm64-v8a")'));
    // The x86_64 name may appear only as an exclusion, never as a filter.
    expect(gradle, contains('lib/x86_64/**'));
    expect(gradle, contains('lib/armeabi-v7a/**'));
  });

  test('engine manifest only carries arm64-v8a and its hashes are present', () {
    final manifest =
        jsonDecode(
              File(
                'android/app/src/main/assets/aiteam-engine-manifest.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final abis = manifest['abis'] as Map<String, dynamic>;
    expect(abis.keys.toList(), <String>['arm64-v8a']);
    final sha = (abis['arm64-v8a'] as Map<String, dynamic>)['sha256']
        as Map<String, dynamic>;
    for (final library in <String>[
      'libaiteam_engine.so',
      'libaiteam_sandbox.so',
      'libaiteam_boundary_probe.so',
    ]) {
      expect(sha[library], matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(
        File(
          'android/app/src/main/jniLibs/arm64-v8a/$library',
        ).existsSync(),
        isTrue,
        reason: library,
      );
    }
  });

  test('application id and label are the Mini identity', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle, contains('applicationId = "com.azx8788.opencode.mini"'));
    expect(gradle, contains('namespace = "com.azx8788.opencode.mini"'));
    expect(gradle, contains('"OpenCode Mini"'));
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('version: 0.1.0+1'));
  });

  test('only English and Chinese ARB files ship', () {
    final arbs = Directory('lib/l10n')
        .listSync()
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .where((name) => name.endsWith('.arb'))
        .toList()
      ..sort();
    expect(arbs, <String>['app_en.arb', 'app_zh.arb']);
    for (final locale in <String>['ar', 'es', 'ja', 'pt', 'ru']) {
      expect(
        File('lib/l10n/app_localizations_$locale.dart').existsSync(),
        isFalse,
        reason: '$locale generated file is back',
      );
    }
  });

  test('the app no longer depends on a code-push channel', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, isNot(contains('shorebird')));
    expect(File('shorebird.yaml').existsSync(), isFalse);
    final updater = File(
      'lib/update/shorebird_update_notice.dart',
    ).readAsStringSync();
    expect(updater, isNot(contains('package:shorebird_code_push')));
    expect(updater, contains('bool get isAvailable => false;'));
  });
}