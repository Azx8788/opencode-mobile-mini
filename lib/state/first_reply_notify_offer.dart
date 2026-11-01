import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/platform_capabilities.dart';
import 'connection.dart';
import 'consent_owners.dart';
import 'first_run.dart';
import 'in_flow_consent.dart';

/// What a yes to "Notify me when the agent needs me" turns on: notifications
/// for requests, and the background connection that delivers them (which
/// raises Android's notification permission). False when the background
/// connection could not start; `backgroundLive.lastError` says why.
Future<bool> turnOnNeedsYouNotifications(
  ConnectionController controller,
) async {
  if (!controller.notificationPreferences.requests) {
    await controller.setNotifyRequests(true);
  }
  return controller.setKeepLiveInBackground(true);
}

/// Why "Notify me" did not turn notifications on.
enum FirstReplyNotifyFailure {
  /// The answer could not be kept, so nothing was turned on.
  saveFailed,

  /// The background connection did not start (for example Android's
  /// notification prompt was refused); see [FirstReplyNotifyOffer.failureError].
  notEnabled,
}

/// "Notify you when the agent needs you?" — the one time the app asks for
/// notifications (UX plan 5.6 step 6), with the preset "Tell me when the
/// agent needs me" (P6.7, consent once, in flow).
///
/// Asked once the first reply of a new person's first run has completed:
/// the moment they have watched the agent work and can see why they would
/// rather leave than wait. The conversation shows it as a line in its
/// status slot (F16: never where it would move the reply). The question is
/// claimed for the current server ([ConsentOwners.inFlow]) before it shows,
/// and the answer is saved there first, so What runs by itself shows it on
/// that server's row. "Notify me" then turns on notifications for requests
/// and the background connection through the same calls as Settings →
/// Notifications, which is what raises Android's notification permission.
/// "Not now" and "Notify me" are both final; Settings stays the home for
/// changing it.
class FirstReplyNotifyOffer extends ChangeNotifier {
  FirstReplyNotifyOffer(this.controller);

  final ConnectionController controller;

  /// Whether this question is still owed to the person on this device. The
  /// one-time tips stay quiet until it has been answered, so a first run is
  /// never asked two things at once.
  static bool pendingFor(ConnectionController controller) =>
      !controller.isIsolated &&
      platformCapabilities.supportsNotifications &&
      platformCapabilities.supportsBackgroundService &&
      FirstRun(controller.store.prefs).notifyAskPending;

  /// This server's consents once the question was claimed for it; null
  /// until then, and with a saved server the question shows only after the
  /// claim was saved.
  InFlowConsent? _claimed;
  bool _claiming = false;
  bool _settling = false;

  /// Set on either answer so the question leaves at once, before the write
  /// to preferences has finished.
  bool _answered = false;

  /// True while "Notify me" is being carried out.
  bool get working => _working;
  bool _working = false;

  /// Why turning notifications on failed, said where the question was. The
  /// question is answered either way; [dismissFailure] clears it.
  FirstReplyNotifyFailure? get failure => _failure;
  FirstReplyNotifyFailure? _failure;

  /// The background connection's own reason, for [FirstReplyNotifyFailure.notEnabled].
  String? get failureError => _failureError;
  String? _failureError;

  bool _disposed = false;

  FirstRun get _firstRun => FirstRun(controller.store.prefs);

  /// Whether the question shows now, given whether this conversation holds
  /// a finished reply and is idle. Pure for the caller: the claim, and the
  /// quiet answer when notifications are already on, happen after it.
  bool showFor({required bool replyCompleted}) {
    if (_answered || !replyCompleted || !pendingFor(controller)) return false;
    // Already on (turned on in Settings between the reply and now): the
    // question has been answered elsewhere, so it is not asked.
    if (controller.keepLiveInBackground) {
      if (!_settling) {
        _settling = true;
        scheduleMicrotask(decline);
      }
      return false;
    }
    // Without a saved server there is nothing to keep the answer on, and
    // the question stays the device's one-time question.
    if (_claimed == null && controller.profile != null) {
      if (!_claiming) scheduleMicrotask(_claim);
      return false;
    }
    return true;
  }

  /// Claims the question for the current server before it shows. A server
  /// that was already asked (or answered in Settings) is not asked again,
  /// and the first-run question is then settled; storage that cannot be
  /// read shows nothing, since no answer could be kept.
  Future<void> _claim() async {
    final profileId = controller.profile?.id;
    if (_claiming || profileId == null) return;
    _claiming = true;
    try {
      final consent = await ConsentOwners.inFlow(
        controller.store.prefs,
        profileId,
      );
      final owed = await consent.requestNeedsYouPreset();
      if (_disposed) return;
      if (owed) {
        _claimed = consent;
        _notify();
      } else {
        _answered = true;
        _notify();
        await _firstRun.answerNotifyAsk();
      }
    } catch (_) {
      _answered = true;
      _notify();
    }
  }

  /// "Notify me".
  Future<void> accept() async {
    if (_working) return;
    _working = true;
    _notify();
    try {
      // Saved first: nothing is turned on without a kept yes.
      await _claimed?.answer(
        InFlowConsentKind.needsYouNotifications,
        allow: true,
      );
    } catch (_) {
      _working = false;
      _answered = true;
      _failure = FirstReplyNotifyFailure.saveFailed;
      _notify();
      return;
    }
    final enabled = await turnOnNeedsYouNotifications(controller);
    // Asked once: a refusal at Android's own prompt is an answer too.
    await _firstRun.answerNotifyAsk();
    _working = false;
    _answered = true;
    if (!enabled) {
      _failure = FirstReplyNotifyFailure.notEnabled;
      _failureError = controller.backgroundLive.lastError;
    }
    _notify();
  }

  /// "Not now": remembered, and nothing is turned on.
  Future<void> decline() async {
    _answered = true;
    _notify();
    try {
      await _claimed?.answer(
        InFlowConsentKind.needsYouNotifications,
        allow: false,
      );
    } catch (_) {
      // Unsaved, it stays "Not answered" on What runs by itself.
    }
    await _firstRun.answerNotifyAsk();
  }

  void dismissFailure() {
    _failure = null;
    _failureError = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
