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
    expect(gradle, contains('"OpenCode Plus"'));
  });

  // The version used to be asserted as a constant here, which failed on the
  // first bump. What actually matters is that the pubspec carries a valid
  // version and that the changelog leads with it, so a bump without notes is
  // the only way left to fail this check.
  test('pubspec version is a valid build and heads the changelog', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)$',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(
      match,
      isNotNull,
      reason: 'pubspec.yaml needs a "major.minor.patch+build" version line',
    );
    final version = 'version: ${match!.group(1)}+${match.group(2)}';
    expect(
      int.parse(match.group(2)!),
      greaterThan(0),
      reason: 'the build number must be a positive integer',
    );
    final changelog = File('CHANGELOG.md').readAsStringSync();
    expect(
      changelog,
      contains('## ${match.group(1)}+${match.group(2)} —'),
      reason: 'CHANGELOG.md must lead with an entry for $version',
    );
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