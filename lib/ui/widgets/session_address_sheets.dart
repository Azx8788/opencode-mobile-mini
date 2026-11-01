import 'package:flutter/material.dart';

import 'package:opencode_mobile/ui/kit/kit_buttons.dart';
import 'package:opencode_mobile/ui/kit/kit_notice.dart';
import 'package:opencode_mobile/ui/kit/kit_progress.dart';
import 'package:opencode_mobile/ui/kit/kit_row.dart';
import 'package:opencode_mobile/ui/kit/kit_row_parts.dart';
import 'package:opencode_mobile/ui/kit/kit_sheet.dart';
import 'package:opencode_mobile/ui/kit/kit_technical_value.dart';
import 'package:opencode_mobile/ui/kit/kit_text.dart';
import 'package:opencode_mobile/ui/kit/kit_tokens.dart';

import '../../l10n/app_localizations.dart';
import '../../state/profiles.dart';
import '../../state/session_address_controller.dart';
import '../app_theme.dart';

AppLocalizations _l10n(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

/// The normalized host and effective port of a canonical link origin
/// ("device.tailnet.ts.net:443"): the one address both sheets show. The
/// port is spelled out even when the origin omits the default 443.
String sessionAddressHostPort(String origin) {
  final uri = Uri.parse(origin);
  return '${uri.host}:${uri.port}';
}

/// Every failure category in plain words (contract table in
/// docs/qa/codex-sessionlink-2026-09-28/README.md). No exception text, link,
/// host, installation or session ID is ever interpolated.
String sessionAddressFailureText(
  AppLocalizations l10n,
  SessionAddressFailureCode code,
) => switch (code) {
  SessionAddressFailureCode.unavailable => l10n.sessionAddressFailUnavailable,
  SessionAddressFailureCode.invalidLink => l10n.sessionAddressFailInvalidLink,
  SessionAddressFailureCode.tooLarge => l10n.sessionAddressFailTooLarge,
  SessionAddressFailureCode.credentials => l10n.sessionAddressFailCredentials,
  SessionAddressFailureCode.consentRequired =>
    l10n.sessionAddressFailConsentRequired,
  SessionAddressFailureCode.privateRouteRequired =>
    l10n.sessionAddressFailPrivateRouteRequired,
  SessionAddressFailureCode.unreachable => l10n.sessionAddressFailUnreachable,
  SessionAddressFailureCode.timedOut => l10n.sessionAddressFailTimedOut,
  SessionAddressFailureCode.tlsRejected => l10n.sessionAddressFailTlsRejected,
  SessionAddressFailureCode.redirectsRejected =>
    l10n.sessionAddressFailRedirectsRejected,
  SessionAddressFailureCode.accessDenied => l10n.sessionAddressFailAccessDenied,
  SessionAddressFailureCode.invalidDescriptor =>
    l10n.sessionAddressFailInvalidDescriptor,
  SessionAddressFailureCode.instanceMismatch =>
    l10n.sessionAddressFailInstanceMismatch,
  SessionAddressFailureCode.bindingRequired =>
    l10n.sessionAddressFailBindingRequired,
  SessionAddressFailureCode.ambiguousProfile =>
    l10n.sessionAddressFailAmbiguousProfile,
  SessionAddressFailureCode.profileMissing =>
    l10n.sessionAddressFailProfileMissing,
  SessionAddressFailureCode.storage => l10n.sessionAddressFailStorage,
  SessionAddressFailureCode.signInRequired =>
    l10n.sessionAddressFailSignInRequired,
  SessionAddressFailureCode.unsafeLookup => l10n.sessionAddressFailUnsafeLookup,
  SessionAddressFailureCode.sessionMissing =>
    l10n.sessionAddressFailSessionMissing,
  SessionAddressFailureCode.cancelled => l10n.sessionAddressFailCancelled,
};

/// A failure in words plus the fixed category under Details: the only
/// technical text either sheet shows. [actions] is the way forward.
class SessionAddressFailureNotice extends StatelessWidget {
  const SessionAddressFailureNotice({
    super.key,
    required this.code,
    this.actions = const [],
  });

  final SessionAddressFailureCode code;
  final List<KitAction> actions;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final tokens = KitTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KitNotice(
          key: const Key('session-address-failure'),
          tone: AppStatusTone.failure,
          icon: AppIconography.error,
          message: sessionAddressFailureText(l10n, code),
          actions: actions,
        ),
        SizedBox(height: tokens.space3),
        KitDetailsFold(
          foldKey: const Key('session-address-details'),
          values: [
            KitTechnicalValue(
              l10n.sessionAddressReason,
              code.name,
              key: const Key('session-address-reason'),
            ),
          ],
        ),
      ],
    );
  }
}

/// What the incoming-link sheet resolves with once the conversation was
/// found: the saved server and the existing conversation to navigate to.
/// Nothing was created, resumed or sent.
@immutable
class SessionAddressOpened {
  const SessionAddressOpened({
    required this.profileId,
    required this.sessionId,
  });

  final String profileId;
  final String sessionId;
}

/// The receiving side of a link that carries a server address (contract
/// P3.9, "Receiver and UI contract"). [controller] has already received the
/// link (network-silent); this sheet shows its stage in plain words and asks
/// before every step that reaches out: checking the server, adding it,
/// verifying a saved one, opening the conversation. Nothing connects on its
/// own. [failure] is a link that failed local parsing before it reached the
/// controller (only the category survives).
///
/// Closing the sheet cancels the controller, so the locator is consumed and
/// no late result lands anywhere. [onAddServer] opens Add server with only
/// the validated address filled in; [onSignIn] opens the saved server's own
/// sign-in. Both return when the person comes back.
Future<SessionAddressOpened?> showSessionAddressSheet(
  BuildContext context, {
  required SessionAddressController controller,
  SessionAddressFailureCode? failure,
  required Future<void> Function(String origin) onAddServer,
  required Future<void> Function(String profileId) onSignIn,
}) async {
  final l10n = _l10n(context);
  final opened = await showKitSheet<SessionAddressOpened>(
    context,
    title: l10n.sessionAddressOpenTitle,
    icon: AppIconography.link,
    sheetKey: const Key('session-address-sheet'),
    body: (context) => SessionAddressSheetBody(
      controller: controller,
      failure: failure,
      onAddServer: onAddServer,
      onSignIn: onSignIn,
    ),
  );
  controller.cancel();
  return opened;
}

/// The sheet's body, public so a host with its own modal route (and the
/// gallery) can place it; [showSessionAddressSheet] is the kit way.
class SessionAddressSheetBody extends StatefulWidget {
  const SessionAddressSheetBody({
    super.key,
    required this.controller,
    this.failure,
    required this.onAddServer,
    required this.onSignIn,
  });

  final SessionAddressController controller;
  final SessionAddressFailureCode? failure;
  final Future<void> Function(String origin) onAddServer;
  final Future<void> Function(String profileId) onSignIn;

  @override
  State<SessionAddressSheetBody> createState() =>
      _SessionAddressSheetBodyState();
}

/// Categories a person can reasonably retry right away: the connection, not
/// the link or the server's answer about access.
const _retryable = {
  SessionAddressFailureCode.privateRouteRequired,
  SessionAddressFailureCode.unreachable,
  SessionAddressFailureCode.timedOut,
  SessionAddressFailureCode.invalidDescriptor,
  SessionAddressFailureCode.storage,
};

class _SessionAddressSheetBodyState extends State<SessionAddressSheetBody> {
  SessionAddressFailureCode? _localFailure;
  bool _popped = false;

  SessionAddressController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _localFailure = widget.failure;
    _c.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
  }

  @override
  void didUpdateWidget(SessionAddressSheetBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    // A newer link replaced the one that failed to parse.
    if (_c.phase != SessionAddressPhase.idle) _localFailure = null;
    final session = _c.openedSession;
    final profileId = _c.profileId;
    if (_c.phase == SessionAddressPhase.opened &&
        session != null &&
        profileId != null &&
        !_popped) {
      _popped = true;
      Navigator.of(
        context,
      ).pop(SessionAddressOpened(profileId: profileId, sessionId: session.id));
      return;
    }
    setState(() {});
  }

  List<ServerProfile> _matching(String origin) => [
    for (final profile in _c.store.profiles)
      if (_sameOrigin(profile.baseUrl, origin)) profile,
  ];

  static bool _sameOrigin(String raw, String origin) {
    try {
      return SessionAddressLink.normalizeOrigin(raw) == origin;
    } on SessionAddressFailure {
      return false;
    }
  }

  ServerProfile? _profile(String? id) {
    for (final profile in _c.store.profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  Future<void> _addServer(String origin) async {
    await widget.onAddServer(origin);
    if (!mounted || _c.phase != SessionAddressPhase.addServer) return;
    // The server the person just added for this link: select it, then the
    // verify step still asks before anything is remembered or opened.
    final added = _matching(origin);
    if (added.length == 1) {
      _c.selectProfile(added.single.id);
    } else {
      setState(() {});
    }
  }

  Widget _serverRow(String hostPort, String supporting) => KitRowGroup(
    margin: EdgeInsets.zero,
    children: [
      KitRow(
        leading: const KitRowIcon(AppIconography.server),
        title: hostPort,
        titleMaxLines: 2,
        titleKey: const Key('session-address-host'),
        supporting: TextSpan(text: supporting),
      ),
    ],
  );

  Widget _chooser(List<ServerProfile> profiles, String hostPort) => KitRowGroup(
    margin: EdgeInsets.zero,
    children: [
      for (final profile in profiles)
        KitRow(
          key: Key('session-address-choose-${profile.id}'),
          leading: const KitRowIcon(AppIconography.server),
          title: profile.name,
          supporting: TextSpan(text: hostPort),
          onTap: () => _c.selectProfile(profile.id),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final tokens = KitTokens.of(context);
    final gap = SizedBox(height: tokens.space3);
    final link = _c.pending;
    final local = _localFailure;
    final List<Widget> children;
    if (local != null || link == null) {
      children = [
        SessionAddressFailureNotice(
          code: local ?? _c.failure ?? SessionAddressFailureCode.cancelled,
        ),
      ];
    } else {
      final origin = link.origin;
      final hostPort = sessionAddressHostPort(origin);
      final saved = _matching(origin);
      final chosen = _profile(_c.profileId);
      children = switch (_c.phase) {
        SessionAddressPhase.idle => [
          const SessionAddressFailureNotice(
            code: SessionAddressFailureCode.cancelled,
          ),
        ],
        SessionAddressPhase.awaitingConsent => [
          KitText(
            saved.isEmpty
                ? l10n.sessionAddressConsentNew
                : l10n.sessionAddressConsentSaved,
            role: KitTextRole.headline,
          ),
          gap,
          _serverRow(
            hostPort,
            saved.isEmpty
                ? l10n.sessionAddressNotSaved
                : saved.map((p) => p.name).join(', '),
          ),
          gap,
          KitText(
            l10n.sessionAddressConsentNote,
            role: KitTextRole.secondary,
            tone: KitTextTone.secondary,
          ),
          gap,
          KitButton.primary(
            key: const Key('session-address-check'),
            label: l10n.sessionAddressCheck,
            icon: AppIconography.networkCheck,
            onPressed: _c.approveContact,
          ),
        ],
        SessionAddressPhase.checkingServer => [
          KitProgressView(
            progress: KitProgress.waiting(
              caption: l10n.sessionAddressChecking(hostPort),
              key: const Key('session-address-checking'),
            ),
          ),
        ],
        SessionAddressPhase.addServer when saved.isEmpty => [
          _serverRow(hostPort, l10n.sessionAddressNotSaved),
          gap,
          KitText(l10n.sessionAddressAddBody),
          gap,
          KitButton.primary(
            key: const Key('session-address-add'),
            label: l10n.sessionAddressAddServer,
            icon: AppIconography.add,
            onPressed: () => _addServer(origin),
          ),
        ],
        SessionAddressPhase.addServer || SessionAddressPhase.chooseProfile => [
          KitText(l10n.sessionAddressChooseBody),
          gap,
          _chooser(saved, hostPort),
        ],
        SessionAddressPhase.bindingRequired => [
          _serverRow(hostPort, chosen?.name ?? ''),
          gap,
          KitText(l10n.sessionAddressVerifyBody(chosen?.name ?? hostPort)),
          gap,
          KitButton.primary(
            key: const Key('session-address-verify'),
            label: l10n.sessionAddressVerify,
            icon: AppIconography.shield,
            onPressed: _c.approveBinding,
          ),
        ],
        SessionAddressPhase.readyToOpen
            when chosen != null &&
                (chosen.requiresPasswordReentry ||
                    chosen.requiresCodexTokenReentry) =>
          [
            _serverRow(hostPort, chosen.name),
            gap,
            KitNotice(
              key: const Key('session-address-sign-in'),
              icon: AppIconography.login,
              message: l10n.sessionAddressSignInBody(chosen.name),
              actions: [
                KitAction(
                  key: const Key('session-address-sign-in-action'),
                  label: l10n.sessionAddressSignIn,
                  icon: AppIconography.login,
                  onPressed: () async {
                    await widget.onSignIn(chosen.id);
                    if (mounted) setState(() {});
                  },
                ),
              ],
            ),
          ],
        SessionAddressPhase.readyToOpen => [
          _serverRow(hostPort, chosen?.name ?? ''),
          gap,
          KitText(l10n.sessionAddressReadyBody(chosen?.name ?? hostPort)),
          gap,
          KitButton.primary(
            key: const Key('session-address-open'),
            label: l10n.sessionAddressOpen,
            icon: AppIconography.chat,
            onPressed: _c.open,
          ),
        ],
        SessionAddressPhase.openingSession || SessionAddressPhase.opened => [
          KitProgressView(
            progress: KitProgress.waiting(
              caption: l10n.sessionAddressOpening,
              key: const Key('session-address-opening'),
            ),
          ),
        ],
        SessionAddressPhase.failed => [
          SessionAddressFailureNotice(
            code: _c.failure ?? SessionAddressFailureCode.unavailable,
            actions: [
              if (_c.available && _retryable.contains(_c.failure))
                KitAction(
                  key: const Key('session-address-check-again'),
                  label: l10n.kitTryAgain,
                  icon: AppIconography.retry,
                  onPressed: _c.checkAgain,
                ),
              if (_c.failure == SessionAddressFailureCode.signInRequired &&
                  chosen != null)
                KitAction(
                  key: const Key('session-address-sign-in-action'),
                  label: l10n.sessionAddressSignIn,
                  icon: AppIconography.login,
                  onPressed: () => widget.onSignIn(chosen.id),
                ),
            ],
          ),
        ],
      };
    }
    return Column(
      key: const Key('session-address-body'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
