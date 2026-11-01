import 'package:flutter/foundation.dart';

import '../../l10n/app_localizations.dart';
import 'setup_contract.dart';
import 'setup_engine.dart';

/// Where the app gets its [SetupEngine]s, one per host: [engine] installs
/// into the app's own Linux, [termux] into Termux's (x12, P1.2). Both are
/// the channel-backed engine (setup_engine.dart) unless a test sets a fake.
/// A running engine never changes host, so each host keeps its own.
class PhoneSetup {
  PhoneSetup._();

  static SetupEngine? _engine;
  static SetupEngine? _termux;
  static SetupFinisher? _termuxFinisher;
  static AppLocalizations Function()? _strings;

  static SetupEngine get engine => _engine ??= ChannelSetupEngine();

  static set engine(SetupEngine value) => _engine = value;

  /// The in-app engine only if something already made it: a screen that just
  /// watches setup must not start one (it polls the phone).
  static SetupEngine? get engineIfCreated => _engine;

  /// The Termux host's engine. Its last step goes through the finisher the
  /// app shell attached ([attach]); before that, it says it could not
  /// start rather than starting anything another way.
  static SetupEngine get termux => _termux ??= ChannelSetupEngine.termux(
    strings: _strings,
    finisher: (request) async {
      final finish = _termuxFinisher;
      if (finish != null) return finish(request);
      return (_strings ?? ChannelSetupEngine.deviceStrings)()
          .phoneSetupErrorCannotStart;
    },
  );

  static set termux(SetupEngine value) => _termux = value;

  /// The engine of [host].
  static SetupEngine of(SetupHostKind host) =>
      host == SetupHostKind.termux ? termux : engine;

  /// Jobs whose "name your first project" screen has been shown in this run
  /// of the app, so a later tap on the "ready" notification does not offer
  /// it a second time. Kept in memory only: after the app was killed, a
  /// first setup's ready notification leads to that screen again, which is
  /// still a sensible place to land.
  static final _readyShown = <String>{};

  static bool readyShownFor(String? jobId) =>
      jobId != null && _readyShown.contains(jobId);

  static void markReadyShown(String? jobId) {
    if (jobId != null) _readyShown.add(jobId);
  }

  @visibleForTesting
  static void resetReadyShown() => _readyShown.clear();

  /// Called by the app shell once it can start and connect to the phone's
  /// servers: each engine's last step goes through its host's finisher
  /// ([finisher] in-app, [termuxFinisher] in Termux), and their words
  /// follow the app's own language choice ([strings]).
  static void attach({
    required SetupFinisher finisher,
    SetupFinisher? termuxFinisher,
    AppLocalizations Function()? strings,
  }) {
    if (termuxFinisher != null) _termuxFinisher = termuxFinisher;
    if (strings != null) {
      _strings = strings;
      final termuxEngine = _termux;
      if (termuxEngine is ChannelSetupEngine) termuxEngine.strings = strings;
    }
    final current = engine;
    if (current is! ChannelSetupEngine) return;
    current.finisher = finisher;
    if (strings != null) current.strings = strings;
  }
}
