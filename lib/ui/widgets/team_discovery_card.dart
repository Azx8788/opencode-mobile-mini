/// The discovery of 02-ux §1.2: when the connected server has no AI Team
/// config, its own host is asked whether it answers like a Gas City on port
/// 8373 (the host front, which gives controls) or 8372 (the bare
/// supervisor, read-only); the front port is tried first and preferred.
/// What it finds is shown where the team already is, never as a card of its
/// own: the Plugins row says "Found on {server}" with Turn on, and the AI
/// Team page offers Turn on (review board, embedded-team-discovery-card:
/// one team, one presence). A dismissal remembered through
/// [OrchestrationStore.dismissDiscovery] (turning a team off) stops the
/// asking for that server.
library;

import 'package:flutter/material.dart';

import '../../builtin/builtin_server.dart' show looksLikeInAppServer;
import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import '../../state/profiles.dart';
import 'team_host_form.dart';

/// What discovery found for a profile, shared with the Plugins row so it can
/// read "Found on … · Gas City 1.4" before the plugin is on.
class TeamDiscoveryResult {
  const TeamDiscoveryResult({required this.url, required this.found});

  final String url;
  final ProbeFound found;
}

/// The addresses discovery probes for [profile]. None for the OpenCode
/// inside this app: it has its own team (BuiltinTeamSection), and what
/// answers on this phone's loopback ports is Termux's team, which is
/// neither a computer nor this server's to adopt.
List<String> teamDiscoveryUrlsForProfile(ServerProfile profile) =>
    looksLikeInAppServer(profile)
    ? const []
    : teamDiscoveryUrlsFor(profile.baseUrl);

/// Probes the profile's host once per (profile, config-null) and keeps the
/// answer for the widgets on this screen. One per screen; the card and the
/// row read it.
class TeamDiscovery extends ChangeNotifier {
  TeamDiscovery(this.controller, {TeamHostProbe? probe})
    : _probe = probe ?? teamHostProbe;

  final ConnectionController controller;
  final TeamHostProbe _probe;

  String? _probedProfileId;
  bool _running = false;
  bool _probed = false;
  TeamDiscoveryResult? _result;
  ProbeVerdict? _miss;

  /// The found host, null before the probe answered or when nothing was
  /// found.
  TeamDiscoveryResult? get result => _result;

  /// Why nothing was found, once the probe answered without a team: the
  /// most telling of the answers (a team that is starting, then a refused
  /// plain address, then a server that is no team, then no answer at all).
  /// Null while looking, when a team was found, and when no address could
  /// be tried.
  ProbeVerdict? get miss => _miss;

  /// True once the probe for the current profile answered (found or not).
  bool get probed => _probed;
  bool get running => _running;

  /// Runs the probe when the profile has no config and the offer is not
  /// dismissed; a profile switch re-probes, a config re-check is free.
  Future<void> ensureProbed() async {
    final profile = controller.profile;
    if (profile == null || profile.orchestration != null) {
      _reset();
      return;
    }
    if (_probedProfileId == profile.id) return;
    final store = controller.orchestrationStore;
    if (store.isDiscoveryDismissed(profile.id)) {
      _probedProfileId = profile.id;
      _probed = true;
      _result = null;
      notifyListeners();
      return;
    }
    final urls = teamDiscoveryUrlsForProfile(profile);
    _probedProfileId = profile.id;
    _result = null;
    _miss = null;
    if (urls.isEmpty) {
      _probed = true;
      notifyListeners();
      return;
    }
    _running = true;
    _probed = false;
    notifyListeners();
    TeamDiscoveryResult? result;
    ProbeVerdict? miss;
    for (final url in urls) {
      ProbeVerdict verdict;
      try {
        verdict = await _probe(url);
      } catch (error) {
        verdict = ProbeUnreachable(error: error);
      }
      if (_probedProfileId != profile.id) return;
      if (verdict is ProbeFound) {
        result = TeamDiscoveryResult(url: url, found: verdict);
        break;
      }
      if (miss == null || _missRank(verdict) < _missRank(miss)) {
        miss = verdict;
      }
    }
    _running = false;
    _probed = true;
    _result = result;
    _miss = result == null ? miss : null;
    notifyListeners();
  }

  static int _missRank(ProbeVerdict verdict) => switch (verdict) {
    ProbeCityNotRunning() => 0,
    ProbePlainHttpRefused() => 1,
    ProbeNotGasCity() => 2,
    ProbeUnreachable() => 3,
    ProbeFound() => 4,
  };

  void _reset() {
    if (_probedProfileId == null && !_probed && _result == null) return;
    _probedProfileId = null;
    _probed = false;
    _running = false;
    _result = null;
    _miss = null;
    notifyListeners();
  }

  /// Remembers the dismissal and hides the offer.
  Future<void> dismiss() async {
    final profile = controller.profile;
    if (profile == null) return;
    await controller.orchestrationStore.dismissDiscovery(profile.id);
    _result = null;
    notifyListeners();
  }

  /// Saves the found host on the profile and starts the plugin. A failed
  /// save leaves the profile as it was and rethrows.
  Future<void> turnOn() async {
    final profile = controller.profile;
    final result = _result;
    if (profile == null || result == null) return;
    final previous = profile.orchestration;
    profile.orchestration = teamConfigFromVerdict(
      result.found,
      url: result.found.front ? result.found.host.url : result.url,
      city: result.found.city ?? '',
    );
    try {
      await controller.store.upsert(profile);
    } catch (_) {
      // Nothing changed: the offer stays and says the save failed.
      profile.orchestration = previous;
      rethrow;
    }
    controller.syncOrchestration();
    _reset();
  }
}

/// The performance disclaimer of 03-onboarding §4 for the kind of machine
/// a team host runs on (TEAM-206): one sentence per [OrchestrationHostKind].
String teamHostDisclaimer(AppLocalizations l10n, OrchestrationHostKind kind) =>
    switch (kind) {
      OrchestrationHostKind.pc => l10n.teamUiDisclaimerComputer,
      OrchestrationHostKind.laptop => l10n.teamUiHostKindDisclaimerLaptop,
      OrchestrationHostKind.wsl => l10n.teamUiHostKindDisclaimerWsl,
      OrchestrationHostKind.phone => l10n.teamUiDisclaimerPhone,
    };

/// The kind a disclaimer is shown for: the chosen [config] kind when it
/// agrees with what the host reports, else the reported mode's default (a
/// host that says it is a phone is a phone whatever the form said).
OrchestrationHostKind teamHostKindFor(
  OrchestrationConfig? config,
  OrchestrationHostMode? reported,
) {
  final kind = config?.hostKind;
  final mode = reported ?? kind?.mode ?? OrchestrationHostMode.computer;
  return kind != null && kind.mode == mode
      ? kind
      : OrchestrationHostKind.forMode(mode);
}
