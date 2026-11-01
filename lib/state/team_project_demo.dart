import 'package:shared_preferences/shared_preferences.dart';

import 'connection.dart';
import 'orchestration.dart';
import 'orchestration_store.dart';
import 'profiles.dart';

const teamProjectDemoConfig = OrchestrationConfig(
  provider: OrchestrationProvider.fixture,
  url: 'fixture://project-demo',
);

/// Explicitly enables the project simulator only where no team is configured.
/// It never replaces a real engine or sends a request to the OpenCode server.
Future<bool> enableTeamProjectDemo(ConnectionController connection) async {
  final profile = connection.profile;
  if (profile == null || profile.orchestration != null) return false;
  profile.orchestration = teamProjectDemoConfig;
  try {
    await connection.store.upsert(profile);
  } catch (_) {
    profile.orchestration = null;
    rethrow;
  }
  connection.syncOrchestration();
  return true;
}

/// Standalone demo uses its own local namespace and needs no saved server.
/// The caller owns the controller. Opening it never changes the real profile.
OrchestrationController createTeamProjectPreview(SharedPreferences prefs) {
  final profile = ServerProfile(
    id: 'team-project-preview',
    name: 'AI Team demo',
    baseUrl: 'http://127.0.0.1',
  );
  return OrchestrationController(
    profile: profile,
    config: teamProjectDemoConfig,
    store: OrchestrationStore(prefs),
  );
}

/// Leaves the simulator while keeping its workspace available for next time.
/// Profile deletion remains responsible for erasing these local records.
Future<void> leaveTeamProjectDemo(ConnectionController connection) async {
  final profile = connection.profile;
  final config = profile?.orchestration;
  if (profile == null ||
      config?.provider != OrchestrationProvider.fixture ||
      config?.url != teamProjectDemoConfig.url) {
    return;
  }
  final owner = connection.orchestration;
  profile.orchestration = null;
  try {
    await connection.store.upsert(profile);
  } catch (_) {
    profile.orchestration = config;
    rethrow;
  }
  if (owner?.profileId == profile.id) {
    await owner?.stop();
  }
  connection.syncOrchestration();
}
