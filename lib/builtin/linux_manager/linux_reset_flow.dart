/// Reset Linux as one act that either finishes or leaves Linux as it was.
///
/// Build 2400 (N1-5) erased Ubuntu in four seconds and then stopped on
/// "That did not work: That didn't work.": no reinstall, the setup screen
/// said "OpenCode is ready" (the finished job of an earlier Repair was still
/// held in memory) while the card said it was not answering. Now:
///
/// 1. A marker is saved before anything is erased, so a reset the app did
///    not finish (killed, phone restarted) is finished on the next start
///    ([resumeIfPending]).
/// 2. Linux is erased (projects stay: `BuiltinLinux.remove`'s default). When
///    the phone refuses before erasing anything (a terminal or task still
///    running), nothing changed: the marker goes and the caller says so.
///    When erasing stopped part way, Linux is gone either way and setup
///    replaces what is left.
/// 3. The setup engine forgets the old job ([SetupEngine.restore] reads no
///    job now), and phone setup starts at once with the normal selection;
///    its own job record, progress screen and Continue take over.
///
/// Cleaning up the old server's saved connections is the caller's
/// ([LinuxResetFlow.afterErase]); a failure there never stops the reinstall
/// and is reported as what it is.
library;

import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../builtin_linux.dart';
import '../reply_watch.dart' show replySpeedPreferenceKey;
import '../setup/setup_contract.dart';

/// How a reset ended, for the screen that started it.
enum LinuxResetResult {
  /// Erased, and setup is running (or finished) on a fresh Linux.
  reinstalling,

  /// The phone refused before erasing anything; Linux is as it was.
  notErased,
}

class LinuxResetOutcome {
  const LinuxResetOutcome(
    this.result, {
    this.problems = const [],
    this.details,
  });

  final LinuxResetResult result;

  /// What the cleanup after erasing could not do, in words.
  final List<String> problems;

  /// Technical text for a Details fold: the phone's error code, never
  /// shown as the message.
  final String? details;
}

class LinuxResetFlow {
  LinuxResetFlow({
    required this.linux,
    required this.engine,
    required this.prefs,
    required this.selection,
    this.beforeErase,
    this.afterErase,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// One per app (Linux is one per app), so not profile-scoped.
  static const markerKey = 'oc.linuxReset.pending';
  static const _erasing = 'erasing';
  static const _installing = 'installing';

  final BuiltinLinux linux;
  final SetupEngine engine;
  final SharedPreferences prefs;

  /// What the fresh setup installs (the first-setup selection).
  final Set<String> selection;

  /// Before erasing: leave the in-app server.
  final Future<void> Function()? beforeErase;

  /// After erasing: forget what belonged to the old Linux. Returns what
  /// could not be cleaned, in words; never throws for the flow to stop.
  final Future<List<String>> Function()? afterErase;

  final DateTime Function() _clock;

  static bool pending(SharedPreferences prefs) =>
      prefs.getString(markerKey) != null;

  Future<void> _mark(String phase) => prefs.setString(
    markerKey,
    '$phase ${_clock().toUtc().toIso8601String()}',
  );

  static String? _phase(SharedPreferences prefs) =>
      prefs.getString(markerKey)?.split(' ').first;

  /// Erases Linux and starts setup on a fresh one.
  Future<LinuxResetOutcome> run() async {
    await _mark(_erasing);
    await beforeErase?.call();
    try {
      await linux.uninstall();
    } on Object catch (error) {
      if (await _stillInstalled()) {
        // Refused before erasing (the phone checks first): nothing changed.
        await prefs.remove(markerKey);
        return LinuxResetOutcome(
          LinuxResetResult.notErased,
          details: error is BuiltinLinuxException
              ? (error.code ?? error.message)
              : error.runtimeType.toString(),
        );
      }
      // Erasing stopped part way. Linux is gone either way; setup replaces
      // a partial Ubuntu (it keeps projects first), so the reset goes on.
    }
    return _reinstall(afterErase: afterErase);
  }

  Future<LinuxResetOutcome> _reinstall({
    Future<List<String>> Function()? afterErase,
  }) async {
    await _mark(_installing);
    // The last reply was timed on the Linux that is gone; "Reply speed"
    // must not show it for the fresh one.
    await prefs.remove(replySpeedPreferenceKey);
    // The job on disk went with Linux; reading again drops the old
    // finished job from memory, so no screen says "ready" for a Linux that
    // is not there.
    try {
      await engine.restore();
    } on Object {
      // Unreadable now: the run below reads again.
    }
    var problems = const <String>[];
    if (afterErase != null) {
      try {
        problems = await afterErase();
      } on Object {
        problems = const [];
      }
    }
    await engine.run(selection);
    // From here the setup job's own record carries the reset: Continue,
    // the progress screen and the notification resume it. A start that
    // failed keeps the marker, so the next app start tries again.
    final state = engine.progress.value.state;
    if (state == SetupState.running || state == SetupState.done) {
      await prefs.remove(markerKey);
    }
    return LinuxResetOutcome(LinuxResetResult.reinstalling, problems: problems);
  }

  Future<bool> _stillInstalled() async {
    try {
      final status = await linux.status();
      return status.installed;
    } on Object {
      // Unknown: treat as erased, so setup runs and settles it.
      return false;
    }
  }

  /// On app start: finishes a reset that was confirmed but not finished.
  /// Returns true when it did something.
  Future<bool> resumeIfPending() async {
    final phase = _phase(prefs);
    if (phase == null) return false;
    if (phase == _installing) {
      // Erased already. A Linux that is installed again means setup got
      // that far; its own job record carries the rest.
      if (await _stillInstalled()) {
        await prefs.remove(markerKey);
        return false;
      }
      await _reinstall();
      return true;
    }
    // Killed while erasing (or before): the person confirmed the reset, so
    // it is finished, not undone.
    await run();
    return true;
  }
}
