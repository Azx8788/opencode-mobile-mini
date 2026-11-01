// What "Since you were away" lists: only what is still true, newest state per
// item. The engine appends a timeline row on every state change, so a plan
// that stopped and then finished leaves both rows behind; the digest keeps the
// later one and drops what the person has already looked at.
import '../../../../domain/team_project.dart';

/// The digest rows for [timeline]: newer than [readAt], one per item (the
/// planner, or one task), the newest state of each, newest item first.
List<TeamTimelineEvent> teamDigestEvents(
  List<TeamTimelineEvent> timeline,
  DateTime? readAt,
) {
  final newest = <String, (int, TeamTimelineEvent)>{};
  for (var i = 0; i < timeline.length; i++) {
    final e = timeline[i];
    final at = DateTime.tryParse(e.at);
    if (readAt != null && (at == null || !at.isAfter(readAt))) continue;
    final key = switch (e.kind) {
      'planner' || 'planningCheckpoint' => 'planner',
      'job' || 'taskCheckpoint' when e.taskId.isNotEmpty => 'task:${e.taskId}',
      _ => 'row:${e.id.isEmpty ? i : e.id}',
    };
    final held = newest[key];
    if (held != null) {
      final heldAt = DateTime.tryParse(held.$2.at);
      if (heldAt != null && at != null && at.isBefore(heldAt)) continue;
    }
    newest[key] = (i, e);
  }
  final rows = newest.values.toList()..sort((a, b) => b.$1.compareTo(a.$1));
  return [for (final r in rows) r.$2];
}
