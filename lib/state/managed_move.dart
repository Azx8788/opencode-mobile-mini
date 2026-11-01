// The automatic OpenCode 1 -> 2 move on a phone-hosted server.
//
// Right after an app update the phone server is often still starting or busy,
// so a first attempt that fails is usually not a verdict. [ManagedMoveRunner]
// waits (bounded) for the phone to be ready, then retries a few times with a
// growing pause before the person ever sees a failure. Pure Dart with an
// injectable sleep so the schedule is testable with a fake clock.

import 'dart:async';

/// Why one attempt of the move did not finish. Words for each live in the
/// l10n files; technical text travels separately as [ManagedMoveAttempt.details].
enum ManagedMoveReason {
  /// The phone's Linux or server was not answering yet (starting or busy).
  phoneNotReady,

  /// OpenCode 2 already holds a separate history; moving would overwrite one.
  separateHistory,

  /// The move itself stopped part-way (space, a busy server, a failed step).
  moveStopped,

  /// The move ran but OpenCode 2 did not confirm the conversations arrived.
  notConfirmed;

  /// A later attempt can succeed without the person changing anything.
  bool get retryable => this != separateHistory;
}

class ManagedMoveAttempt {
  const ManagedMoveAttempt.success() : reason = null, details = null;
  const ManagedMoveAttempt.failure(
    ManagedMoveReason this.reason, {
    this.details,
  });

  final ManagedMoveReason? reason;

  /// Technical text for the Details fold only. Never shown as main copy.
  final String? details;

  bool get ok => reason == null;
}

class ManagedMoveRunner {
  const ManagedMoveRunner({
    this.backoff = const [
      Duration(seconds: 8),
      Duration(seconds: 20),
      Duration(seconds: 45),
    ],
    this.readyTimeout = const Duration(seconds: 60),
    this.readyPoll = const Duration(seconds: 2),
    this.sleep = _sleep,
  });

  /// The pause before each retry; its length is the retry count.
  final List<Duration> backoff;

  /// How long to wait for [ready] before an attempt goes ahead anyway (the
  /// attempt then reports the real failure).
  final Duration readyTimeout;
  final Duration readyPoll;
  final Future<void> Function(Duration) sleep;

  static Future<void> _sleep(Duration d) => Future<void>.delayed(d);

  /// Polls [ready] until it is true or [readyTimeout] passed. Returns whether
  /// it became ready.
  Future<bool> waitUntilReady(Future<bool> Function() ready) async {
    var waited = Duration.zero;
    while (true) {
      try {
        if (await ready()) return true;
      } catch (_) {
        // Not answering yet is the thing being waited out.
      }
      if (waited >= readyTimeout) return false;
      await sleep(readyPoll);
      waited += readyPoll;
    }
  }

  /// Runs [attempt] until it succeeds, fails for a reason a retry cannot fix,
  /// or the retries are used up. [onWaiting] is told which retry is next so
  /// the page can say it is still moving, calmly. [cancelled] stops early.
  Future<ManagedMoveAttempt> run({
    required Future<ManagedMoveAttempt> Function() attempt,
    Future<bool> Function()? ready,
    void Function(int retry, int of)? onWaiting,
    bool Function()? cancelled,
  }) async {
    var result = const ManagedMoveAttempt.failure(
      ManagedMoveReason.phoneNotReady,
    );
    for (var i = 0; i <= backoff.length; i++) {
      if (cancelled?.call() ?? false) return result;
      if (ready != null) await waitUntilReady(ready);
      if (cancelled?.call() ?? false) return result;
      try {
        result = await attempt();
      } catch (error) {
        result = ManagedMoveAttempt.failure(
          ManagedMoveReason.moveStopped,
          details: error.toString(),
        );
      }
      if (result.ok || !result.reason!.retryable) return result;
      if (i == backoff.length) break;
      onWaiting?.call(i + 1, backoff.length);
      await sleep(backoff[i]);
    }
    return result;
  }
}
