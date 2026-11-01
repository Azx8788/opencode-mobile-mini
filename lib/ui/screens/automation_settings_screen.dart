import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../builtin/app_exit_recovery.dart' show appLifecycleBridgeProvider;
import '../../l10n/app_localizations.dart';
import '../../state/automation_policy.dart';
import '../../state/consent_owners.dart';
import '../../state/connection.dart';
import '../../state/in_flow_consent.dart';
import '../../state/team_planning.dart' show TeamSupervision;
import '../app_theme.dart';
import '../kit/kit.dart';
import '../../state/first_reply_notify_offer.dart'
    show turnOnNeedsYouNotifications;
import '../widgets/phone_server_consents.dart';
import 'saved_permissions_screen.dart';
import 'team/start_run_sheet.dart' show teamSupervisionCopy;

/// What the "What runs by itself" page can show for the current server.
/// Each part is present only where something real sits behind it: the
/// team's level only with a team, the saved rules only where the server
/// lists them, watching only for a server the monitor can read.
@immutable
class AutomationSettingsSections {
  const AutomationSettingsSections({
    required this.team,
    required this.savedRules,
    required this.watch,
  });

  /// How much the AI Team decides alone (the level new tasks start at).
  final bool team;

  /// The server's "Always allowed actions".
  final bool savedRules;

  /// Watching this server in the background for requests.
  final bool watch;

  bool get any => team || savedRules || watch;

  /// The sections [controller]'s current server supports; [team] overrides
  /// whether the AI Team is set up (tests describe it without a host).
  static AutomationSettingsSections of(
    ConnectionController controller, {
    bool? team,
  }) {
    final profile = controller.profile;
    if (profile == null) {
      return const AutomationSettingsSections(
        team: false,
        savedRules: false,
        watch: false,
      );
    }
    return AutomationSettingsSections(
      team: team ?? controller.orchestration != null,
      savedRules: controller.capabilities.savedPermissionList,
      watch:
          !controller.isIsolated &&
          controller.isProfileReadable(profile.id) &&
          controller.profileMonitor.supportsProfile(profile),
    );
  }
}

/// What runs by itself (P6.1): what the app and the agent do on the current
/// server without asking first, and the place to turn each of it off. The
/// last section of the "Notifications and background" page.
///
/// Built from kit parts: the AI Team's supervision as a [KitChoiceList]
/// (stored in this server's [AutomationPolicy], `oc.automation.<profileId>`;
/// new team tasks start at it) and the door to Always allowed actions (the
/// server's saved rules). Watching a server is a switch on the same page. A
/// choice is said as chosen only once storage took it.
///
/// **Your answers** (P6.7) lists what the app asked once on this server, in
/// flow ([ConsentOwners]): keeping the phone server alive (battery, the
/// maker's auto-start), "Notify me when the agent needs me", and the "Always
/// allow" offers turned down. Only asked questions have a row, the ones
/// still owing an answer first, then the declined (each saying what that
/// means), then the allowed (opening where the system setting lives).
/// Allowing here asks the same question as in flow and runs the same step.
class AutomationSettingsSection extends StatefulWidget {
  const AutomationSettingsSection({
    super.key,
    required this.controller,
    this.teamAvailable,
    this.onShowSection,
  });

  final ConnectionController controller;

  /// Scrolls the host page to the section an allowed answer is
  /// changed in (`what`, `keep-running`).
  final ValueChanged<String>? onShowSection;

  /// Whether the AI Team is set up for this server; null reads the
  /// connection. Tests pass it to describe a team without a host.
  final bool? teamAvailable;

  @override
  State<AutomationSettingsSection> createState() =>
      _AutomationSettingsSectionState();
}

class _AutomationSettingsSectionState extends State<AutomationSettingsSection> {
  AutomationPolicyController? _policy;
  String? _profileId;
  bool _saving = false;
  bool _saveFailed = false;

  /// This server's answers asked in flow; null until read (or unreadable).
  InFlowConsent? _consent;
  bool _consentUnreadable = false;
  bool _consentSaveFailed = false;
  int _declinedOffers = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_connectionChanged);
    widget.controller.profileMonitor.addListener(_changed);
    _bind();
  }

  @override
  void didUpdateWidget(covariant AutomationSettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    oldWidget.controller.removeListener(_connectionChanged);
    oldWidget.controller.profileMonitor.removeListener(_changed);
    widget.controller.addListener(_connectionChanged);
    widget.controller.profileMonitor.addListener(_changed);
    _bind();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_connectionChanged);
    widget.controller.profileMonitor.removeListener(_changed);
    _policy?.removeListener(_changed);
    super.dispose();
  }

  /// Follows the current server: another server's page never keeps showing
  /// (or writing) the previous one's choices.
  void _bind() {
    final profileId = widget.controller.profile?.id;
    if (_policy != null && profileId == _profileId) return;
    _policy?.removeListener(_changed);
    _profileId = profileId;
    _saveFailed = false;
    _policy = profileId == null
        ? null
        : AutomationPolicyController.forProfile(
            widget.controller.store.prefs,
            profileId,
          );
    _policy?.addListener(_changed);
    _consent = null;
    _consentUnreadable = false;
    _consentSaveFailed = false;
    _declinedOffers = 0;
    if (profileId != null) unawaited(_loadConsents(profileId));
  }

  Future<void> _loadConsents(String profileId) async {
    final prefs = widget.controller.store.prefs;
    InFlowConsent? consent;
    var unreadable = false;
    try {
      consent = await ConsentOwners.inFlow(prefs, profileId);
    } catch (_) {
      unreadable = true;
    }
    final declined = await ConsentOwners.repeated(
      prefs,
      profileId,
    ).declinedCount();
    if (!mounted || _profileId != profileId) return;
    setState(() {
      _consent = consent;
      _consentUnreadable = unreadable || declined == null;
      _declinedOffers = declined ?? 0;
    });
  }

  /// A question left unanswered or declined, answered now: the same words
  /// as in flow, saved before its step runs.
  Future<void> _allowConsent(InFlowConsentKind kind) async {
    final consent = _consent;
    if (consent == null || !consent.storageAvailable) return;
    final bridge = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLifecycleBridgeProvider);
    final maker = kind == InFlowConsentKind.makerAutoStart
        ? (await bridge.keepAliveInfo()).manufacturer
        : '';
    if (!mounted) return;
    final allow = await askConsent(
      context,
      kind,
      maker: maker,
      keyPrefix: 'automation-consent-ask',
    );
    if (!allow || !mounted) return;
    try {
      await consent.changeFromSettings(kind, allow: true);
    } catch (_) {
      if (mounted) setState(() => _consentSaveFailed = true);
      return;
    }
    if (mounted) setState(() => _consentSaveFailed = false);
    if (kind == InFlowConsentKind.needsYouNotifications) {
      await turnOnNeedsYouNotifications(widget.controller);
    } else {
      await runPhoneConsent(
        kind,
        connection: widget.controller,
        bridge: bridge,
      );
    }
    if (mounted) setState(() {});
  }

  /// An allowed answer is changed where the system keeps it: the phone's
  /// own settings (Keep running) or Notifications.
  void _openConsentHome(InFlowConsentKind kind) async {
    widget.onShowSection?.call(
      kind == InFlowConsentKind.needsYouNotifications ? 'what' : 'keep-running',
    );
  }

  Future<void> _offerAgain() async {
    final profileId = _profileId;
    if (profileId == null) return;
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final again = await showKitConfirm(
      context,
      title: l10n.consentAlwaysAgainTitle,
      body: l10n.consentAlwaysAgainBody,
      confirmLabel: l10n.consentAlwaysAgainConfirm,
      icon: AppIconography.privacy,
      sheetKey: const ValueKey('automation-consent-offer-again'),
      confirmKey: const ValueKey('automation-consent-offer-again-confirm'),
    );
    if (!again || !mounted) return;
    final repeated = ConsentOwners.repeated(
      widget.controller.store.prefs,
      profileId,
    );
    final saved = await repeated.forgetDeclined();
    final declined = await repeated.declinedCount();
    if (!mounted || _profileId != profileId) return;
    setState(() {
      _consentSaveFailed = !saved;
      _declinedOffers = declined ?? 0;
    });
  }

  void _connectionChanged() {
    if (!mounted) return;
    setState(_bind);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Choosing a level is the consent the contract asks for; it is stored
  /// before the page says so, and a refused write is said on the page.
  Future<void> _choose(AutomationSupervision level) async {
    final policy = _policy;
    if (policy == null || _saving || policy.value.supervision == level) return;
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    try {
      await policy.setSupervision(level);
    } catch (_) {
      if (mounted) setState(() => _saveFailed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _open(Widget screen) async {
    await pushKitPage<void>(context, (_) => screen);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final tokens = KitTokens.of(context);
    final controller = widget.controller;
    final profile = controller.profile;
    final policy = _policy;
    final sections = AutomationSettingsSections.of(
      controller,
      team: widget.teamAvailable,
    );

    final answers = _answerRows(l10n);
    final Widget body;
    if (profile == null ||
        policy == null ||
        (!sections.any && answers.isEmpty && !_consentUnreadable)) {
      return const SizedBox.shrink();
    } else {
      final children = <Widget>[
        if (_saveFailed) ...[
          KitNotice(
            key: const ValueKey('automation-save-failed'),
            tone: AppStatusTone.failure,
            message: l10n.automationSaveFailed,
          ),
          SizedBox(height: tokens.sectionGap),
        ],
        if (_consentUnreadable || _consentSaveFailed) ...[
          KitNotice(
            key: const ValueKey('automation-consent-failed'),
            tone: AppStatusTone.failure,
            message: _consentUnreadable
                ? l10n.consentStorageFailed
                : l10n.consentSaveFailed,
          ),
          SizedBox(height: tokens.sectionGap),
        ],
        if (answers.isNotEmpty) ...[
          KitRowGroup(
            key: const ValueKey('automation-answers'),
            label: l10n.consentGroupLabel,
            margin: EdgeInsetsDirectional.zero,
            children: answers,
          ),
          SizedBox(height: tokens.sectionGap),
        ],
        if (sections.team) ...[
          _supervision(l10n, tokens, policy.value.supervision),
          SizedBox(height: tokens.sectionGap),
        ],
        if (sections.savedRules)
          KitRowGroup(
            key: const ValueKey('automation-elsewhere'),
            label: l10n.automationWithoutAskingLabel,
            margin: EdgeInsetsDirectional.zero,
            children: [
              if (sections.savedRules)
                KitRow(
                  key: const ValueKey('automation-saved-permissions'),
                  leading: KitRow.icon(context, AppIconography.privacy),
                  title: l10n.e7LibraryAlwaysAllowedActions,
                  supporting: TextSpan(text: l10n.automationSavedRulesDetail),
                  supportingMaxLines: 2,
                  trailing: const KitChevron(),
                  onTap: () =>
                      _open(SavedPermissionsScreen(controller: controller)),
                ),
            ],
          ),
      ];
      body = Padding(
        padding: EdgeInsets.symmetric(horizontal: tokens.gutter),
        child: Column(
          key: const ValueKey('automation-settings-list'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );
    }
    return body;
  }

  /// The team's level: where new team tasks start. The start sheet still
  /// lets one task run at another level.
  Widget _supervision(
    AppLocalizations l10n,
    KitTokens tokens,
    AutomationSupervision selected,
  ) {
    return Column(
      key: const ValueKey('automation-team'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsetsDirectional.only(
            start: tokens.space1,
            end: tokens.space1,
            bottom: tokens.labelGap,
          ),
          child: Semantics(
            header: true,
            child: KitText(
              l10n.automationTeamLabel,
              role: KitTextRole.label,
              tone: KitTextTone.secondary,
            ),
          ),
        ),
        KitChoiceList<AutomationSupervision>.single(
          semanticsLabel: l10n.automationTeamLabel,
          choices: [
            for (final level in AutomationSupervision.values)
              KitChoice(
                key: ValueKey('automation-supervision-${level.name}'),
                value: level,
                title: _levelCopy(l10n, level.team).$1,
                supporting: _levelCopy(l10n, level.team).$2,
                enabled: !_saving,
                disabledReason: _saving ? l10n.automationSaving : null,
              ),
          ],
          selected: selected,
          onSelected: (level) => unawaited(_choose(level)),
        ),
        Padding(
          padding: EdgeInsetsDirectional.only(
            start: tokens.space1,
            end: tokens.space1,
            top: tokens.labelGap,
          ),
          child: KitText(
            l10n.automationTeamFootnote,
            role: KitTextRole.secondary,
            tone: KitTextTone.secondary,
          ),
        ),
      ],
    );
  }

  (String, String) _levelCopy(AppLocalizations l10n, TeamSupervision level) =>
      teamSupervisionCopy(l10n, level);

  /// The rows of Your answers, most in need of an answer first: a question
  /// left unanswered, then what was declined (and the Always allow offers
  /// turned down), then what was allowed. An unasked question has no row.
  List<Widget> _answerRows(AppLocalizations l10n) {
    final consent = _consent;
    if (consent == null) return const [];
    final rows = [
      for (final kind in InFlowConsentKind.values) consent.row(kind),
    ];
    final enabled = consent.storageAvailable;
    Widget row(InFlowConsentRow answer) {
      final kind = answer.kind;
      final allowed = answer.choice == InFlowConsentChoice.accepted;
      return KitRow(
        key: ValueKey('automation-consent-${kind.name}'),
        leading: KitRow.icon(context, switch (kind) {
          InFlowConsentKind.batteryExemption => AppIconography.batteryWarning,
          InFlowConsentKind.makerAutoStart => AppIconography.sync,
          InFlowConsentKind.needsYouNotifications =>
            AppIconography.notificationImportant,
        }),
        title: switch (kind) {
          InFlowConsentKind.batteryExemption => l10n.consentRowBattery,
          InFlowConsentKind.makerAutoStart => l10n.consentRowMaker,
          InFlowConsentKind.needsYouNotifications => l10n.consentRowNeedsYou,
        },
        titleMaxLines: 2,
        supporting: TextSpan(
          text: switch (answer.explanation) {
            InFlowConsentExplanation.batteryMayStopServer =>
              l10n.consentWhyBattery,
            InFlowConsentExplanation.makerMayPreventRestart =>
              l10n.consentWhyMaker,
            InFlowConsentExplanation.needsYouAlertsOff =>
              l10n.consentWhyNeedsYou,
            // Asked but never answered: say what it protects, like a plain
            // setting that is off. Never "the question closed".
            InFlowConsentExplanation.unfinished => switch (kind) {
              InFlowConsentKind.batteryExemption => l10n.consentWhyBattery,
              InFlowConsentKind.makerAutoStart => l10n.consentWhyMaker,
              InFlowConsentKind.needsYouNotifications =>
                l10n.consentWhyNeedsYou,
            },
            InFlowConsentExplanation.acceptedCheckSystemSettings =>
              kind == InFlowConsentKind.needsYouNotifications
                  ? l10n.consentAllowedNeedsYou
                  : l10n.consentAllowedSystem,
            InFlowConsentExplanation.notAsked => '',
          },
        ),
        supportingMaxLines: 3,
        trailing: KitRowValue(
          kind == InFlowConsentKind.needsYouNotifications
              ? (allowed ? l10n.settingsV3On : l10n.settingsV3Off)
              : switch (answer.choice) {
                  InFlowConsentChoice.accepted => l10n.consentValueAllowed,
                  InFlowConsentChoice.denied => l10n.consentValueDeclined,
                  _ => l10n.consentValueUnanswered,
                },
        ),
        onTap: !enabled && !allowed
            ? null
            : () {
                if (allowed) {
                  _openConsentHome(kind);
                } else {
                  unawaited(_allowConsent(kind));
                }
              },
      );
    }

    final offers = _declinedOffers > 0
        ? KitRow(
            key: const ValueKey('automation-consent-always-allow'),
            leading: KitRow.icon(context, AppIconography.privacy),
            title: l10n.consentRowAlwaysAllow,
            supporting: TextSpan(text: l10n.consentWhyAlwaysAllow),
            supportingMaxLines: 3,
            trailing: KitRowValue(
              l10n.consentValueDeclinedCount(_declinedOffers),
            ),
            onTap: () => unawaited(_offerAgain()),
          )
        : null;
    return [
      for (final answer in rows)
        if (answer.choice == InFlowConsentChoice.offered) row(answer),
      for (final answer in rows)
        if (answer.choice == InFlowConsentChoice.denied) row(answer),
      ?offers,
      for (final answer in rows)
        if (answer.choice == InFlowConsentChoice.accepted) row(answer),
    ];
  }
}
