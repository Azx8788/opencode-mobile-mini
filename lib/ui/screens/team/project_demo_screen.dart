import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../l10n/app_localizations.dart';
import '../../../state/orchestration.dart';
import '../../../state/team_project_demo.dart';
import '../../kit/kit.dart';
import 'projects/team_projects_screen.dart';

/// A persisted, isolated project demo reachable even before adding a server.
class TeamProjectDemoScreen extends StatefulWidget {
  const TeamProjectDemoScreen({super.key, this.preferences});
  final SharedPreferences? preferences;
  @override
  State<TeamProjectDemoScreen> createState() => _TeamProjectDemoScreenState();
}

class _TeamProjectDemoScreenState extends State<TeamProjectDemoScreen> {
  OrchestrationController? _team;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final previous = _team;
    _team = null;
    previous?.dispose();
    if (mounted) setState(() => _failed = false);
    try {
      final prefs = widget.preferences ?? await SharedPreferences.getInstance();
      if (!mounted) return;
      final team = createTeamProjectPreview(prefs);
      _team = team;
      await team.start();
      if (mounted) setState(() => _failed = team.projectController == null);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _team?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final projects = _team?.projectController;
    if (projects != null) return TeamProjectsScreen(controller: projects);
    return KitScreen(
      topBar: KitTopBar(title: copy.teamProjectHome),
      loading: !_failed,
      loadingLabel: copy.teamProjectLoad,
      body: _failed
          ? KitNotice.error(
              message: copy.teamProjectLoadFailure,
              retry: KitAction(label: copy.teamProjectRetry, onPressed: _load),
            )
          : const SizedBox.shrink(),
    );
  }
}
