import 'profiles.dart';

/// When a switch gives this phone a different saved server (one per
/// runtime), the AI Team that was on for the old one follows to the new
/// one: its config and engine credential move, so the team stays on and the
/// start that follows brings it back. A target that already has its own
/// team config keeps it; a remote server's team is never touched
/// ([sameHost] picks only this phone's own servers).
Future<void> teamFollowsRuntime(
  ProfileStore store,
  ServerProfile target, {
  required bool Function(ServerProfile profile) sameHost,
}) async {
  if (target.orchestration != null) return;
  for (final from in [...store.profiles]) {
    if (from.id == target.id || !sameHost(from)) continue;
    final config = from.orchestration;
    if (config == null) continue;
    target
      ..orchestration = config
      ..teamEngineAuth = from.teamEngineAuth;
    from
      ..orchestration = null
      ..teamEngineAuth = '';
    await store.upsert(target);
    await store.upsert(from);
    return;
  }
}
