/// Turning a server's AI Team on at an address, changing that address, and
/// turning it off: what the one AI Team page does (programme P3.4, the
/// team-plugin-sheet merged into team-home), and what Plugins' "a
/// computer's team instead" does, written once.
///
/// Reads and writes only the profile's [OrchestrationConfig] through the
/// connection's [ProfileStore], and the sibling [OrchestrationController]'s
/// own cache; never the server gateway.
library;

import 'package:flutter/widgets.dart';

import '../../builtin/team/builtin_team.dart' show BuiltinTeam;
import '../../state/connection.dart';
import '../../state/orchestration.dart';
import '../../state/profiles.dart';
import 'builtin_team_section.dart' show sharedBuiltinTeam;
import 'team_host_form.dart';

/// What became of a turn-off.
enum TeamOffOutcome {
  /// Off, and this phone holds nothing of it any more.
  off,

  /// Off, but some of its cached data could not be removed.
  leftovers,

  /// The team on this phone could not be stopped; nothing changed.
  failed,
}

/// Saves [config] as [profile]'s team and starts it. A changed host drops
/// the old host's cache before the new one writes its own.
Future<void> saveTeamHost(
  ConnectionController connection,
  ServerProfile profile,
  OrchestrationConfig config,
) async {
  final current = connection.orchestration;
  if (current != null && current.profileId == profile.id) {
    await current.remove();
  }
  profile.orchestration = config;
  await connection.store.upsert(profile);
  connection.syncOrchestration();
}

/// Opens the address form for the connected server's team (prefilled with
/// the saved address, else [suggestedUrl], else the server's own host) and
/// saves what it confirms. True when a new address was saved.
Future<bool> editTeamAddress(
  BuildContext context,
  ConnectionController connection, {
  TeamHostProbe? probe,
  String? suggestedUrl,
}) async {
  final profile = connection.profile;
  if (profile == null) return false;
  final existing = profile.orchestration;
  final config = await showTeamHostSheet(
    context,
    initialUrl:
        existing?.url ??
        suggestedUrl ??
        teamDiscoveryUrlFor(profile.baseUrl) ??
        '',
    initialCity: existing?.city ?? '',
    initialHostKind: existing?.hostKind,
    probe: probe,
  );
  if (config == null) return false;
  await saveTeamHost(connection, profile, config);
  return true;
}

/// Turns [profile]'s team off: the team inside this app stops first (and
/// stays stopped), then the cached team data goes, the config is cleared
/// and the discovery offer is not made again for 30 days (02-ux §1.3).
Future<TeamOffOutcome> turnOffTeam(
  ConnectionController connection,
  ServerProfile profile, {
  BuiltinTeam? builtin,
}) async {
  if (BuiltinTeam.isBuiltinConfig(profile.orchestration)) {
    try {
      await (builtin ?? sharedBuiltinTeam).turnOff();
    } catch (_) {
      return TeamOffOutcome.failed;
    }
  }
  final current = connection.orchestration;
  final Set<String> failed;
  if (current != null && current.profileId == profile.id) {
    failed = await current.remove();
  } else {
    failed = await connection.orchestrationStore.sweep(profile.id);
  }
  profile.orchestration = null;
  await connection.store.upsert(profile);
  // Written before the sync so the re-check after it sees the dismissal.
  await connection.orchestrationStore.dismissDiscovery(profile.id);
  connection.syncOrchestration();
  return failed.isEmpty ? TeamOffOutcome.off : TeamOffOutcome.leftovers;
}
