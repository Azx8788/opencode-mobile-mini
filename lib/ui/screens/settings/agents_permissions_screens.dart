part of '../settings_screen.dart';

/// Agents (Settings Standard W1): the one home for everything that is an
/// agent. The AI Team, the agents that run on this phone, and the external
/// agents added by address were three homes (audit M1); each is one row here
/// and opens the page that already holds it.
class AgentsHubScreen extends StatelessWidget {
  const AgentsHubScreen({super.key, required this.controller});

  final ConnectionController controller;

  Future<void> _door(BuildContext context, String id) async {
    final copy = _settingsCopy(context);
    final entry = allSearchEntries(
      copy,
    ).where((entry) => entry.id == id).firstOrNull;
    if (entry == null) return;
    await entry.open(context, SearchScope.of(context, controller));
  }

  @override
  Widget build(BuildContext context) {
    final copy = _settingsCopy(context);
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final tokens = KitTokens.of(context);
    final profile = controller.profile;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => KitScreen(
        topBar: KitTopBar(title: copy.agentsSectionTitle),
        width: KitScreenWidth.reading,
        body: ListView(
          key: const ValueKey('agents-hub-list'),
          padding: EdgeInsetsDirectional.only(
            top: tokens.space2,
            bottom: KitScreen.endPadding(context),
          ),
          children: [
            // One group, three rows: each says what it is and its state, so
            // no row repeats a label above it.
            KitRowGroup(
              children: [
                if (profile != null)
                  // On, off, or turning on while this phone installs it: the
                  // words Tools › Plugins uses (teamStateLine).
                  Builder(
                    builder: (context) {
                      Widget row(SetupProgress? setup) => KitRow(
                        key: const ValueKey('settings-ai-team'),
                        title: l10n.teamUiHomeTitle,
                        trailing: KitRowValue(
                          teamStateLine(l10n, controller, setup: setup),
                        ),
                        onTap: () => _door(context, 'settings-ai-team'),
                      );
                      if (teamServerKindOf(profile) != TeamServerKind.inApp) {
                        return row(null);
                      }
                      return ValueListenableBuilder<SetupProgress>(
                        valueListenable: PhoneSetup.engine.progress,
                        builder: (context, setup, _) => row(setup),
                      );
                    },
                  ),
                KitRow(
                  key: const ValueKey('agents-hub-phone'),
                  title: copy.settingsV3AgentsOnPhone,
                  supporting: controller.phoneAgentsAvailable
                      ? null
                      : TextSpan(text: copy.agentsRunOnBuiltIn),
                  supportingMaxLines: 2,
                  trailing: controller.phoneAgentsAvailable
                      ? KitRowValue(copy.settingsV3AgentsReady)
                      : const KitChevron(),
                  onTap: () =>
                      pushKitPage<void>(context, (_) => const AgentsScreen()),
                ),
                KitRow(
                  key: const ValueKey('agents-hub-external'),
                  title: copy.a2aTitle,
                  trailing: KitRowValue(
                    copy.settingsV3AgentsExternalCount(_externalCount()),
                  ),
                  onTap: () => openExternalAgents(context, controller),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  int _externalCount() {
    try {
      final store = controller.store;
      return ExternalAgentStore(
        store.prefs,
        store.secure,
      ).profiles.where((p) => !p.deleting).length;
    } catch (_) {
      return 0;
    }
  }
}

/// Permissions and automation (Chat): what runs by itself and the actions
/// that are always allowed. It moved out of the old "Notifications and
/// background" page, where it had nothing to do with either.
class PermissionsAutomationScreen extends StatelessWidget {
  const PermissionsAutomationScreen({
    super.key,
    required this.controller,
    this.teamAvailable,
  });

  final ConnectionController controller;

  /// Test seam, handed to the section unchanged.
  final bool? teamAvailable;

  @override
  Widget build(BuildContext context) {
    final copy = _settingsCopy(context);
    final tokens = KitTokens.of(context);
    return KitScreen(
      topBar: KitTopBar(title: copy.settingsV3Permissions),
      width: KitScreenWidth.reading,
      body: ListView(
        key: const ValueKey('permissions-automation'),
        padding: EdgeInsetsDirectional.only(
          top: tokens.space2,
          bottom: KitScreen.endPadding(context),
        ),
        children: [
          AutomationSettingsSection(
            controller: controller,
            teamAvailable: teamAvailable,
            // An allowed answer is changed where the system keeps it: the
            // page for notifications or for the background connection.
            onShowSection: (slug) => pushKitPage<void>(
              context,
              (_) => NotificationsSettingsScreen(
                controller: controller,
                page: slug == 'what'
                    ? NotificationsPage.notifications
                    : NotificationsPage.background,
                initialSection: slug,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
