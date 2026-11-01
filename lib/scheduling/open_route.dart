import 'models.dart';

/// Where tapping a scheduled run's notification leads.
sealed class ScheduledOpenRoute {
  const ScheduledOpenRoute(this.schedule);
  final ScheduledPrompt schedule;
}

/// The conversation the run used ("started", "skipped · busy", or a failed
/// run that had already reached its conversation).
final class ScheduledOpenConversation extends ScheduledOpenRoute {
  const ScheduledOpenConversation(super.schedule, this.sessionId);
  final String sessionId;
}

/// The schedule's run history: the morning summary, or a run that never
/// reached a conversation.
final class ScheduledOpenHistory extends ScheduledOpenRoute {
  const ScheduledOpenHistory(super.schedule);
}

/// Resolves the notification payload (`profileId`, `scheduleId`,
/// `sessionId`) against what this phone has stored. Null when the schedule
/// is gone or its saved server changed: private routing never falls back
/// to another target.
ScheduledOpenRoute? resolveScheduledOpen({
  required Map<String, dynamic> payload,
  required String? profileFingerprint,
  required List<ScheduledPrompt> schedules,
  required List<ScheduledPromptRun> history,
}) {
  final scheduleId = payload['scheduleId'];
  final digest = scheduleId == '__digest' || scheduleId == '';
  final schedule = digest
      ? schedules.firstOrNull
      : schedules.where((s) => s.id == scheduleId).firstOrNull;
  if (schedule == null ||
      profileFingerprint == null ||
      payload['profileId'] != schedule.profileId ||
      profileFingerprint != schedule.profileFingerprint) {
    return null;
  }
  if (digest) return ScheduledOpenHistory(schedule);
  final sessionId = payload['sessionId'];
  final known =
      sessionId is String &&
      sessionId.isNotEmpty &&
      history.any(
        (run) => run.sessionId == sessionId && run.scheduleId == schedule.id,
      );
  return known
      ? ScheduledOpenConversation(schedule, sessionId)
      : ScheduledOpenHistory(schedule);
}
