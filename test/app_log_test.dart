// The on-device log is the only record of a first run that happened on a
// phone someone else is holding, so its format and its masking are tested
// rather than assumed.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/diagnostics/app_log.dart';

void main() {
  late Directory dir;
  var now = DateTime(2026, 11, 1, 10, 0, 0);

  Future<void> open() =>
      AppLog.start(directory: dir, clock: () => now, runId: 'test-run');

  setUp(() async {
    now = DateTime(2026, 11, 1, 10, 0, 0);
    dir = await Directory.systemTemp.createTemp('applog-test');
    await AppLog.stop();
    await open();
  });

  tearDown(() async {
    await AppLog.stop();
    try {
      await dir.delete(recursive: true);
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
}
