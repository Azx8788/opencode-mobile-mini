/// Shared pieces of the AI Team plugin's enablement UI (TEAM-106): the
/// manual-add sheet (address + team name, probe on submit), the verdict copy for
/// every [ProbeVerdict], the host guide sheet and the turn-off confirmation.
/// Used by Settings › Plugins, the discovery card and the server editor so
/// the three entry points share one form and one set of words.
///
/// Transport rule (04-plugin-architecture §7, revised): `http://` is allowed
/// to loopback and tailnet addresses and refused elsewhere; the copy never
/// mentions HTTPS or `tailscale serve`.
library;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../orchestration/adapters/gascity/gascity_probe.dart';
import '../../state/profiles.dart';
import '../app_theme.dart';
import '../kit/kit_buttons.dart';
import '../kit/kit_code_block.dart';
import '../kit/kit_details_fold.dart';
import '../kit/kit_field.dart';
import '../kit/kit_notice.dart';
import '../kit/kit_sheet.dart';
import '../kit/kit_text.dart';
import '../kit/kit_tokens.dart';
import '../setup_commands.dart';
import 'external_link.dart';

export '../../orchestration/adapters/gascity/gascity_probe.dart'
    show
        ProbeCityNotRunning,
        ProbeFound,
        ProbeNotGasCity,
        ProbePlainHttpRefused,
        ProbeUnreachable,
        ProbeVerdict,
        isOrchestrationUrlAllowed,
        isTailnetHost;

/// Probes one address; never throws.
typedef TeamHostProbe =
    Future<ProbeVerdict> Function(String url, {String? city});

/// The real probe: [GasCityProbe] over the network.
Future<ProbeVerdict> defaultTeamHostProbe(String url, {String? city}) =>
    const GasCityProbe().probe(url, city: city);

/// The probe every AI Team form uses. Tests replace it with a fake so no
/// widget opens a socket; production leaves it at [defaultTeamHostProbe].
TeamHostProbe teamHostProbe = defaultTeamHostProbe;

/// The port a Gas City supervisor listens on by default.
const teamHostDefaultPort = 8372;

/// The port the host front (tool/host/cp_front) listens on by default.
const teamHostFrontPort = 8373;

/// The address the manual-add form prefills for a server profile: the
/// profile's own host on port [teamHostDefaultPort] over plain `http`, or
/// null when that would be refused (a public host) or the server URL has
/// no host. Discovery itself tries [teamDiscoveryUrlsFor].
String? teamDiscoveryUrlFor(String baseUrl) =>
    _teamHostUrl(baseUrl, teamHostDefaultPort);

/// The addresses discovery probes for a server profile, in order: the
/// profile's own host on the front port [teamHostFrontPort] first (a
/// front gives controls), then the bare supervisor port
/// [teamHostDefaultPort]. Empty when plain `http` to that host would be
/// refused or the server URL has no host.
List<String> teamDiscoveryUrlsFor(String baseUrl) => [
  ?_teamHostUrl(baseUrl, teamHostFrontPort),
  ?_teamHostUrl(baseUrl, teamHostDefaultPort),
];

String? _teamHostUrl(String baseUrl, int port) {
  final Uri parsed;
  try {
    parsed = Uri.parse(baseUrl.trim());
  } on FormatException {
    return null;
  }
  if (!parsed.hasAuthority || parsed.host.isEmpty) return null;
  final host = parsed.host.contains(':') ? '[${parsed.host}]' : parsed.host;
  final url = Uri.parse('http://$host:$port');
  return isOrchestrationUrlAllowed(url) ? url.toString() : null;
}

/// The plugin config a found verdict turns into for [url] / [city].
/// [hostKind] is the person's choice for the disclaimer (TEAM-206); it is
/// kept only when it belongs to the mode the host reports, so a phone host
/// never carries a laptop disclaimer.
OrchestrationConfig teamConfigFromVerdict(
  ProbeFound found, {
  required String url,
  required String city,
  OrchestrationHostKind? hostKind,
  DateTime? now,
}) => OrchestrationConfig(
  provider: OrchestrationProvider.gascity,
  url: url,
  city: city.isNotEmpty ? city : (found.city ?? ''),
  hostMode: found.host.hostMode,
  hostKind: hostKind != null && hostKind.mode == found.host.hostMode
      ? hostKind
      : null,
  front: !found.readOnly,
  enabledAt: (now ?? DateTime.now()).toUtc(),
);

/// The kinds the form offers; the phone kind comes from the host, never
/// from a choice.
const teamHostKindChoices = [
  OrchestrationHostKind.pc,
  OrchestrationHostKind.laptop,
  OrchestrationHostKind.wsl,
];

/// The form label of a choosable host kind.
String teamHostKindLabel(AppLocalizations l10n, OrchestrationHostKind kind) =>
    switch (kind) {
      OrchestrationHostKind.pc => l10n.teamUiHostKindDesktop,
      OrchestrationHostKind.laptop => l10n.teamUiHostKindLaptop,
      OrchestrationHostKind.wsl => l10n.teamUiHostKindWsl,
      OrchestrationHostKind.phone => l10n.teamUiHostModePhone,
    };

/// The product sentence for a verdict (03-onboarding §5), null for
/// [ProbeFound].
String? teamVerdictCopy(AppLocalizations l10n, ProbeVerdict verdict) =>
    switch (verdict) {
      ProbeFound() => null,
      ProbeNotGasCity() => l10n.teamUiVerdictNotGasCity,
      ProbeCityNotRunning() => l10n.teamUiVerdictCityNotRunning,
      ProbePlainHttpRefused() => l10n.teamUiTailnetRequired,
      ProbeUnreachable() => l10n.teamUiVerdictUnreachable,
    };

/// Opens the manual-add sheet. Returns the config to save once the probe
/// found a host (or the person chose to save an address that did not
/// answer), null when the person left without one.
Future<OrchestrationConfig?> showTeamHostSheet(
  BuildContext context, {
  String initialUrl = '',
  String initialCity = '',
  OrchestrationHostKind? initialHostKind,
  TeamHostProbe? probe,
}) {
  final l10n = lookupAppLocalizations(Localizations.localeOf(context));
  final actions = TeamHostFormActions._();
  // Until the form has built: Test and turn on, run through the form.
  actions.primary.value = KitAction(
    key: const ValueKey('team-host-submit'),
    label: l10n.teamUiAddSubmit,
    onPressed: actions._submit,
  );
  return showKitSheet<OrchestrationConfig>(
    context,
    title: l10n.teamUiAddTitle,
    icon: AppIconography.computer,
    primaryListenable: actions.primary,
    secondaryListenable: actions.secondary,
    body: (sheetContext) => TeamHostForm(
      initialUrl: initialUrl,
      initialCity: initialCity,
      initialHostKind: initialHostKind,
      probe: probe ?? teamHostProbe,
      onFound: (config) => Navigator.of(context).pop(config),
      actions: actions,
    ),
  ).whenComplete(actions._dispose);
}

/// The form's changing actions (Test and turn on, then Cancel test while
/// the test runs, then Save the address anyway after no answer), pinned by
/// the sheet that hosts the form so they stay in reach at any text size
/// while the fields scroll.
class TeamHostFormActions {
  TeamHostFormActions._();

  final primary = ValueNotifier<KitAction?>(null);
  final secondary = ValueNotifier<KitAction?>(null);

  /// The attached form's submit; null while no form is attached.
  VoidCallback? _handler;
  bool _disposed = false;

  void _submit() => _handler?.call();

  void _publish(KitAction primary, KitAction? secondary) {
    if (_disposed) return;
    this.primary.value = primary;
    this.secondary.value = secondary;
  }

  void _dispose() {
    _disposed = true;
    primary.dispose();
    secondary.dispose();
  }
}

/// Address and team name, one submit that tests the address and reports
/// the verdict (the manual fallback to discovery).
///
/// Map `team-host-sheet` (fix): the test is progress while it runs, with
/// Cancel test; a failed test says why in one notice and keeps the raw
/// error under Connection details; an address that did not answer can be
/// saved anyway (the team page then says it is not answering). The "kind
/// of computer" question is gone: the kind comes from [initialHostKind] or
/// the host itself.
///
/// Inside [showTeamHostSheet] its actions are pinned by the sheet through
/// [actions]; without it (a page that hosts the form) they close the form.
class TeamHostForm extends StatefulWidget {
  const TeamHostForm({
    super.key = const ValueKey('team-host-form'),
    required this.probe,
    required this.onFound,
    this.initialUrl = '',
    this.initialCity = '',
    this.initialHostKind,
    this.actions,
  });

  final TeamHostProbe probe;
  final ValueChanged<OrchestrationConfig> onFound;
  final String initialUrl;
  final String initialCity;

  /// The kind the config carries for the disclaimer; null (or a kind the
  /// form does not offer, such as the phone) is [OrchestrationHostKind.pc].
  final OrchestrationHostKind? initialHostKind;

  /// Where the sheet pins the form's actions; null draws them under the
  /// fields.
  final TeamHostFormActions? actions;

  @override
  State<TeamHostForm> createState() => _TeamHostFormState();
}

class _TeamHostFormState extends State<TeamHostForm> {
  late final TextEditingController _url = TextEditingController(
    text: widget.initialUrl,
  );
  late final TextEditingController _city = TextEditingController(
    text: widget.initialCity,
  );

  /// The address field, focused again when the person comes back from the
  /// host guide through "Enter the address".
  final FocusNode _urlFocus = FocusNode();
  late final OrchestrationHostKind _kind =
      teamHostKindChoices.contains(widget.initialHostKind)
      ? widget.initialHostKind!
      : OrchestrationHostKind.pc;
  bool _testing = false;

  /// Bumped by every test and by Cancel test: an answer for an older test
  /// is dropped.
  int _test = 0;
  String? _failure;
  bool _failureIsUnavailable = false;

  /// The address that did not answer, when it may be saved anyway.
  String? _unanswered;

  /// The raw platform error behind an unreachable verdict, kept under
  /// Details so a real cause ("Connection refused", a cleartext block, a
  /// DNS miss) is there when someone needs it.
  String? _failureDetail;

  @override
  void initState() {
    super.initState();
    widget.actions?._handler = _submit;
  }

  @override
  void dispose() {
    final actions = widget.actions;
    if (actions != null && actions._handler == _submit) {
      actions._handler = null;
    }
    _url.dispose();
    _city.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  /// A state change: rebuilds the form and re-pins the sheet's actions.
  /// Only called from events, never while building.
  void _update(VoidCallback change) {
    setState(change);
    final actions = widget.actions;
    if (actions == null) return;
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    actions._publish(_primary(l10n), _secondary(l10n));
  }

  KitAction _primary(AppLocalizations l10n) => KitAction(
    key: const ValueKey('team-host-submit'),
    label: _testing ? l10n.teamUiAddTesting : l10n.teamUiAddSubmit,
    working: _testing,
    onPressed: _submit,
  );

  KitAction? _secondary(AppLocalizations l10n) => _testing
      ? KitAction(
          key: const ValueKey('team-host-cancel-test'),
          label: l10n.teamHostFormCancelTest,
          onPressed: _cancelTest,
        )
      : _unanswered != null
      ? KitAction(
          key: const ValueKey('team-host-save-anyway'),
          label: l10n.teamHostFormSaveAnyway,
          onPressed: _saveAnyway,
        )
      : null;

  void _fail(String message, {bool unavailable = false}) {
    _update(() {
      _failure = message;
      _failureIsUnavailable = unavailable;
      _failureDetail = null;
      _unanswered = null;
    });
  }

  Future<void> _submit() async {
    if (_testing) return;
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final url = _url.text.trim();
    final city = _city.text.trim();
    if (url.isEmpty) {
      _fail(l10n.teamUiAddressRequired);
      return;
    }
    // The transport rule is decided before any request, with the tailnet
    // wording, so a public address never waits for a timeout.
    final parsed = Uri.tryParse(url);
    if (parsed == null ||
        !parsed.hasAuthority ||
        (parsed.scheme == 'http' && !isOrchestrationUrlAllowed(parsed))) {
      _fail(
        parsed != null && parsed.scheme == 'http'
            ? l10n.teamUiTailnetRequired
            : l10n.teamUiVerdictUnreachable,
      );
      return;
    }
    FocusScope.of(context).unfocus();
    final test = ++_test;
    _update(() {
      _testing = true;
      _failure = null;
      _failureDetail = null;
      _unanswered = null;
    });
    final verdict = await widget.probe(url, city: city.isEmpty ? null : city);
    if (!mounted || test != _test) return;
    if (verdict is ProbeFound) {
      _update(() => _testing = false);
      widget.onFound(
        teamConfigFromVerdict(verdict, url: url, city: city, hostKind: _kind),
      );
      return;
    }
    _update(() {
      _testing = false;
      _failure = teamVerdictCopy(l10n, verdict);
      _failureIsUnavailable = verdict is ProbeNotGasCity;
      _unanswered = verdict is ProbeUnreachable ? url : null;
      _failureDetail = switch (verdict) {
        ProbeUnreachable(:final error) => _errorDetail(error),
        _ => null,
      };
    });
  }

  /// Cancel test, or an edit while the test runs: the answer, when it
  /// comes, is dropped (it would be for the old words).
  void _cancelTest() {
    if (!_testing) return;
    _update(() {
      _test++;
      _testing = false;
    });
  }

  /// Saves an address that did not answer (the computer may be asleep):
  /// read-only until it answers, like any team that is not answering.
  void _saveAnyway() {
    final url = _unanswered;
    if (url == null) return;
    widget.onFound(
      OrchestrationConfig(
        provider: OrchestrationProvider.gascity,
        url: url,
        city: _city.text.trim(),
        hostKind: _kind,
        enabledAt: DateTime.now().toUtc(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final tokens = KitTokens.of(context);
    final failure = _failure;
    final detail = _failureDetail;
    final gap = SizedBox(height: tokens.space4);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KitField(
          label: l10n.teamUiAddAddressLabel,
          hint: l10n.teamUiAddAddressHint,
          controller: _url,
          focusNode: _urlFocus,
          kind: KitFieldKind.url,
          onChanged: (_) => _cancelTest(),
          autofocus: widget.initialUrl.isEmpty,
          textInputAction: TextInputAction.next,
          fieldKey: const ValueKey('team-host-url'),
        ),
        gap,
        KitField(
          label: l10n.teamHostFormTeamLabel,
          helper: l10n.teamHostFormTeamHelper,
          controller: _city,
          kind: KitFieldKind.mono,
          onChanged: (_) => _cancelTest(),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          fieldKey: const ValueKey('team-host-city'),
        ),
        if (failure != null) ...[
          gap,
          KitNotice(
            key: const ValueKey('team-host-verdict'),
            tone: AppStatusTone.failure,
            message: failure,
            notes: [if (_unanswered != null) l10n.teamHostFormSaveAnywayNote],
            actions: [
              if (_failureIsUnavailable)
                KitAction(
                  key: const ValueKey('team-host-verdict-how'),
                  label: l10n.teamHostFormHowAction,
                  // The guide's "Enter the address" comes back here.
                  onPressed: () => showTeamHostGuideSheet(
                    context,
                    enterAddress: () async {
                      if (mounted) _urlFocus.requestFocus();
                    },
                  ),
                ),
            ],
          ),
        ],
        if (widget.actions == null) ...[
          gap,
          KitActionBlock(primary: _primary(l10n), secondary: _secondary(l10n)),
        ],
        // The raw error, last and folded (KIT-33).
        if (detail != null && detail.isNotEmpty) ...[
          if (widget.actions != null) gap,
          KitDetailsFold(
            label: l10n.teamHostFormConnectionDetails,
            text: detail,
            textKey: const ValueKey('team-host-verdict-detail'),
          ),
        ],
      ],
    );
  }
}

// revamp: redesign (slice-P3.4, slice-close-security, slice-team-g17)
/// The four host steps of docs/ai-team-host.md, as a sheet; the app has no
/// bundled markdown viewer for repository docs. Each step is one sentence
/// and its exact command in the kit's code block, with Copy; the front is
/// downloaded from a pinned commit and checked against its SHA-256 before
/// it runs ([HostScripts]). "Open the full guide" opens the published guide
/// in the browser, never a file in the repository.
///
/// The next step is the team's address (map `team-host-guide-sheet`): with
/// [enterAddress], the sheet's primary is "Enter the address", which closes
/// the guide and then runs [enterAddress] — the address form, or, from the
/// form itself, back to its field. Without it (a team that is already
/// added, where the guide only explains the host side) the sheet has no
/// primary.
Future<void> showTeamHostGuideSheet(
  BuildContext context, {
  Future<void> Function()? enterAddress,
}) async {
  final l10n = lookupAppLocalizations(Localizations.localeOf(context));
  final steps = [
    (l10n.teamUiHostGuideStep1, HostScripts.teamCheckTools),
    (l10n.teamUiHostGuideStep2, HostScripts.teamCreateCity),
    (l10n.teamUiHostGuideStep3, HostScripts.teamStart),
    (l10n.teamUiHostGuideStep4, HostScripts.teamFront),
  ];
  BuildContext? sheetBody;
  final chosen = await showKitSheet<bool>(
    context,
    sheetKey: const ValueKey('team-host-guide'),
    title: l10n.teamUiHostGuideTitle,
    primary: enterAddress == null
        ? null
        : KitAction(
            key: const ValueKey('team-host-guide-enter-address'),
            label: l10n.teamUiHostGuideEnterAddress,
            onPressed: () {
              final inside = sheetBody;
              if (inside != null && inside.mounted) {
                KitSheet.close(inside, true);
              }
            },
          ),
    body: (sheetContext) {
      sheetBody = sheetContext;
      final tokens = KitTokens.of(sheetContext);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsetsDirectional.only(bottom: tokens.space4),
            child: KitText(
              l10n.teamUiHostGuideIntro,
              role: KitTextRole.secondary,
              tone: KitTextTone.secondary,
            ),
          ),
          for (final (i, (step, command)) in steps.indexed)
            Padding(
              padding: EdgeInsetsDirectional.only(bottom: tokens.space4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: KitTokens.markSlotSize,
                    child: KitText(
                      _stepNumber(i),
                      role: KitTextRole.rowTitle,
                      tabular: true,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        KitText(step),
                        SizedBox(height: tokens.space2),
                        KitCodeBlock(
                          text: command,
                          kind: KitCodeKind.command,
                          // Several lines get a labelled Copy in a header; one line
                          // keeps the kit's own Copy on the line.
                          copyLabel: command.contains('\n')
                              ? l10n.kitCodeCopyCommand
                              : null,
                          copyKey: ValueKey('team-host-guide-copy-${i + 1}'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: KitButton.tertiary(
              key: const ValueKey('team-host-guide-open'),
              label: l10n.teamUiHostGuideOpen,
              icon: AppIconography.externalLink,
              onPressed: () =>
                  openExternalLink(sheetContext, HostScripts.teamGuideUrl),
            ),
          ),
        ],
      );
    },
  );
  if (chosen == true && enterAddress != null && context.mounted) {
    await enterAddress();
  }
}

/// "1." … for the guide steps; digits stay Western in every locale, as the
/// commands beside them do.
String _stepNumber(int index) => '${index + 1}.';

/// The turn-off confirmation of 02-ux §1.3. True when the person confirmed.
/// It removes the team's data from this phone, so it is the destructive
/// question; the host itself is untouched.
Future<bool> showTeamTurnOffSheet(BuildContext context, String serverName) {
  final l10n = lookupAppLocalizations(Localizations.localeOf(context));
  return showKitConfirm(
    context,
    title: l10n.teamUiTurnOffTitle(serverName),
    body: l10n.teamUiTurnOffBody,
    confirmLabel: l10n.teamUiTurnOffConfirm,
    cancelLabel: l10n.teamUiKeep,
    kind: KitConfirmKind.destructive,
    icon: AppIconography.unlink,
    sheetKey: const ValueKey('team-turn-off-sheet'),
    confirmKey: const ValueKey('team-turn-off-confirm'),
  );
}

/// One line of the platform's own words for [error], trimmed: the Dio
/// wrapper text is dropped in favour of the underlying exception when there
/// is one, and long messages are cut at 240 characters.
String _errorDetail(Object error) {
  var text = error.toString();
  final inner = RegExp(
    r'(SocketException|HandshakeException|HttpException|TimeoutException|FormatException|OS Error)[^\n]*',
  ).firstMatch(text);
  if (inner != null) text = inner.group(0)!;
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.length > 240 ? '${text.substring(0, 240)}…' : text;
}
