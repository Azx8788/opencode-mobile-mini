import '../builtin/thermal_guard.dart';
import '../domain/orchestration_gateway.dart';
import 'team_conversation.dart' show teamSessionState;

/// Facts for the team page; localize these states in the UI.
enum TeamActivity {
  unknown,
  idle,
  working,
  needsYou,
  blocked,
  pausedForHeat,
  stoppedForHeat,
}

/// A projection of one profile's current host, sessions and thermal hold.
/// Nothing is persisted and no network requests or recovery actions are made.
class TeamOverview {
  const TeamOverview._({
    required this.activity,
    required this.isStale,
    required this.agentCounts,
    this.hostMode,
    this.heatHold,
  });

  final TeamActivity activity;
  final OrchestrationHostMode? hostMode;
  final bool isStale;

  /// Counts use session state before the possibly lagging agent state.
  /// These are last-known counts when [isStale] is true, not live counts.
  final Map<AgentState, int> agentCounts;

  /// Only a hold matching the profile, phone host URL and city is returned.
  /// Its `since`, `status` and `serviceStopped` explain the actual heat pause.
  final ThermalTeamHold? heatHold;
}

/// Recompute when the orchestration controller or thermal guard notifies.
///
/// Pass null [agents] until the agents scope has loaded successfully (and when
/// unsupported). An empty successfully fetched list is idle. Pass [isStale]
/// for disconnected, failed or old snapshots; inactivity never implies pause.
/// A current profile/host-matched thermal hold is independent of stream health.
TeamOverview teamOverview({
  required String profileId,
  required OrchestrationHostIdentity? host,
  required List<OrchestrationAgent>? agents,
  required bool isStale,
  ThermalTeamHold? heatHold,
}) {
  final counts = <AgentState, int>{};
  for (final agent in agents ?? const <OrchestrationAgent>[]) {
    final state = teamSessionState(agent);
    counts.update(state, (count) => count + 1, ifAbsent: () => 1);
  }
  final matchingHold =
      heatHold != null &&
          host != null &&
          host.hostMode == OrchestrationHostMode.phone &&
          heatHold.team.id == profileId &&
          _base(heatHold.team.url) == _base(host.url) &&
          host.city != null &&
          host.city!.isNotEmpty &&
          heatHold.team.city == host.city
      ? heatHold
      : null;
  final TeamActivity activity;
  if (matchingHold != null) {
    activity = matchingHold.serviceStopped
        ? TeamActivity.stoppedForHeat
        : TeamActivity.pausedForHeat;
  } else if (host == null || agents == null || isStale) {
    activity = TeamActivity.unknown;
  } else if (counts.containsKey(AgentState.waiting)) {
    activity = TeamActivity.needsYou;
  } else if (counts.containsKey(AgentState.working)) {
    activity = TeamActivity.working;
  } else if (counts.containsKey(AgentState.blocked) ||
      counts.containsKey(AgentState.crashed)) {
    activity = TeamActivity.blocked;
  } else if (counts.containsKey(AgentState.unknown)) {
    activity = TeamActivity.unknown;
  } else {
    activity = TeamActivity.idle;
  }
  return TeamOverview._(
    activity: activity,
    hostMode: host?.hostMode,
    isStale: isStale,
    agentCounts: Map.unmodifiable(counts),
    heatHold: matchingHold,
  );
}

String _base(String url) => url.replaceFirst(RegExp(r'/+$'), '');
