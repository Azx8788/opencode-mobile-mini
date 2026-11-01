/// B-2 (E2E 2026-09-30): a phone that had the old Gas City team On before
/// the update keeps it On, and the old team has no project screens. This is
/// the one screen that says AI Team changed and offers the way over: the
/// phone's one-tap setup, or keeping the old team for now. The choice to
/// keep is a per-profile key (`oc.teamMigrationKept.<profileId>`), so
/// deleting the server sweeps it.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../state/connection.dart';
import '../../../state/phone_team_setup.dart';
import '../../../state/profiles.dart' show OrchestrationProvider;
import '../../app_theme.dart';
import '../../kit/kit.dart';
import 'project_demo_screen.dart';
import 'team_phone_setup_screen.dart';

String _keptKey(String profileId) => 'oc.teamMigrationKept.$profileId';

/// Whether the connected server has an old (non-phone-engine) team On while this phone can
/// run the new one.
bool teamMigrationOffered(ConnectionController connection) {
  final profile = connection.profile;
  final provider = profile?.orchestration?.provider;
  if (provider == null || provider == OrchestrationProvider.phoneEngine) {
    return false;
  }
  return PhoneTeamSetup.hasServer(connection);
}

bool teamMigrationKept(ConnectionController connection) {
  final id = connection.profile?.id;
  return id != null && (connection.store.prefs.getBool(_keptKey(id)) ?? false);
}

/// Shows [child] (the old team) once the person chose to keep it, the
/// migration screen before that.
class TeamMigrationGate extends StatefulWidget {
  const TeamMigrationGate({
    super.key,
    required this.connection,
    required this.child,
  });
  final ConnectionController connection;
  final Widget child;

  @override
  State<TeamMigrationGate> createState() => _TeamMigrationGateState();
}

class _TeamMigrationGateState extends State<TeamMigrationGate> {
  late bool _kept = teamMigrationKept(widget.connection);

  @override
  Widget build(BuildContext context) {
    if (_kept || !teamMigrationOffered(widget.connection)) return widget.child;
    return TeamMigrationScreen(
      connection: widget.connection,
      onKeep: () async {
        final id = widget.connection.profile?.id;
        if (id != null) {
          await widget.connection.store.prefs.setBool(_keptKey(id), true);
        }
        if (mounted) setState(() => _kept = true);
      },
    );
  }
}

/// Opens the same screen from the old team's menu (to switch later).
Future<void> openTeamMigration(
  BuildContext context,
  ConnectionController connection,
) => pushKitPage<void>(
  context,
  (_) => TeamMigrationScreen(
    connection: connection,
    onKeep: () async => Navigator.of(context).maybePop(),
  ),
);

class TeamMigrationScreen extends StatelessWidget {
  const TeamMigrationScreen({
    super.key,
    required this.connection,
    required this.onKeep,
  });
  final ConnectionController connection;
  final Future<void> Function() onKeep;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return KitScreen(
      topBar: KitTopBar(title: l10n.teamUiHomeTitle),
      width: KitScreenWidth.reading,
      body: KitStateView(
        icon: AppIconography.swap,
        title: l10n.teamMigrationTitle,
        body: l10n.teamMigrationBody,
        primary: KitAction(
          key: const ValueKey('team-migration-switch'),
          label: l10n.teamMigrationSwitch,
          onPressed: () => unawaited(openPhoneTeamSetup(context, connection)),
        ),
        secondary: KitAction(
          key: const ValueKey('team-migration-keep'),
          label: l10n.teamMigrationKeep,
          onPressed: () => unawaited(onKeep()),
        ),
        tertiary: [
          KitAction(
            key: const ValueKey('team-migration-demo'),
            label: l10n.teamProjectTryDemo,
            onPressed: () => unawaited(
              pushKitPage<void>(
                context,
                (_) =>
                    TeamProjectDemoScreen(preferences: connection.store.prefs),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
