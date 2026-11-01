import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

import '../../domain/models.dart';
import 'session_title.dart';

/// One session in the family the chat belongs to: the parent that delegated,
/// the current session, and every sibling or child subagent.
class RunningAgentEntry {
  const RunningAgentEntry({
    required this.session,
    required this.busy,
    required this.current,
    required this.relation,
  });

  final Session session;
  final bool busy;
  final bool current;
  final RunningAgentRelation relation;

  String get label => labelFor(lookupAppLocalizations(const Locale('en')));

  String labelFor(AppLocalizations strings) =>
      relation == RunningAgentRelation.parent
      ? strings.chatUiParentSession(
          presentedSessionTitle(session, fallback: strings.chatUiMainSession),
        )
      : presentedSessionTitle(
          session,
          fallback: session.agent?.isNotEmpty == true
              ? session.agent!
              : strings.chatUiSubagent,
        );
}

enum RunningAgentRelation { parent, current, sibling, child }

/// Builds the strip entries for [sessionID] from the session map and the set
/// of busy sessions: the parent (when delegated), siblings sharing that
/// parent, and children this session delegated to. Returns an empty list
/// unless at least one *other* member of the family is running — the strip
/// exists to switch between concurrently working agents, not to list history.
List<RunningAgentEntry> runningAgentEntries({
  required String sessionID,
  required Map<String, Session> sessions,
  required Set<String> busy,
  bool includeIdle = false,
}) {
  final current = sessions[sessionID];
  if (current == null) return const [];
  final parentID = current.parentID;
  final parent = parentID == null ? null : sessions[parentID];
  int created(Session s) => s.time?.created ?? 0;
  final siblings =
      sessions.values
          .where((s) => parentID != null && s.parentID == parentID)
          .toList()
        ..sort((a, b) => created(a).compareTo(created(b)));
  final children =
      sessions.values.where((s) => s.parentID == sessionID).toList()
        ..sort((a, b) => created(a).compareTo(created(b)));
  final entries = <RunningAgentEntry>[
    if (parent != null)
      RunningAgentEntry(
        session: parent,
        busy: busy.contains(parent.id),
        current: false,
        relation: RunningAgentRelation.parent,
      ),
    if (parent == null && !children.any((s) => s.id == sessionID))
      RunningAgentEntry(
        session: current,
        busy: busy.contains(sessionID),
        current: true,
        relation: RunningAgentRelation.current,
      ),
    for (final s in siblings)
      RunningAgentEntry(
        session: s,
        busy: busy.contains(s.id),
        current: s.id == sessionID,
        relation: s.id == sessionID
            ? RunningAgentRelation.current
            : RunningAgentRelation.sibling,
      ),
    for (final s in children)
      RunningAgentEntry(
        session: s,
        busy: busy.contains(s.id),
        current: false,
        relation: RunningAgentRelation.child,
      ),
  ];
  final othersRunning = entries.any((e) => !e.current && e.busy);
  if (!includeIdle && !othersRunning) return const [];
  // Running agents first so the switch target is one tap away, then the
  // current session for orientation, then whatever has finished.
  final running = entries.where((e) => e.busy && !e.current).toList();
  final self = entries.where((e) => e.current).toList();
  final idle = entries.where((e) => !e.busy && !e.current).toList();
  return [...running, ...self, ...idle];
}
