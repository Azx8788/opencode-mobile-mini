import '../builtin/builtin_linux.dart';
import '../domain/dev_preview.dart';
import '../domain/managed_shell.dart';
import 'connection.dart';
import 'detected_dev_servers.dart';
import 'profiles.dart';

/// How to run a script in the in-app Linux, or null when [profile] is not
/// the phone itself (a server on another machine) or this build has no
/// in-app Linux. Listening ports can only be read where the script runs.
Future<PhoneRunResult> Function(String script)? phoneScriptRunner(
  ServerProfile? profile, {
  BuiltinLinux? linux,
  bool? supported,
}) {
  if (profile == null || profile.transientTransport) return null;
  if (!(supported ?? BuiltinLinux.supported)) return null;
  final host = Uri.tryParse(profile.baseUrl.trim())?.host ?? '';
  if (host.isEmpty || !DevPreviewTarget.isLoopbackHost(host)) return null;
  final runner = linux ?? BuiltinLinux();
  return (script) async {
    final result = await runner.run(
      script,
      timeout: const Duration(seconds: 25),
    );
    return (exitCode: result.exitCode, output: result.output);
  };
}

/// The detector for [connection]'s project: shells the server runs, plus
/// listening ports when the server is the phone. [isCurrent] says when the
/// caller's screen is still the one to update.
DetectedDevServers detectedDevServersFor(
  ConnectionController connection, {
  required bool Function() isCurrent,
  Set<String> Function()? ownedShellIds,
  Future<PhoneRunResult> Function(String script)? runOnPhone,
  bool usePhoneScan = true,
}) {
  return DetectedDevServers(
    directory: connection.directory ?? '',
    isCurrent: isCurrent,
    ownedShellIds: ownedShellIds,
    runOnPhone:
        runOnPhone ??
        (usePhoneScan ? phoneScriptRunner(connection.profile) : null),
    resolveGateway: () async {
      if (!connection.capabilities.developmentServices) return null;
      try {
        final gateway = await connection.prepareActionRepository();
        return gateway is ManagedShellGateway ? gateway : null;
      } catch (_) {
        return null;
      }
    },
  );
}
