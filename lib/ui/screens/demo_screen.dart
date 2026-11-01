import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../demo/demo_copy.dart';
import '../../demo/demo_gateway.dart';
import '../../demo/demo_store.dart';
import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import '../../state/review_handoff.dart';
import '../app_iconography.dart';
import '../app_theme.dart' show AppStatusTone;
import '../kit/kit.dart';
import 'chat_screen.dart';
import 'team/project_demo_screen.dart';

/// "Try it offline" (map: demo): the production chat backed by a
/// route-owned gateway and ephemeral stores, under one status line that says
/// it is simulated. Nothing replaces the real connection, profile store or
/// plugin singleton.
class DemoScreen extends StatefulWidget {
  const DemoScreen({super.key});

  @override
  State<DemoScreen> createState() => _DemoScreenState();
}

class _DemoScreenState extends State<DemoScreen> {
  late DemoGateway _gateway;
  late DemoProfileStore _store;
  late ConnectionController _controller;
  late ReviewHandoffStore _handoff;
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    _create();
  }

  void _create() {
    _gateway = DemoGateway();
    _store = DemoProfileStore();
    _handoff = ReviewHandoffStore();
    _controller =
        ConnectionController.isolated(
            _store,
            gateway: _gateway,
            operations: _gateway,
            profile: _store.profiles.single,
          )
          ..sessionsById = {DemoGateway.sessionID: DemoGateway.sampleSession}
          ..catalog = DemoGateway.catalog
          ..selectedModel = DemoGateway.model;
  }

  bool _reducedMotion(BuildContext context) =>
      KitMotion.reduced(context) || MediaQuery.accessibleNavigationOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _gateway.reducedMotion = _reducedMotion(context);
  }

  void _reset() {
    final previous = _controller;
    final previousStore = _store;
    _gateway.close();
    setState(() {
      _generation++;
      _create();
      _gateway.reducedMotion = _reducedMotion(context);
    });
    // Let the old chat remove its listeners before releasing its controller.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      previous.dispose();
      unawaited(previousStore.prefs.clear());
    });
  }

  void _exit() {
    _gateway.close();
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _gateway.close();
    _controller.dispose();
    unawaited(_store.prefs.clear());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final tokens = KitTokens.of(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    return KitScreen(
      // The X is the one way out and says so: "Leave demo". Set up your own
      // server stays on the finished notice, where the loop has earned it.
      topBar: KitTopBar(
        title: l10n.demoScreenTitle,
        exit: KitTopBarExit.none,
        actions: [
          KitAction(
            key: const Key('demo-leave'),
            label: l10n.demoScreenLeave,
            icon: AppIconography.close,
            onPressed: _exit,
          ),
          KitAction(
            key: const Key('demo-team-projects'),
            label: l10n.teamProjectTryDemo,
            icon: AppIconography.agent,
            onPressed: () => unawaited(
              pushKitPage<void>(context, (_) => const TeamProjectDemoScreen()),
            ),
          ),
        ],
      ),
      // One line says it is simulated and offers to start again; the longer
      // disclosure sits under it while there is room.
      status: KitStatus(
        kind: KitStatusKind.info,
        id: 'demo',
        icon: AppIconography.experiments,
        message: l10n.demoScreenSimulated,
        supporting: keyboard ? null : l10n.demoScreenDisclosure,
        action: KitAction(
          key: const Key('demo-reset'),
          label: l10n.demoScreenReset,
          icon: AppIconography.restart,
          onPressed: _reset,
        ),
      ),
      header: [
        ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => _gateway.hasFinished && !keyboard
              ? Padding(
                  padding: EdgeInsetsDirectional.fromSTEB(
                    tokens.gutter,
                    tokens.space2,
                    tokens.gutter,
                    tokens.space2,
                  ),
                  child: KitNotice(
                    key: const Key('demo-finished'),
                    tone: AppStatusTone.ok,
                    message: l10n.demoScreenFinished,
                    actions: [
                      KitAction(
                        key: const Key('demo-set-up-server'),
                        label: l10n.demoSetUpServer,
                        icon: AppIconography.server,
                        onPressed: _exit,
                      ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
      body: ProviderScope(
        key: ValueKey(_generation),
        overrides: [
          connProvider.overrideWithValue(_controller),
          bootstrapProvider.overrideWithValue(AppBootstrap(_store)),
        ],
        child: ChatScreen(
          sessionID: DemoGateway.sessionID,
          showAppBar: false,
          hostKeyboardUp: keyboard,
          emptyState: KitStateView(
            icon: AppIconography.experiments,
            title: l10n.demoTaskTitle,
            body: l10n.demoTaskInstruction,
          ),
          initialText: DemoCopy.prompt,
          handoffStore: _handoff,
        ),
      ),
    );
  }
}
