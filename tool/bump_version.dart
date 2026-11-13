// Bumps the one version the app has: `version:` in pubspec.yaml.
//
// `flutter build apk` reads that line and nothing else, so a build made
// without touching it carries the same versionCode as the previous one and
// an installer has no reason to treat it as an upgrade. This script is the
// missing step: run it before a build, or let `tool/build_apk.sh` run it.
//
//   dart run tool/bump_version.dart              # 0.3.13+17 -> 0.3.13+18
//   dart run tool/bump_version.dart --patch      # 0.3.13+17 -> 0.3.14+18
//   dart run tool/bump_version.dart --minor      # 0.3.13+17 -> 0.4.0+18
//   dart run tool/bump_version.dart --major      # 0.3.13+17 -> 1.0.0+18
//   dart run tool/bump_version.dart --set 0.5.0+40
//   dart run tool/bump_version.dart --dry-run    # print, write nothing
//
// The build number always moves forward, including on --patch/--minor/
// --major: Android compares versionCode first, and a version that claims to
// be newer while carrying a smaller code is an install that silently does
// nothing.
import 'dart:io';

final _versionLine = RegExp(r'^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$');

void main(List<String> args) {
  final file = File('pubspec.yaml');
  if (!file.existsSync()) {
    stderr.writeln('pubspec.yaml not found; run this from the project root.');
    exit(2);
  }

  var dryRun = false;
  var bump = 'build';
  String? explicit;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--dry-run':
        dryRun = true;
      case '--patch':
        bump = 'patch';
      case '--minor':
        bump = 'minor';
      case '--major':
        bump = 'major';
      case '--build':
        bump = 'build';
      case '--set':
        if (i + 1 >= args.length) {
          stderr.writeln('--set needs a value, e.g. --set 0.3.14+18');
          exit(2);
        }
        explicit = args[++i];
      case '--help' || '-h':
        stdout.writeln(
          'usage: dart run tool/bump_version.dart '
          '[--build|--patch|--minor|--major|--set x.y.z+n] [--dry-run]',
        );
        return;
      default:
        stderr.writeln('unknown argument: ${args[i]}');
        exit(2);
    }
  }

  final lines = file.readAsLinesSync();
  final index = lines.indexWhere((line) => line.startsWith('version:'));
  if (index < 0) {
    stderr.writeln('pubspec.yaml has no version: line');
    exit(1);
  }
  final match = _versionLine.firstMatch(lines[index]);
  if (match == null) {
    stderr.writeln(
      'version line is not x.y.z+n: ${lines[index].trim()}',
    );
    exit(1);
  }

  final major = int.parse(match[1]!);
  final minor = int.parse(match[2]!);
  final patch = int.parse(match[3]!);
  final build = int.parse(match[4]!);
  final previous = '$major.$minor.$patch+$build';

  late int nextMajor;
  late int nextMinor;
  late int nextPatch;
  late int nextBuild;
  if (explicit != null) {
    final target = _versionLine.firstMatch('version: $explicit');
    if (target == null) {
      stderr.writeln('--set needs x.y.z+n, got: $explicit');
      exit(2);
    }
    nextMajor = int.parse(target[1]!);
    nextMinor = int.parse(target[2]!);
    nextPatch = int.parse(target[3]!);
    nextBuild = int.parse(target[4]!);
    if (nextBuild < build) {
      stderr.writeln(
        'refusing to move versionCode backwards: $previous -> $explicit',
      );
      exit(1);
    }
  } else {
    nextMajor = major;
    nextMinor = minor;
    nextPatch = patch;
    nextBuild = build + 1;
    switch (bump) {
      case 'patch':
        nextPatch = patch + 1;
      case 'minor':
        nextMinor = minor + 1;
        nextPatch = 0;
      case 'major':
        nextMajor = major + 1;
        nextMinor = 0;
        nextPatch = 0;
    }
  }

  final next = '$nextMajor.$nextMinor.$nextPatch+$nextBuild';
  if (dryRun) {
    stdout.writeln('$previous -> $next (dry run)');
    return;
  }
  lines[index] = 'version: $next';
  file.writeAsStringSync('${lines.join('\n')}\n');
  _syncChangelog(next);
  stdout.writeln('$previous -> $next');
}

/// Keeps CHANGELOG.md's newest entry naming the version this build reports.
///
/// `test/mini_package_test.dart` refuses a pubspec version with no matching
/// heading, and a preview that moves only the build number would otherwise
/// leave the changelog pointing at the build before it. The entry's words
/// stay: a build-only bump is the same version's next upload, not a new set
/// of changes to describe.
void _syncChangelog(String next) {
  final file = File('CHANGELOG.md');
  if (!file.existsSync()) return;
  final text = file.readAsStringSync();
  final head = RegExp(
    r'^## \d+\.\d+\.\d+\+\d+ — ',
    multiLine: true,
  ).firstMatch(text);
  if (head == null) return;
  final updated = text.replaceRange(head.start, head.end, '## $next — ');
  if (updated != text) file.writeAsStringSync(updated);
}
