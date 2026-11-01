import '../../diagnostics/app_log.dart';
import '../../l10n/app_localizations.dart';
import '../../state/move_to_opencode2.dart';
import '../../state/profiles.dart';
import '../builtin_linux.dart';
import '../builtin_server.dart';
import 'setup_engine.dart';

/// The last step of a setup job: start OpenCode inside the app and connect
/// to it, through the same [BuiltinServerStarter] the opening card and the
/// return-to-app hook use, so setup can never start the server differently.
///
/// A server that already runs the right OpenCode, with the app connected to
/// it, is left alone ("Add tools" must not cut a running session); anything
/// else starts (or restarts) it and connects.
class BuiltinSetupFinisher {
  BuiltinSetupFinisher({
    required this.store,
    required this.starter,
    required this.connect,
    required this.isConnectedTo,
    required this.strings,
  });

  final ProfileStore store;
  final BuiltinServerStarter starter;

  /// Connects the app to [profile]; null on success, else why not.
  final Future<String?> Function(ServerProfile profile) connect;
  final bool Function(ServerProfile profile) isConnectedTo;
  final AppLocalizations Function() strings;

  BuiltinLinux get linux => starter.linux;

  Future<String?> call(SetupFinishRequest request) async {
    final l10n = strings();
    AppLog.info('setup', 'finisher begun', {
      'host': request.host.name,
      'runtime': request.runtime.wireName,
      'version': request.version,
      'openCodeChanged': request.openCodeChanged,
    });
    // A Termux job must never create/start the in-app Ubuntu profile.
    if (request.host != SetupHostKind.builtin) {
      AppLog.warn('setup', 'finisher refused a non-builtin host', {
        'host': request.host.name,
      });
      return l10n.phoneSetupErrorCannotStart;
    }
    request.runtime.requireSupported();
    final profile = await ensureBuiltinProfile(
      store,
      flavor: ServerFlavor.v2,
      name: l10n.phoneSetupProfileName,
      version: request.version,
      // The older setup screen's names, in every language this build ships.
      // Deriving them from `supportedLocales` keeps the list honest when the
      // catalogue set changes: this build has no Arabic catalogue, and asking
      // `lookupAppLocalizations` for one throws before the server is started.
      replaceNames: {
        for (final words in AppLocalizations.supportedLocales.map(
          lookupAppLocalizations,
        ))
          words.builtinServerProfileName(words.setupRuntimeTwo),
      },
    );
    AppLog.info('setup', 'profile ready', {
      'profile': profile.id,
      'url': profile.baseUrl,
      'backend': profile.backend.name,
    });
    // Reuse the selected migration source, including its local keys and team.
    // Only a source without its own team may adopt an older alias's team.
    await teamFollowsRuntime(
      store,
      profile,
      sameHost: (p) =>
          p.backend == ServerBackend.openCode &&
          BuiltinLinux.managesServerUrl(p.baseUrl),
    );
    var running = false;
    try {
      running = (await linux.status()).serverRunning;
    } on BuiltinLinuxException catch (error) {
      running = false;
      AppLog.warn('setup', 'server status read failed', {'error': '$error'});
    }
    final connected = isConnectedTo(profile);
    AppLog.info('setup', 'server state before start', {
      'running': running,
      'connected': connected,
    });
    if (!request.openCodeChanged && running && connected) {
      AppLog.info('setup', 'reusing the running server');
      return null;
    }
    // Running but not ours to trust (another runtime, or the app is not
    // connected to it): restarting costs seconds and removes the doubt.
    final migrating = profile.requiresOpenCode2Migration;
    AppLog.info('setup', 'starting the server', {
      'profile': profile.id,
      'migrateLegacyHistory': migrating,
    });
    final failure = await starter.start(
      profile,
      migrateLegacyHistory: migrating,
    );
    if (failure?.problem == BuiltinStartProblem.componentRecovery) {
      AppLog.error(
        'setup',
        'runtime_ownership_unknown',
        message: 'server start needs a component recovery',
      );
      return 'runtime_ownership_unknown';
    }
    if (failure != null) {
      final reason = failure.reason(l10n);
      AppLog.error(
        'setup',
        failure.problem.name,
        message: 'server start failed',
        fields: {'profile': profile.id, 'reason': reason},
      );
      return migrating ? l10n.setupSwitchFailed : reason;
    }
    AppLog.info('setup', 'server started, connecting', {'profile': profile.id});
    if (migrating) {
      profile
        ..requiresOpenCode2Migration = false
        ..openCode2HistoryPending = true;
      try {
        await store.upsert(profile);
      } catch (error, stack) {
        profile
          ..requiresOpenCode2Migration = true
          ..openCode2HistoryPending = false;
        AppLog.error(
          'setup',
          error,
          stack: stack,
          message: 'saving the migrated profile failed',
        );
        return l10n.setupSwitchFailed;
      }
    }
    final connectError = await connect(profile);
    if (connectError != null) {
      AppLog.error(
        'setup',
        connectError,
        message: 'connect after start failed',
      );
    } else {
      AppLog.info('setup', 'connected to the in-app server', {
        'profile': profile.id,
      });
    }
    return connectError;
  }
}
