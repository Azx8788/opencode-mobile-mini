import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:opencode_mobile/ui/kit/kit_buttons.dart';
import 'package:opencode_mobile/ui/kit/kit_code_block.dart';
import 'package:opencode_mobile/ui/kit/kit_copy.dart';
import 'package:opencode_mobile/ui/kit/kit_details_fold.dart';
import 'package:opencode_mobile/ui/kit/kit_notice.dart';
import 'package:opencode_mobile/ui/kit/kit_qr.dart';
import 'package:opencode_mobile/ui/kit/kit_row.dart';
import 'package:opencode_mobile/ui/kit/kit_row_parts.dart';
import 'package:opencode_mobile/ui/kit/kit_sheet.dart';
import 'package:opencode_mobile/ui/kit/kit_text.dart';
import 'package:opencode_mobile/ui/kit/kit_tokens.dart';

import '../../domain/server_gateway.dart' show ServerCapabilities;
import '../../domain/session_handoff.dart';
import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import '../../state/profiles.dart';
import '../../state/session_address_controller.dart';
import '../app_iconography.dart';
import 'session_address_sheets.dart';

AppLocalizations _l10n(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

/// The CLI versions the resume syntax was verified against, for the sheet's
/// Details fold. Recorded in docs/qa/f4-session-handoff/README.md with the
/// exact `--help` output.
const sessionResumeVerifiedVersions = 'opencode 1.18.25, opencode2 beta-19242';

/// What they pop with when the person picks "Reload conversation" on the
/// unavailable state (only offered when the host passes `offerReload`).
const continueOnComputerReload = 'reload';

/// F4-S1 in the kit sheet frame: the terminal command that resumes this
/// session on the computer running the server, wrapped so all of it shows.
/// Resolves to [continueOnComputerReload] when the person asks to reload a
/// conversation whose folder the server did not report, and null when they
/// close it. The sheet itself never connects or sends anything; copying
/// only writes the clipboard. Export lives in the conversation menu.
Future<String?> showContinueOnComputerSheet(
  BuildContext context, {
  required SessionResumeCommand command,
  bool offerReload = false,
}) {
  final l10n = _l10n(context);
  return showKitSheet<String>(
    context,
    title: l10n.handoffUiComputerTitle,
    icon: AppIconography.computer,
    body: (context) =>
        _ContinueOnComputerBody(command: command, offerReload: offerReload),
  );
}

/// F4-S2 in the kit sheet frame: see [ContinueOnPhoneSheet]. [address],
/// when given, adds the per-link "Include this server's address" switch.
Future<void> showContinueOnPhoneSheet(
  BuildContext context, {
  required SessionLink? link,
  SessionAddressOffer? address,
}) {
  final l10n = _l10n(context);
  return showKitSheet<void>(
    context,
    title: l10n.handoffUiPhoneTitle,
    icon: AppIconography.qrCode,
    body: (context) => _ContinueOnPhoneBody(link: link, address: address),
  );
}

/// "Include this server's address" on Open on another phone (contract P3.9):
/// the address shown beside the switch and the one way to build the portable
/// link. It exists only when the connected server reports
/// [ServerCapabilities.sessionAddressHandoff] AND the address coordinator is
/// admitted; otherwise [forSession] is null and the sheet shows the local
/// link exactly as before, with no switch.
class SessionAddressOffer {
  const SessionAddressOffer({
    required this.hostPort,
    required String Function({required bool includeServerAddress}) build,
  }) : _build = build;

  /// The normalized host and effective port ("device.tailnet.ts.net:443"),
  /// or null when the saved address cannot go in a link (only a private
  /// HTTPS `.ts.net` name can): the switch then says why and stays off.
  final String? hostPort;

  final String Function({required bool includeServerAddress}) _build;

  /// Builds the portable link again, from the switch's own value: never
  /// cached, so a secret registered since the last build is refused. Throws
  /// [SessionAddressFailure] (consentRequired while the switch is off).
  String build({required bool includeServerAddress}) =>
      _build(includeServerAddress: includeServerAddress);

  static SessionAddressOffer? forSession({
    required ServerCapabilities capabilities,
    required SessionAddressController addresses,
    required ServerProfile? profile,
    required String sessionID,
  }) {
    if (!capabilities.sessionAddressHandoff ||
        !addresses.available ||
        profile == null) {
      return null;
    }
    String? hostPort;
    try {
      hostPort = sessionAddressHostPort(
        SessionAddressLink.normalizeOrigin(profile.baseUrl),
      );
    } on SessionAddressFailure {
      hostPort = null;
    }
    final profileID = profile.id;
    return SessionAddressOffer(
      hostPort: hostPort,
      build: ({required includeServerAddress}) => addresses.buildForProfile(
        profileID,
        sessionID,
        includeServerAddress: includeServerAddress,
      ),
    );
  }

  /// The same, from the app's providers: what the conversation menu passes.
  static SessionAddressOffer? of(
    BuildContext context, {
    required ConnectionController connection,
    required String sessionID,
  }) => forSession(
    capabilities: connection.capabilities,
    addresses: ProviderScope.containerOf(
      context,
      listen: false,
    ).read(sessionAddressProvider),
    profile: connection.profile,
    sessionID: sessionID,
  );
}

/// F4-S1 as a whole sheet (header and body) for a host that opens its own
/// modal route; [showContinueOnComputerSheet] is the kit way to open it.
/// Pops with [continueOnComputerReload]; otherwise closes with null.
class ContinueOnComputerSheet extends StatelessWidget {
  const ContinueOnComputerSheet({
    super.key,
    required this.command,
    this.offerReload = false,
  });

  final SessionResumeCommand command;

  /// Offer "Reload conversation" when the server did not report a folder;
  /// the host reloads the conversation and opens the sheet again.
  final bool offerReload;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    return KitSheet(
      title: l10n.handoffUiComputerTitle,
      icon: AppIconography.computer,
      // The host's modal route draws its own drag handle.
      handle: false,
      onClose: () => Navigator.maybePop(context),
      child: _ContinueOnComputerBody(
        command: command,
        offerReload: offerReload,
      ),
    );
  }
}

class _ContinueOnComputerBody extends StatelessWidget {
  const _ContinueOnComputerBody({
    required this.command,
    required this.offerReload,
  });

  final SessionResumeCommand command;
  final bool offerReload;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final tokens = KitTokens.of(context);
    final binary = command.binary;
    final unavailable = command.unavailable;
    final gap = SizedBox(height: tokens.space3);
    return Column(
      key: const Key('continue-on-computer-sheet'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KitText(l10n.handoffUiComputerIntro(binary)),
        gap,
        if (command.command case final text?) ...[
          KitCodeBlock(
            text: text,
            // The command is what this sheet exists to show: all of it,
            // wrapped under its prompt, never cut at the sheet's edge
            // (R3's hanging wrap), with the command's own copy label.
            kind: KitCodeKind.command,
            caption: l10n.handoffUiComputerCommandLabel,
            wrap: true,
            showWrapToggle: false,
            highlight: false,
            copyLabel: l10n.handoffSheetCopyCommand,
            blockKey: const Key('continue-on-computer-command'),
            copyKey: const Key('continue-on-computer-copy'),
          ),
          gap,
          KitText(
            l10n.handoffUiComputerDirectoryNote,
            role: KitTextRole.secondary,
            tone: KitTextTone.secondary,
          ),
          gap,
          KitDetailsFold(
            foldKey: const Key('continue-on-computer-details'),
            notes: [
              l10n.handoffUiComputerVerify(
                sessionResumeVerifiedVersions,
                binary,
              ),
            ],
          ),
        ] else
          KitNotice(
            key: const Key('continue-on-computer-unavailable'),
            icon: AppIconography.info,
            message: switch (unavailable) {
              SessionResumeUnavailable.managedWorkspace =>
                l10n.handoffUiUnavailableWorkspace,
              SessionResumeUnavailable.invalidSessionID =>
                l10n.handoffUiUnavailableReference,
              SessionResumeUnavailable.missingDirectory ||
              SessionResumeUnavailable.unsafeDirectory ||
              null => l10n.handoffUiUnavailableDirectory,
            },
            actions: [
              // Reloading helps only when the folder was not reported; a
              // cloud environment or an unsafe reference stays unavailable.
              if (offerReload &&
                  (unavailable == SessionResumeUnavailable.missingDirectory ||
                      unavailable == null))
                KitAction(
                  key: const Key('continue-on-computer-reload'),
                  label: l10n.handoffSheetReloadConversation,
                  icon: AppIconography.retry,
                  onPressed: () =>
                      Navigator.pop(context, continueOnComputerReload),
                ),
            ],
          ),
      ],
    );
  }
}

/// F4-S2: a QR code carrying the `opencode-mobile://session` link for this
/// session, plus the same link as text with a copy button, as a whole
/// sheet for a host that opens its own modal route
/// ([showContinueOnPhoneSheet] is the kit way). Route identifiers only; the
/// sheet cannot leak more than [SessionLink] holds.
class ContinueOnPhoneSheet extends StatelessWidget {
  const ContinueOnPhoneSheet({super.key, required this.link, this.address});

  /// Null when either identifier failed validation; the sheet then shows
  /// its unavailable state instead of guessing.
  final SessionLink? link;

  /// The opt-in to include this server's address; null hides it.
  final SessionAddressOffer? address;

  @override
  Widget build(BuildContext context) => KitSheet(
    title: _l10n(context).handoffUiPhoneTitle,
    icon: AppIconography.qrCode,
    handle: false,
    onClose: () => Navigator.maybePop(context),
    child: _ContinueOnPhoneBody(link: link, address: address),
  );
}

class _ContinueOnPhoneBody extends StatefulWidget {
  const _ContinueOnPhoneBody({required this.link, this.address});

  final SessionLink? link;
  final SessionAddressOffer? address;

  @override
  State<_ContinueOnPhoneBody> createState() => _ContinueOnPhoneBodyState();
}

class _ContinueOnPhoneBodyState extends State<_ContinueOnPhoneBody> {
  /// Off every time the sheet opens: opening it is not consent to show the
  /// server's address.
  bool _include = false;

  /// The portable link built for this switch-on, shown as QR and text. Only
  /// ever set from [SessionAddressOffer.build] with the switch on.
  String? _portable;
  SessionAddressFailureCode? _failure;

  void _rebuild() {
    _portable = null;
    _failure = null;
    final address = widget.address;
    if (!_include || address == null) return;
    try {
      _portable = address.build(includeServerAddress: _include);
    } on SessionAddressFailure catch (failure) {
      _failure = failure.code;
    } catch (_) {
      _failure = SessionAddressFailureCode.unavailable;
    }
  }

  void _setInclude(bool on) => setState(() {
    _include = on;
    _rebuild();
  });

  /// Copy builds the link again rather than reusing the shown one.
  Future<void> _copyPortable() async {
    setState(_rebuild);
    final text = _portable;
    if (text == null) return;
    await KitCopy.copy(context, text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final tokens = KitTokens.of(context);
    final link = widget.link;
    final address = link == null ? null : widget.address;
    final portable = _include ? _portable : null;
    final gap = SizedBox(height: tokens.space3);
    return Column(
      key: const Key('continue-on-phone-sheet'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KitText(_include ? l10n.sessionAddressIntro : l10n.handoffUiPhoneIntro),
        gap,
        if (address != null) ...[
          KitRowGroup(
            margin: EdgeInsets.zero,
            children: [
              KitSwitchRow(
                switchKey: const Key('session-address-include'),
                leading: const KitRowIcon(AppIconography.server),
                title: l10n.sessionAddressInclude,
                supporting: address.hostPort,
                value: _include,
                onChanged: address.hostPort == null ? null : _setInclude,
                disabledReason: l10n.sessionAddressUnsupportedHost,
              ),
            ],
          ),
          if (address.hostPort != null) ...[
            gap,
            KitText(
              l10n.sessionAddressDisclosure,
              key: const Key('session-address-disclosure'),
              role: KitTextRole.secondary,
              tone: KitTextTone.secondary,
            ),
          ],
          gap,
        ],
        if (link == null)
          KitNotice(
            key: const Key('continue-on-phone-unavailable'),
            icon: AppIconography.info,
            message: l10n.handoffUiPhoneUnavailable,
          )
        else if (_include && _failure != null)
          // The address could not go in: say why, and show no code at all
          // rather than silently falling back to the local link.
          SessionAddressFailureNotice(code: _failure!)
        else if (portable != null) ...[
          Center(
            child: KitQr(
              data: portable,
              semanticsLabel: l10n.handoffUiPhoneQrLabel,
              qrKey: const Key('session-address-qr'),
            ),
          ),
          gap,
          KitCodeBlock(
            text: portable,
            kind: KitCodeKind.output,
            caption: l10n.handoffUiPhoneLinkLabel,
            wrap: true,
            showWrapToggle: false,
            highlight: false,
            copyable: false,
            blockKey: const Key('session-address-link'),
          ),
          gap,
          KitButton.secondary(
            key: const Key('session-address-copy'),
            label: l10n.handoffUiPhoneCopyLink,
            icon: AppIconography.copy,
            onPressed: _copyPortable,
          ),
        ] else ...[
          Center(
            child: KitQr(
              data: link.toString(),
              semanticsLabel: l10n.handoffUiPhoneQrLabel,
              qrKey: const Key('session-link-qr'),
            ),
          ),
          gap,
          KitCodeBlock(
            text: link.toString(),
            kind: KitCodeKind.output,
            caption: l10n.handoffUiPhoneLinkLabel,
            wrap: true,
            showWrapToggle: false,
            highlight: false,
            copyLabel: l10n.handoffUiPhoneCopyLink,
            blockKey: const Key('continue-on-phone-link'),
            copyKey: const Key('continue-on-phone-copy'),
          ),
          gap,
          // What happens on a phone that does not have this server yet: it
          // says so and offers Servers (handoffUiLinkServerMissing).
          KitNotice(
            key: const Key('continue-on-phone-server-note'),
            icon: AppIconography.server,
            message: l10n.handoffSheetPhoneServerNote,
            liveRegion: false,
          ),
        ],
      ],
    );
  }
}
