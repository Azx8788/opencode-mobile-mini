/// Which OpenCode session an AI Team agent is running in.
///
/// Gas City starts each agent as `opencode acp` in the agent's work folder
/// (`<city>/.gc/worktrees/<rig>/polecats/<name>`, the refinery's
/// `<city>/.gc/worktrees/<rig>/refinery`). On the phone that OpenCode shares
/// its session store with the phone's OpenCode server, so the agent's run is
/// an ordinary session there, in that folder.
///
/// Gas City keeps the OpenCode session id on the session bead
/// (`metadata.session_key`), but its `/sessions` API filters that key out
/// ("prevents leaking internal bead fields"), so the app matches by folder:
/// the newest top-level session in the agent's work folder (or below it)
/// that was active since the Gas City session started. A polecat's worktree
/// is reused from task to task, so an older session there is a previous
/// task and never counts as this one.
library;

import 'server_gateway.dart';

/// Slack for clocks and for OpenCode writing the session a moment before
/// Gas City records its own start.
const _startSlack = Duration(minutes: 2);

/// Picks the OpenCode session an AI Team agent runs in, or null when none
/// of [sessions] qualifies. See the library comment for the rule.
String? pickTeamAgentSession({
  required String? workDir,
  DateTime? startedAt,
  required Iterable<GlobalSessionResult> sessions,
}) {
  final root = _segments(workDir);
  if (root == null || root.isEmpty) return null;
  final notBefore = startedAt?.subtract(_startSlack).millisecondsSinceEpoch;
  Session? best;
  for (final result in sessions) {
    final session = result.session;
    if (session.parentID != null) continue;
    final folder = _segments(session.directory ?? result.projectDirectory);
    if (folder == null || !_within(folder, root)) continue;
    final at = _activeAt(session);
    if (notBefore != null && (at == null || at < notBefore)) continue;
    if (best == null || _newer(session, best)) best = session;
  }
  return best?.id;
}

/// Looks through the server's newest sessions, up to [pages] pages of
/// [pageSize], for the agent's session ([pickTeamAgentSession]). Null when
/// none matches or the server could not be asked.
Future<String?> findTeamAgentSession(
  ServerOperationsGateway repository, {
  required String? workDir,
  DateTime? startedAt,
  int pages = 3,
  int pageSize = 40,
}) async {
  final root = _segments(workDir);
  if (root == null || root.isEmpty) return null;
  final notBefore = startedAt?.subtract(_startSlack).millisecondsSinceEpoch;
  final seen = <GlobalSessionResult>[];
  String? cursor;
  try {
    for (var page = 0; page < pages; page++) {
      final result = await repository.listGlobalSessions(
        limit: pageSize,
        cursor: cursor,
      );
      seen.addAll(result.items);
      final found = pickTeamAgentSession(
        workDir: workDir,
        startedAt: startedAt,
        sessions: seen,
      );
      // The list is newest first: once a page reaches back before the
      // agent's session started, later pages hold only older ones.
      if (found != null && notBefore != null) {
        final oldest = result.items
            .map((r) => _activeAt(r.session))
            .whereType<int>()
            .fold<int?>(null, (a, b) => a == null || b < a ? b : a);
        if (oldest != null && oldest < notBefore) return found;
      }
      if (!result.hasMore || result.nextCursor == cursor) break;
      cursor = result.nextCursor;
    }
  } catch (_) {
    return null;
  }
  return pickTeamAgentSession(
    workDir: workDir,
    startedAt: startedAt,
    sessions: seen,
  );
}

/// When the session was last active: updated, else created (ms epoch).
int? _activeAt(Session session) =>
    session.time?.updated ?? session.time?.created;

/// Newest by activity, then by creation, then by id.
bool _newer(Session a, Session b) {
  final byActive = (_activeAt(a) ?? 0).compareTo(_activeAt(b) ?? 0);
  if (byActive != 0) return byActive > 0;
  final byCreated = (a.time?.created ?? 0).compareTo(b.time?.created ?? 0);
  if (byCreated != 0) return byCreated > 0;
  return a.id.compareTo(b.id) > 0;
}

/// True when [folder] is [root] or inside it.
bool _within(List<String> folder, List<String> root) {
  if (folder.length < root.length) return false;
  for (var i = 0; i < root.length; i++) {
    if (folder[i] != root[i]) return false;
  }
  return true;
}

/// Path segments with `.` dropped and `..` applied; null when no path.
List<String>? _segments(String? directory) {
  final value = directory?.trim().replaceAll('\\', '/');
  if (value == null || value.isEmpty) return null;
  final out = <String>[];
  for (final part in value.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(part);
  }
  return out;
}
