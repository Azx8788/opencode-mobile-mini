import 'dart:convert';

import '../domain/attention_feed.dart';
import '../domain/profile_monitor.dart';
import '../domain/work_row_status.dart';
import '../ui/kit/kit_redact.dart';

export '../domain/attention_feed.dart';

/// Supply only the current saved profiles. A monitor cache may outlive removal;
/// it is never itself an authority for which servers belong in the feed.
class AttentionServer {
  const AttentionServer({
    required this.profileID,
    required this.name,
    required this.snapshot,
  });

  final String profileID, name;
  final ProfileAttentionSnapshot snapshot;
}

/// In-memory projection of the existing monitor and active transport.
/// Owns no polling, transport, persistence, notification or automatic action.
class AttentionFeed {
  AttentionFeed._(this.items, this.servers);

  /// The default covers the existing monitor's five-minute background cadence.
  /// Callers can tighten it for foreground-only surfaces. Rebuild on the
  /// monitor's notifications/shared clock; this projection starts no timer.
  factory AttentionFeed.fromServers(
    Iterable<AttentionServer> savedServers, {
    required DateTime now,
    Duration maxAge = const Duration(minutes: 6),
  }) {
    final items = <AttentionFeedItem>[];
    final checks = <AttentionServerCheck>[];
    final seenProfiles = <String>{};
    for (final server in savedServers) {
      if (!seenProfiles.add(server.profileID)) continue;
      final snapshot = server.snapshot;
      final name = KitRedact.text(server.name);
      if (snapshot.profileID != server.profileID) {
        checks.add(
          AttentionServerCheck(
            profileID: server.profileID,
            serverName: name,
            state: AttentionCheckState.unavailable,
            isFresh: false,
            coverageComplete: false,
          ),
        );
        continue;
      }
      final current =
          snapshot.isCurrent && _recent(snapshot.checkedAt, now, maxAge);
      final coverage = snapshot.complete && snapshot.attentionComplete;
      checks.add(
        AttentionServerCheck(
          profileID: server.profileID,
          serverName: name,
          state: _checkState(snapshot, current, coverage),
          checkedAt: snapshot.checkedAt,
          nextCheckAt: snapshot.nextCheckAt,
          isFresh: current,
          coverageComplete: coverage,
        ),
      );

      final observations = <String, AttentionObservation>{};
      void add(AttentionObservation observation) {
        final previous = observations[observation.identity];
        if (previous == null ||
            observation.observedAt.isAfter(previous.observedAt) ||
            (observation.observedAt == previous.observedAt &&
                (!previous.isFresh || observation.isFresh))) {
          observations[observation.identity] = observation;
        }
      }

      // Pending requests are complete independently of the bounded reads for
      // failed runs/team tasks. A local busy check-in is not a request.
      final checkedAt = snapshot.checkedAt;
      if (checkedAt != null) {
        for (final request in snapshot.requests) {
          final kind = switch (request.kind) {
            MonitoredRequestKind.permission => AttentionKind.permission,
            MonitoredRequestKind.question => AttentionKind.question,
            MonitoredRequestKind.form => AttentionKind.form,
            MonitoredRequestKind.checkIn => null,
          };
          if (kind == null) continue;
          add(
            AttentionObservation(
              id: request.id,
              kind: kind,
              facts: const WorkRowFacts(phase: WorkRowPhase.needsYou),
              observedAt: checkedAt,
              sessionID: request.sessionID,
              requestID: request.id,
              title: request.title,
              directory: request.directory ?? snapshot.directory,
              workspace: request.workspace ?? snapshot.workspace,
            ),
          );
        }
      }
      for (final observation in snapshot.attention) {
        add(
          AttentionObservation(
            id: observation.id,
            kind: observation.kind,
            facts: observation.facts,
            observedAt: observation.observedAt,
            isFresh: observation.isFresh,
            sessionID: observation.sessionID,
            requestID: observation.requestID,
            taskID: observation.taskID,
            runID: observation.runID,
            title: observation.title,
            directory: observation.directory ?? snapshot.directory,
            workspace: observation.workspace ?? snapshot.workspace,
          ),
        );
      }
      for (final observation in observations.values) {
        items.add(
          AttentionFeedItem(
            identity: jsonEncode([server.profileID, observation.identity]),
            profileID: server.profileID,
            serverName: name,
            kind: observation.kind,
            title: observation.title == null
                ? null
                : KitRedact.text(observation.title!),
            target: AttentionTarget(
              profileID: server.profileID,
              kind: observation.kind,
              sessionID: observation.sessionID,
              requestID:
                  observation.requestID ??
                  (observation.kind == AttentionKind.failedRun
                      ? null
                      : observation.id),
              taskID: observation.taskID,
              runID: observation.runID,
              directory: observation.directory,
              workspace: observation.workspace,
            ),
            status: WorkRowStatus(
              facts: observation.facts,
              observedAt: observation.observedAt,
              isFresh:
                  current &&
                  observation.isFresh &&
                  _recent(observation.observedAt, now, maxAge),
            ),
          ),
        );
      }
    }
    // Requests and gates require a decision. Failed runs follow them. Within
    // each urgency, fresh evidence comes first, then the oldest observation;
    // stable identities make equal timestamps deterministic across refreshes.
    items.sort((a, b) {
      var order = _urgency(a).compareTo(_urgency(b));
      if (order != 0) return order;
      order = (a.status.isFresh ? 0 : 1).compareTo(b.status.isFresh ? 0 : 1);
      if (order != 0) return order;
      order = a.status.observedAt.compareTo(b.status.observedAt);
      return order != 0 ? order : a.identity.compareTo(b.identity);
    });
    checks.sort((a, b) => a.profileID.compareTo(b.profileID));
    return AttentionFeed._(List.unmodifiable(items), List.unmodifiable(checks));
  }

  final List<AttentionFeedItem> items;
  final List<AttentionServerCheck> servers;

  /// Only this permits an all-clear empty state. No known item is a lower
  /// bound, not a zero, if any saved server could not be checked completely.
  bool get isComplete =>
      servers.every((server) => server.isCurrent) &&
      items.every((item) => item.status.isFresh);
  int get knownAttentionCount => items.length;
  int get freshAttentionCount =>
      items.where((item) => item.status.isFresh).length;
  int? get attentionCount => isComplete ? items.length : null;

  static int _urgency(AttentionFeedItem item) =>
      item.kind == AttentionKind.failedRun ||
          item.status.facts.phase == WorkRowPhase.failed
      ? 1
      : 0;

  static bool _recent(DateTime? at, DateTime now, Duration maxAge) =>
      at != null && !at.isAfter(now) && now.difference(at) <= maxAge;

  static AttentionCheckState _checkState(
    ProfileAttentionSnapshot snapshot,
    bool current,
    bool coverage,
  ) => switch (snapshot.status) {
    ProfileMonitorStatus.disabled => AttentionCheckState.disabled,
    ProfileMonitorStatus.waiting => AttentionCheckState.waiting,
    ProfileMonitorStatus.checking => AttentionCheckState.checking,
    ProfileMonitorStatus.unavailable => AttentionCheckState.unavailable,
    ProfileMonitorStatus.wifiRequired => AttentionCheckState.wifiRequired,
    ProfileMonitorStatus.paused => AttentionCheckState.paused,
    ProfileMonitorStatus.current when !snapshot.complete =>
      AttentionCheckState.partial,
    ProfileMonitorStatus.current when !current => AttentionCheckState.stale,
    ProfileMonitorStatus.current when !coverage => AttentionCheckState.partial,
    ProfileMonitorStatus.current => AttentionCheckState.current,
  };
}
