// The on-device log is the only record of a first run that happened on a
// phone someone else is holding, so its format and its masking are tested
// rather than assumed.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/diagnostics/app_log.dart';

void main() {
  late Directory dir;
  late Directory publicDir;
  var now = DateTime(2026, 11, 1, 10, 0, 0);

  Future<void> open() => AppLog.start(
    directory: dir,
    publicDirectory: publicDir,
    clock: () => now,
    runId: 'test-run',
  );

  setUp(() async {
    now = DateTime(2026, 11, 1, 10, 0, 0);
    dir = await Directory.systemTemp.createTemp('applog-test');
    publicDir = await Directory.systemTemp.createTemp('applog-public');
    await AppLog.stop();
    await open();
  });

  tearDown(() async {
    await AppLog.stop();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
    try {
      await publicDir.delete(recursive: true);
    } catch (_) {}
  });

  List<Map<String, Object?>> readLines(String text) => [
    for (final line in text.trim().split('\n'))
      if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, Object?>,
  ];

  test('writes one JSON object per line with the step it came from', () async {
    AppLog.info('setup', 'job running', {'job': 'abc', 'current': 'opencode'});
    AppLog.error('setup', 'could not start', message: 'start step failed');
    await AppLog.flush();

    final entries = readLines(await AppLog.currentFile!.readAsString());
    expect(entries, hasLength(2));

    expect(entries.first['lvl'], 'info');
    expect(entries.first['src'], 'setup');
    expect(entries.first['run'], 'test-run');
    expect(entries.first['msg'], 'job running');
    expect(entries.first['job'], 'abc');
    expect(entries.first['current'], 'opencode');

    expect(entries.last['lvl'], 'error');
    expect(entries.last['error'], 'could not start');
    expect(entries.last['msg'], 'start step failed');
  });

  test('a credential field never reaches the disk', () async {
    AppLog.info('server', 'start', {
      'password': 'hunter2hunter2',
      'token': 'ghp_abcdefghijklmnopqrstuvwxyz012345',
      'port': 4096,
    });
    await AppLog.flush();

    final text = await AppLog.currentFile!.readAsString();
    expect(text, isNot(contains('hunter2hunter2')));
    expect(text, isNot(contains('ghp_abcdefghijklmnopqrstuvwxyz012345')));

    // Masking must not break the one-record-per-line format.
    final entries = readLines(text);
    expect(entries, hasLength(1));
    expect(entries.single['port'], '4096');
  });

  test('the file is named for the day and rolls over at midnight', () async {
    AppLog.info('app', 'before midnight');
    await AppLog.flush();
    expect(AppLog.currentFile!.path, endsWith('app-2026-11-01.log'));

    now = DateTime(2026, 11, 2, 0, 0, 1);
    AppLog.info('app', 'after midnight');
    await AppLog.flush();
    expect(AppLog.currentFile!.path, endsWith('app-2026-11-02.log'));

    final day1 = File('${dir.path}/app-2026-11-01.log');
    final day2 = File('${dir.path}/app-2026-11-02.log');
    expect(
      readLines(await day1.readAsString()).single['msg'],
      'before midnight',
    );
    expect(
      readLines(await day2.readAsString()).single['msg'],
      'after midnight',
    );
  });

  test('lines logged while the folder opens are kept, not dropped', () async {
    await AppLog.stop();
    final opening = AppLog.start(
      directory: dir,
      clock: () => now,
      runId: 'early-run',
    );
    // Synchronous part of start() has run; the folder is not open yet.
    AppLog.info('app', 'logged during startup');
    await opening;
    await AppLog.flush();

    final text = await AppLog.currentFile!.readAsString();
    expect(text, contains('logged during startup'));
    expect(readLines(text).single['run'], 'early-run');
  });

  test('the public mirror gets the same lines as the private log', () async {
    await AppLog.publicProbeDone;
    expect(AppLog.publicEnabled, isTrue);
    expect(AppLog.publicDirectoryPath, publicDir.path);

    AppLog.info('app', 'mirrored line', {'step': 'mirror'});
    await AppLog.flush();

    final publicFile = File('${publicDir.path}/app-2026-11-01.log');
    expect(await publicFile.exists(), isTrue);
    expect(await publicFile.readAsString(), contains('mirrored line'));
    expect(
      await AppLog.currentFile!.readAsString(),
      contains('mirrored line'),
    );
  });

  test('an unwritable public folder leaves the private log alone', () async {
    await AppLog.stop();
    // A file where the folder would go: creating the folder then fails
    // whatever user the test runs as, which "no permission on /storage"
    // does not (root can create it, and then the test proves nothing).
    final blocker = await Directory.systemTemp.createTemp('applog-blocked');
    final inTheWay = File('${blocker.path}/not-a-folder');
    await inTheWay.writeAsString('x');
    await AppLog.start(
      directory: dir,
      publicDirectory: Directory('${inTheWay.path}/logs'),
      clock: () => now,
      runId: 'private-run',
    );
    await AppLog.publicProbeDone;
    expect(AppLog.publicEnabled, isFalse);

    AppLog.info('app', 'private only');
    await AppLog.flush();
    expect(
      await AppLog.currentFile!.readAsString(),
      contains('private only'),
    );
    await blocker.delete(recursive: true);
  });

  test('a fresh public file replays what the private log already holds', () async {
    await AppLog.publicProbeDone;
    AppLog.info('app', 'before replay');
    await AppLog.flush();

    // Drop the public file to force the replay path on the next probe.
    final publicFile = File('${publicDir.path}/app-2026-11-01.log');
    if (await publicFile.exists()) await publicFile.delete();
    await AppLog.refreshPublicLog();
    await AppLog.flush();

    expect(await publicFile.readAsString(), contains('before replay'));
  });

  test('the public file rolls over at midnight like the private one', () async {
    await AppLog.publicProbeDone;
    AppLog.info('app', 'public before midnight');
    await AppLog.flush();

    now = DateTime(2026, 11, 2, 0, 0, 1);
    AppLog.info('app', 'public after midnight');
    await AppLog.flush();

    final day1 = File('${publicDir.path}/app-2026-11-01.log');
    final day2 = File('${publicDir.path}/app-2026-11-02.log');
    expect(await day1.readAsString(), contains('public before midnight'));
    expect(await day2.readAsString(), contains('public after midnight'));
  });
}
