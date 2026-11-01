part of '../main.dart';

/// How long a tapped scheduled-run notification waits for the app's own
/// startup connection before it routes anyway (and, if that cannot reach
/// the conversation, opens the schedule's history).
const _scheduledOpenWaitLimit = Duration(seconds: 30);

extension _OcAppScheduleRoute on _OcAppState {
  /// A notification tap is consumed once, resolved against stored schedules
  /// and history, then held until it can open. A cold start used to race
  /// the root screen's own connect: both connected at once, the scheduled
  /// route saw "not connected" and gave up, leaving the Conversations list.
  Future<void> _consumeScheduledPromptOpen() async {
    if (_navigatorKey.currentState == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_consumeScheduledPromptOpen());
      });
      return;
    }
    try {
      final target = await const ScheduledPromptsPlatform().consumeOpen();
      if (target == null || !mounted) return;
      final profileId = target['profileId'] as String?;
      if (profileId == null) return;
      final profile = await _controller.store.loadForWidgetAction(profileId);
      if (profile == null || !mounted) return;
      final store = ScheduledPromptStore();
      final route = resolveScheduledOpen(
        payload: target,
        profileFingerprint: scheduledProfileFingerprint(profile),
        schedules: await store.load(profileId),
        history: await store.history(profileId),
      );
      if (route == null || !mounted) return;
      _pendingScheduledOpen = route;
      _pendingScheduledOpenSince = DateTime.now();
      _scheduledOpenTimer?.cancel();
      _scheduledOpenTimer = Timer(_scheduledOpenWaitLimit, () {
        if (mounted) _scheduleScheduledOpenRoute();
      });
      _scheduleScheduledOpenRoute();
    } catch (_) {
      // Deleted or changed private routing never falls back to another target.
    }
  }

  /// A conversation waits while a connection is on its way: the schedule's
  /// own server starting up, or another saved server's startup connect,
  /// which must settle before the scheduled route switches servers.
  bool _scheduledOpenWaiting(ScheduledOpenRoute route) {
    if (route is! ScheduledOpenConversation) return false;
    final since = _pendingScheduledOpenSince;
    if (since != null &&
        DateTime.now().difference(since) >= _scheduledOpenWaitLimit) {
      return false;
    }
    if (_controller.connectionLoading || _controller.locationLoading) {
      return true;
    }
    return _launchNewTaskWaiting;
  }

  /// Re-evaluated on every connection change (see `_controllerChanged`).
  void _scheduleScheduledOpenRoute() {
    final route = _pendingScheduledOpen;
    if (route == null || _scheduledOpenRouting) return;
    if (_scheduledOpenWaiting(route)) return;
    _pendingScheduledOpen = null;
    _pendingScheduledOpenSince = null;
    _scheduledOpenTimer?.cancel();
    _scheduledOpenTimer = null;
    _scheduledOpenRouting = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final navigator = _navigatorKey.currentState;
        if (navigator == null || !mounted) return;
        if (route is ScheduledOpenConversation &&
            await openScheduledRun(
              navigator.context,
              _controller,
              route.schedule,
              route.sessionId,
            )) {
          return;
        }
        if (!mounted) return;
        // A run without a conversation, or a conversation that cannot be
        // reached right now: the schedule's history says what happened.
        unawaited(
          openStoredScheduledPrompts(
            navigator.context,
            _controller,
            route.schedule,
          ),
        );
      } catch (_) {
        // Private routing never falls back to another target.
      } finally {
        _scheduledOpenRouting = false;
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }
}
