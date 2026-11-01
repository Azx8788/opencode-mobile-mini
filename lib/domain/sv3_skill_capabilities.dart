import 'server_gateway.dart';

export '../domain/models.dart' show ModelRef, SessionSelection;

/// SV3 capability hooks without changing the single-owner gateway library.
extension Sv3SkillCapabilities on ServerCapabilities {
  /// Activation additionally needs the optional, runtime-probed gateway facet.
  bool canStartSkillConversation(SessionSkillGateway? gateway) =>
      serverCatalog && gateway != null && gateway.sessionSkillsSupported;

  /// Requests a draft through ordinary prompting; does not install a skill.
  bool get skillAuthoringRequests => serverCatalog;

  /// No provider discovery contract supplies a key provisioning page URL.
  bool get providerKeyPageLinks => false;
}
