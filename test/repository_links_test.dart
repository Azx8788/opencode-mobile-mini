import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/feedback/problem_report.dart';
import 'package:opencode_mobile/update/desktop_release_check.dart';

/// The repository this build belongs to. Every link a person can be sent to
/// has to name it: a report, a release page or an advisory that points at the
/// project this app derives from is read by people who do not ship it.
const owner = 'Azx8788';
const repo = 'opencode-plus';
const repository = 'https://github.com/$owner/$repo';

void main() {
  group('code links', () {
    test('a bug report opens an issue in this repository', () {
      final uri = Uri.parse(bugReportRepoUrl);
      expect(uri.host, 'github.com');
      expect(uri.pathSegments, <String>[owner, repo]);
    });

    test('the release check reads and links this repository', () {
      expect(
        desktopReleasesApiUrl,
        'https://api.github.com/repos/$owner/$repo/releases',
      );
      expect(desktopReleasesPageUrl, '$repository/releases');
    });
  });

  group('documents', () {
    String read(String path) => File(path).readAsStringSync();

    test('the security policy sends private reports here', () {
      final policy = read('SECURITY.md');
      expect(
        policy,
        contains('$repository/security/advisories/new'),
        reason: 'a report filed upstream never reaches this maintainer',
      );
      expect(
        policy,
        isNot(contains('Eslamasabry/opencode-mobile-next/security')),
      );
    });

    test('the security policy introduces this app, not its upstream', () {
      final firstLine = read('SECURITY.md').split('\n').first;
      expect(firstLine.trim(), '# Security policy');
      expect(
        read('SECURITY.md'),
        contains('OpenCode Plus is an independent community project'),
      );
    });

    test('the privacy policy points questions here', () {
      for (final path in <String>['PRIVACY.md', 'assets/l10n/PRIVACY.ar.md']) {
        expect(
          read(path),
          contains('$repository/issues'),
          reason: '$path still sends questions to another project',
        );
      }
    });

    test('no document promises a code-push channel', () {
      // `shorebird_code_push` is not a dependency of this build. A privacy
      // policy that describes a data flow the app does not have is wrong in
      // the direction that costs trust.
      for (final path in <String>['PRIVACY.md', 'SECURITY.md']) {
        expect(
          read(path).toLowerCase(),
          isNot(contains('uses shorebird')),
          reason: path,
        );
      }
    });
  });
}
