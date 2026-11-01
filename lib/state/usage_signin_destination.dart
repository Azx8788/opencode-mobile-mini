import '../domain/agent_catalog.dart';
import '../platform/launch_shortcut.dart';
import 'paseo_usage_monitor.dart';
import 'profiles.dart';

/// Where a Usage widget row's tap leads.
enum UsageSignInKind {
  /// The server's Providers page, opening that provider's sign-in or key.
  openCodeProvider,

  /// This phone's agent sheet on the sign-in step.
  agentSignIn,

  /// The "Read usage from" screen for a sign-in no reader reaches
  /// yet (widget `set_up` rows), for the server in
  /// [UsageSignInDestination.profileId].
  readUsageFrom,

  /// Nothing better can be resolved: the Usage page.
  usagePage,
}

class UsageSignInDestination {
  const UsageSignInDestination(
    this.kind, {
    this.providerId,
    this.agentId,
    this.profileId,
  });

  final UsageSignInKind kind;

  /// OpenCode's provider id for [UsageSignInKind.openCodeProvider].
  final String? providerId;

  /// The built-in agent for [UsageSignInKind.agentSignIn].
  final String? agentId;

  /// The saved server for [UsageSignInKind.readUsageFrom].
  final String? profileId;

  static const usage = UsageSignInDestination(UsageSignInKind.usagePage);

  @override
  bool operator ==(Object other) =>
      other is UsageSignInDestination &&
      other.kind == kind &&
      other.providerId == providerId &&
      other.agentId == agentId &&
      other.profileId == profileId;

  @override
  int get hashCode => Object.hash(kind, providerId, agentId, profileId);

  @override
  String toString() =>
      'UsageSignInDestination($kind, $providerId, $agentId, $profileId)';
}

/// OpenCode's own ids for the providers the Usage widget can read.
const _openCodeProviderIds = {
  'codex': 'openai',
  'glm': 'zai-coding-plan',
  'minimax': 'minimax-coding-plan',
};

/// Maps a widget row's [target] to a screen. [profile] is the saved server
/// the target names (null when it is gone, or for this phone's agents).
UsageSignInDestination usageSignInDestination(
  UsageSignInTarget target, {
  required ServerProfile? profile,
}) {
  if (target.action == 'set_up') {
    return profile == null
        ? UsageSignInDestination.usage
        : UsageSignInDestination(
            UsageSignInKind.readUsageFrom,
            providerId: target.providerId,
            profileId: profile.id,
          );
  }
  if (target.profileId == PaseoUsageMonitor.phoneId) {
    final agent = AgentCatalog.builtIn.byId(target.providerId);
    return agent == null
        ? UsageSignInDestination.usage
        : UsageSignInDestination(
            UsageSignInKind.agentSignIn,
            agentId: agent.id,
          );
  }
  if (profile == null || profile.backend != ServerBackend.openCode) {
    return UsageSignInDestination.usage;
  }
  final id = _openCodeProviderIds[target.providerId];
  if (id == null) return UsageSignInDestination.usage;
  return UsageSignInDestination(
    UsageSignInKind.openCodeProvider,
    providerId: id,
  );
}
