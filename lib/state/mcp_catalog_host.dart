import '../builtin/builtin_server.dart';
import '../termux/bridge.dart';
import 'phone_host.dart' show PhoneHostKind;
import 'profiles.dart';

/// Which phone host serves [profile], or null when it is not OpenCode on
/// this phone. The MCP catalogue (P2.5) uses it to offer phone setup's Add
/// tools for a server that needs Node there, instead of a command that
/// would fail. Shape only (the managed loopback address on Android), the
/// same test This phone uses to pick its host.
PhoneHostKind? phoneHostOfProfile(ServerProfile? profile) {
  if (profile == null) return null;
  if (TermuxBridge.supported &&
      TermuxBridge.managesServerUrl(profile.baseUrl)) {
    return PhoneHostKind.termux;
  }
  if (looksLikeInAppServer(profile)) return PhoneHostKind.inApp;
  return null;
}
