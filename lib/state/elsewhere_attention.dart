import 'package:flutter/foundation.dart';

import '../domain/models.dart' show EventEnvelope;
import '../domain/attention_feed.dart';
import '../domain/session_stop.dart';
import '../domain/team_directories.dart';
import '../domain/work_row_status.dart';

/// What is going on in a project other than the selected one.
@immutable
class ProjectActivity {
  const ProjectActivity({
    required this.directory,
    required this.running,
    required this.waiting,
  });

  final String directory;

  /// Conversations with a run in progress.
  final Set<String> running;

  /// Conversations stopped on a person: a permission, question or form.
  final Set<String> waiting;

  bool get isEmpty => running.isEmpty && waiting.isEmpty;
}

/// Keeps track of the server's *other* projects from its server-wide event
/// channel.
///
/// The app shows one project and wipes its approvals, questions and running
/// state on every switch, so an agent that stopped on a permission in a
/// project you are not looking at waited unseen. The server-wide channel
/// already carries every project's events, stamped with their folder; this
/// reads the few that say "running", "needs you" and "done" and keeps a small
/// tally per project. It holds ids and folders only: answering still happens
/// in the conversation, in its own project.
class ElsewhereAttention extends ChangeNotifier {
  ElsewhereAttention({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final _runningIn = <String, Set<String>>{};
  // Typed identity includes folder/session: request ids alone may collide.
  final _waitingRequests = <String, AttentionObservation>{};
  final _failedRuns = <String, AttentionObservation>{};

  /// Feed the all-server projection without opening another event channel.
  /// These are observed requests/failures, never proof other folders are empty.
  List<AttentionObservation> observations({String? except}) =>
      List.unmodifiable(
        [
          ..._waitingRequests.values,
          ..._failedRuns.values,
        ].where((observation) => observation.directory != except),
      );

  /// A lost/replaced volatile stream cannot refresh its old observations.
  /// Keep them visible, but only a newly received event refreshes that row.
  void markStale() {
    var changed = false;
    for (final rows in [_waitingRequests, _failedRuns]) {
      for (final entry in rows.entries.toList()) {
        if (!entry.value.isFresh) continue;
        rows[entry.key] = entry.value.copyWith(isFresh: false);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// Every other project with something going on, busiest first.
  List<ProjectActivity> activity({String? except}) {
    final directories = {
      ..._runningIn.keys,
      for (final request in _waitingRequests.values) request.directory!,
    }..remove(except);
    final result = [
      for (final directory in directories)
        ProjectActivity(
          directory: directory,
          running: Set.unmodifiable(_runningIn[directory] ?? const <String>{}),
          waiting: Set.unmodifiable({
            for (final request in _waitingRequests.values)
              if (request.directory == directory) request.sessionID!,
          }),
        ),
    ].where((project) => !project.isEmpty).toList();
    result.sort((a, b) {
      final byWaiting = b.waiting.length.compareTo(a.waiting.length);
      return byWaiting != 0
          ? byWaiting
          : b.running.length.compareTo(a.running.length);
    });
    return result;
  }

  /// Conversations in other projects that are stopped on a person.
  int waitingCount({String? except}) => {
    for (final request in _waitingRequests.values)
      if (request.directory != except) request.sessionID!,
  }.length;

  ProjectActivity? forProject(String directory) =>
      activity().where((p) => p.directory == directory).firstOrNull;

  /// Feeds one event from the server-wide channel. Every project is tallied,
  /// the selected one included: readers leave it out with `except`, and the
  /// tally is already right for it the moment you switch away.
  void handle(EventEnvelope event) {
    final directory = event.directory;
    if (directory == null || directory.isEmpty) return;
    // The AI Team's agents run and ask in their own folders; their work is
    // shown on the AI Team screen, not as the person's other projects.
    if (isAiTeamDirectory(directory)) return;
    final props = event.properties;
    final sessionID = props['sessionID']?.toString();
    var changed = false;
    switch (event.type) {
      case 'permission.asked' ||
          'permission.v2.asked' ||
          'permission.updated' ||
          'question.asked' ||
          'question.updated' ||
          'question.v2.asked':
        final id = (props['id'] ?? props['requestID'])?.toString();
        changed = _observe(
          id: id,
          sessionID: sessionID,
          kind: event.type.startsWith('permission.')
              ? AttentionKind.permission
              : AttentionKind.question,
          directory: directory,
          workspace: event.workspace,
        );
      case 'form.v2.created':
        final form = props['form'];
        if (form is! Map) break;
        changed = _observe(
          id: form['id']?.toString(),
          sessionID: form['sessionID']?.toString(),
          kind: AttentionKind.form,
          directory: directory,
          workspace: event.workspace,
        );
      case 'permission.replied' ||
          'permission.v2.replied' ||
          'question.replied' ||
          'question.rejected' ||
          'question.v2.replied' ||
          'question.v2.rejected' ||
          'form.v2.replied' ||
          'form.v2.cancelled':
        final id = (props['requestID'] ?? props['permissionID'] ?? props['id'])
            ?.toString();
        final kind = event.type.startsWith('permission.')
            ? AttentionKind.permission
            : event.type.startsWith('question.')
            ? AttentionKind.question
            : AttentionKind.form;
        final before = _waitingRequests.length;
        _waitingRequests.removeWhere(
          (_, request) =>
              request.requestID == id &&
              request.kind == kind &&
              request.directory == directory &&
              request.workspace == event.workspace &&
              (sessionID == null || request.sessionID == sessionID),
        );
        changed = before != _waitingRequests.length;
      case 'session.status':
        if (sessionID == null || sessionID.isEmpty) break;
        final raw = props['status'];
        final status = raw is Map ? raw['type']?.toString() : raw?.toString();
        if (status == 'idle') {
          changed = _settle(directory, sessionID);
        } else if (status == 'busy' || status == 'retry') {
          final cleared = _clearFailure(directory, sessionID);
          changed =
              (_runningIn.putIfAbsent(directory, () => {})).add(sessionID) ||
              cleared;
        }
      case 'session.idle':
        if (sessionID != null) changed = _settle(directory, sessionID);
      case 'session.error':
        if (sessionID == null || sessionID.isEmpty) break;
        // A Stop ends the run; it is not a failure to look at (F3).
        if (sessionErrorIsStop(props['error'])) {
          changed = _settle(directory, sessionID);
          break;
        }
        _settle(directory, sessionID);
        final failure = AttentionObservation(
          id: 'session-failure:$sessionID',
          kind: AttentionKind.failedRun,
          facts: const WorkRowFacts(phase: WorkRowPhase.failed),
          observedAt: _now(),
          sessionID: sessionID,
          directory: directory,
          workspace: event.workspace,
        );
        _failedRuns[failure.identity] = failure;
        changed = true;
      case 'message.updated':
        final info = props['info'];
        if (info is! Map || info['role'] != 'user') break;
        final id = info['sessionID']?.toString();
        if (id != null && id.isNotEmpty) changed = _clearFailure(directory, id);
      case 'session.deleted':
        final id = (props['info'] is Map ? props['info']['id'] : sessionID)
            ?.toString();
        if (id != null) {
          final cleared = _clearFailure(directory, id);
          changed = _settle(directory, id) || cleared;
        }
    }
    if (changed) notifyListeners();
  }

  bool _observe({
    required String? id,
    required String? sessionID,
    required AttentionKind kind,
    required String directory,
    required String? workspace,
  }) {
    if (id == null || id.isEmpty || sessionID == null || sessionID.isEmpty) {
      return false;
    }
    final observation = AttentionObservation(
      id: id,
      kind: kind,
      facts: const WorkRowFacts(phase: WorkRowPhase.needsYou),
      observedAt: _now(),
      sessionID: sessionID,
      requestID: id,
      directory: directory,
      workspace: workspace,
    );
    _waitingRequests[observation.identity] = observation;
    return true;
  }

  bool _settle(String directory, String sessionID) {
    var changed = _runningIn[directory]?.remove(sessionID) ?? false;
    if (_runningIn[directory]?.isEmpty ?? false) _runningIn.remove(directory);
    // A run that ended is no longer waiting on anything.
    final before = _waitingRequests.length;
    _waitingRequests.removeWhere(
      (_, request) =>
          request.sessionID == sessionID && request.directory == directory,
    );
    changed = changed || before != _waitingRequests.length;
    return changed;
  }

  bool _clearFailure(String directory, String sessionID) {
    final before = _failedRuns.length;
    _failedRuns.removeWhere(
      (_, failure) =>
          failure.directory == directory && failure.sessionID == sessionID,
    );
    return before != _failedRuns.length;
  }

  /// A new server, or a lost connection: what was known may be stale.
  void clear() {
    if (_runningIn.isEmpty && _waitingRequests.isEmpty && _failedRuns.isEmpty) {
      return;
    }
    _runningIn.clear();
    _waitingRequests.clear();
    _failedRuns.clear();
    notifyListeners();
  }
}
