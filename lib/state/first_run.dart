import 'package:shared_preferences/shared_preferences.dart';

/// What this device remembers about first run (UX plan 5.6): whether the
/// person is still on their way to a first conversation, and whether the one
/// notification question has been answered.
///
/// A device is "new" only if the welcome (no saved servers) was the first
/// thing it showed. A build upgraded over saved servers never sees the
/// welcome, so an existing person is never walked through first run.
class FirstRun {
  const FirstRun(this.prefs);

  final SharedPreferences prefs;

  static const stateKey = 'oc.firstRun.state';
  static const notifyAskKey = 'oc.firstRun.notifyAsk';

  static const _armed = 'armed';
  static const _done = 'done';
  static const _pending = 'pending';
  static const _answered = 'answered';

  /// True from the welcome until the first conversation opened: the next
  /// successful connect should end inside a new conversation, not on Work.
  bool get landingPending => prefs.getString(stateKey) == _armed;

  /// Called where the saved servers are listed. With none, and nothing
  /// recorded yet, this is a new device. With some, the person is returning
  /// and stays that way even if they later remove every server.
  Future<void> observeServers({required bool hasServers}) async {
    if (prefs.getString(stateKey) != null) return;
    await prefs.setString(stateKey, hasServers ? _done : _armed);
  }

  /// The shell opened for someone who never saw the welcome.
  Future<void> markReturning() async {
    if (prefs.getString(stateKey) == null) {
      await prefs.setString(stateKey, _done);
    }
  }

  /// The first conversation opened. First run is over, and the notification
  /// question becomes due after its first reply.
  Future<void> markLanded() async {
    await prefs.setString(stateKey, _done);
    if (prefs.getString(notifyAskKey) == null) {
      await prefs.setString(notifyAskKey, _pending);
    }
  }

  /// True until the person answers "Get told when it's done?" either way.
  /// Never true for someone who did not come through first run.
  bool get notifyAskPending => prefs.getString(notifyAskKey) == _pending;

  /// Both answers are final: Settings → Notifications is the home afterwards.
  Future<void> answerNotifyAsk() => prefs.setString(notifyAskKey, _answered);
}
