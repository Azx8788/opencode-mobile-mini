import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../domain/agent_account.dart';
import '../../l10n/app_localizations.dart';
import '../../state/agent_account.dart';
import '../../state/connection.dart';
import '../app_theme.dart';
import '../kit/kit_bidi.dart';
import '../kit/kit_buttons.dart';
import '../kit/kit_capability_explainer.dart';
import '../kit/kit_details_fold.dart';
import '../kit/kit_icon_button.dart';
import '../kit/kit_notice.dart';
import '../kit/kit_progress.dart';
import '../kit/kit_progress_row.dart';
import '../kit/kit_row.dart';
import '../kit/kit_screen.dart';
import '../kit/kit_state_view.dart';
import '../kit/kit_surface.dart';
import '../kit/kit_text.dart';
import '../kit/kit_tokens.dart';
import '../kit/kit_top_bar.dart';
import '../widgets/external_link.dart';

AppLocalizations _strings(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

/// Pins the route to the profile/location the user opened. A reconnect may
/// refresh that account, but never recreates a pending login.
///
/// Before an account session exists the page says why instead of showing a
/// blank or misleading line: the server changed (scope lost, with the way
/// back), it is not connected, or it cannot host a Codex account at all
/// (KitCapabilityExplainer `server.codex`, which offers to connect one once
/// the app registers that flow).
class AgentAccountScreen extends StatefulWidget {
  final ConnectionController connection;
  const AgentAccountScreen({super.key, required this.connection});
  @override
  State<AgentAccountScreen> createState() => _AgentAccountScreenState();
}

class _AgentAccountScreenState extends State<AgentAccountScreen>
    with WidgetsBindingObserver {
  late final String? _profileId;
  late final int _location;
  late final Object? _gateway;
  late final String _name;
  AgentAccountController? _controller;
  bool _scopeLost = false;

  @override
  void initState() {
    super.initState();
    final connection = widget.connection;
    _profileId = connection.profile?.id;
    _location = connection.locationRevision;
    _gateway = connection.api;
    _name = connection.profile?.name ?? '';
    connection.addListener(_sync);
    WidgetsBinding.instance.addObserver(this);
    _bind();
  }

  bool get _supported =>
      widget.connection.capabilities.agentAccount &&
      widget.connection.api is AgentAccountGateway;

  void _bind() {
    final gateway = widget.connection.api;
    if (!widget.connection.isConnected ||
        !widget.connection.capabilities.agentAccount ||
        gateway is! AgentAccountGateway) {
      return;
    }
    _controller?.dispose();
    _controller = AgentAccountController(
      (gateway as AgentAccountGateway).openAccountSession(),
    );
    unawaited(_controller!.refresh());
  }

  void _sync() {
    if (!mounted || _scopeLost) return;
    final connection = widget.connection;
    if (connection.profile?.id != _profileId ||
        connection.locationRevision != _location ||
        !identical(connection.api, _gateway)) {
      _scopeLost = true;
      _controller?.dispose();
      _controller = null;
      setState(() {});
      return;
    }
    if (!connection.isConnected) {
      _controller?.invalidate();
    } else if (_controller == null || !_controller!.session.active) {
      _bind();
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_scopeLost) {
      _sync();
      final controller = _controller;
      if (controller != null && controller.session.active) {
        unawaited(controller.refresh());
      }
    }
  }

  @override
  void dispose() {
    widget.connection.removeListener(_sync);
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller != null) {
      return AgentAccountPanel(controller: controller, profileName: _name);
    }
    final l10n = _strings(context);
    final Widget state;
    if (_scopeLost) {
      state = KitStateView(
        key: const ValueKey('agent-account-scope-lost'),
        icon: AppIconography.swap,
        title: l10n.agentAccountScopeLostTitle,
        body: l10n.agentAccountScopeLost,
        primary: KitAction(
          label: l10n.agentAccountBackToServers,
          icon: AppIconography.back,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      );
    } else if (!_supported) {
      state = KitCapabilityExplainer.state(
        key: const ValueKey('agent-account-unsupported'),
        capability: 'server.codex',
        serverName: _name.isEmpty ? null : _name,
        size: KitStateSize.page,
        source: 'agent-account',
      );
    } else {
      state = KitStateView(
        key: const ValueKey('agent-account-not-connected'),
        icon: AppIconography.cloudOff,
        title: l10n.agentAccountDisconnected,
        body: l10n.agentAccountNotConnected,
      );
    }
    return KitScreen(
      topBar: KitTopBar(
        title: l10n.agentAccountTitle,
        subtitle: _name.isEmpty ? null : _name,
      ),
      width: KitScreenWidth.reading,
      body: state,
    );
  }
}

/// Rendered product surface, also used by synthetic widget capture fixtures.
///
/// One page per account state: the state in words first (who is signed in,
/// or why not), the sign-in steps while a device-code sign-in runs, then
/// the limits and token usage the host reports. Sign in is the one pinned
/// primary. The host notes fold under Details at the end.
class AgentAccountPanel extends StatelessWidget {
  final AgentAccountController controller;
  final String profileName;
  const AgentAccountPanel({
    super.key,
    required this.controller,
    required this.profileName,
  });

  String _headline(AppLocalizations l) {
    final account = controller.account;
    return switch (controller.status) {
      AccountPanelStatus.loading => l.agentAccountLoading,
      AccountPanelStatus.unavailable => l.agentAccountUnavailable,
      AccountPanelStatus.error => l.agentAccountReadFailed,
      AccountPanelStatus.disconnected => l.agentAccountDisconnected,
      AccountPanelStatus.ready =>
        account!.signedIn
            ? l.agentAccountConnected
            : account.requiresSignIn
            ? controller.loginPending
                  ? l.agentAccountInProgress
                  : controller.loginStatus == AccountLoginStatus.uncertain
                  ? l.agentAccountNeedsAttention
                  : l.agentAccountSignedOut
            : l.agentAccountNoAuth,
    };
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final l = _strings(context);
      final tokens = KitTokens.of(context);
      final account = controller.account;
      final status = controller.status;
      final ready = status == AccountPanelStatus.ready;
      final signedIn = ready && account!.signedIn;
      final canRefresh =
          status != AccountPanelStatus.loading && controller.session.active;
      final working =
          status == AccountPanelStatus.loading ||
          controller.loginStatus == AccountLoginStatus.starting ||
          controller.loginStatus == AccountLoginStatus.cancelling;
      final section = SizedBox(height: tokens.sectionGap);
      return KitScreen(
        topBar: KitTopBar(
          title: l.agentAccountTitle,
          subtitle: profileName.isEmpty ? null : profileName,
          actions: [
            KitAction(
              label: l.agentAccountRefresh,
              icon: AppIconography.retry,
              onPressed: canRefresh ? controller.refresh : null,
              disabledReason: canRefresh ? null : l.agentAccountLoading,
            ),
          ],
        ),
        width: KitScreenWidth.reading,
        loading: working,
        loadingLabel: l.agentAccountLoading,
        bottom: controller.canSignIn
            ? KitActionBlock(
                primary: KitAction(
                  key: const ValueKey('agent-account-sign-in'),
                  label: l.agentAccountSignIn,
                  icon: AppIconography.login,
                  onPressed: controller.signIn,
                ),
              )
            : null,
        body: ListView(
          padding: KitScreen.padding(context),
          children: [
            SizedBox(height: tokens.space3),
            _state(context, l),
            if (controller.loginStatus != AccountLoginStatus.idle) ...[
              section,
              _login(context, l),
            ],
            if (signedIn) ...[
              section,
              ..._limits(context, l),
              section,
              ..._usage(context, l),
            ],
            if (controller.updatedAt case final at?) ...[
              section,
              KitText(
                l.agentAccountUpdated(_time(context, at)),
                role: KitTextRole.caption,
              ),
            ],
            SizedBox(height: tokens.space4),
            // Each note once: the sign-in note is already the signed-out
            // body and the unsupported detail the unavailable body, so
            // neither repeats here.
            KitDetailsFold(
              notes: [
                l.agentAccountHostNote,
                if (signedIn) l.agentAccountUsageNote,
              ],
            ),
          ],
        ),
      );
    },
  );

  /// Who is signed in, or why the account cannot be read.
  Widget _state(BuildContext context, AppLocalizations l) {
    final account = controller.account;
    final headline = _headline(l);
    switch (controller.status) {
      case AccountPanelStatus.error:
        return KitNotice.error(
          key: const ValueKey('agent-account-read-failed'),
          message: headline,
          reportSource: 'agent-account',
          retry: controller.session.active
              ? KitAction(label: l.commonRetry, onPressed: controller.refresh)
              : null,
        );
      case AccountPanelStatus.unavailable:
        return KitStateView(
          icon: AppIconography.blocked,
          title: headline,
          body: l.agentAccountUnsupportedDetail,
          size: KitStateSize.inline,
          padding: EdgeInsetsDirectional.zero,
        );
      case AccountPanelStatus.disconnected:
        return KitStateView(
          icon: AppIconography.cloudOff,
          title: headline,
          body: l.agentAccountReconnectDetail,
          size: KitStateSize.inline,
          padding: EdgeInsetsDirectional.zero,
        );
      case AccountPanelStatus.loading:
        return KitStateView(
          icon: AppIconography.account,
          title: headline,
          progress: const KitProgress.waiting(),
          size: KitStateSize.inline,
          padding: EdgeInsetsDirectional.zero,
        );
      case AccountPanelStatus.ready:
        break;
    }
    if (!account!.signedIn) {
      return KitStateView(
        icon: AppIconography.account,
        title: headline,
        body: controller.canSignIn ? l.agentAccountSignInNote : null,
        size: KitStateSize.inline,
        padding: EdgeInsetsDirectional.zero,
      );
    }
    final method = switch (account.type) {
      'chatgpt' => 'ChatGPT',
      'apiKey' => l.agentAccountApiKey,
      'amazonBedrock' => 'Amazon Bedrock',
      _ => l.agentAccountHostAuth,
    };
    return KitRowGroup(
      margin: EdgeInsetsDirectional.zero,
      children: [
        KitRow(
          key: const ValueKey('agent-account-state'),
          leading: KitRow.icon(context, AppIconography.privacy),
          title: headline,
          supporting: account.email == null
              ? null
              : TextSpan(text: KitBidi.auto(account.email!)),
        ),
        KitRow(
          leading: KitRow.icon(context, AppIconography.login),
          title: l.agentAccountSignInMethod,
          trailing: KitRowValue(method, chevron: false),
        ),
        if (account.plan case final plan?)
          KitRow(
            leading: KitRow.icon(context, AppIconography.star),
            title: l.agentAccountPlanTitle,
            trailing: KitRowValue(KitBidi.auto(plan), chevron: false),
          ),
      ],
    );
  }

  /// The device-code sign-in, step by step: the code (copyable), the
  /// official page, and Cancel while it runs; what happened once it ends.
  Widget _login(BuildContext context, AppLocalizations l) {
    final tokens = KitTokens.of(context);
    final status = controller.loginStatus;
    final code = controller.deviceCode;
    final text = switch (status) {
      AccountLoginStatus.starting => l.agentAccountStarting,
      AccountLoginStatus.waiting => l.agentAccountWaiting,
      AccountLoginStatus.cancelling => l.agentAccountCancelling,
      AccountLoginStatus.cancelled => l.agentAccountCancelled,
      AccountLoginStatus.failed => l.agentAccountLoginFailed,
      AccountLoginStatus.uncertain => l.agentAccountLoginUncertain,
      AccountLoginStatus.completed => l.agentAccountLoginCompleted,
      AccountLoginStatus.idle => '',
    };
    final cancel = controller.loginPending || controller.canCancel
        ? KitButton.tertiary(
            key: const ValueKey('agent-account-cancel'),
            label: l.agentAccountCancel,
            icon: AppIconography.close,
            onPressed: status == AccountLoginStatus.cancelling
                ? null
                : controller.cancel,
          )
        : null;
    if (status == AccountLoginStatus.failed) {
      // The code expired or the host refused it: say so, and Sign in (the
      // pinned primary) starts a fresh code.
      return KitNotice.error(
        key: const ValueKey('agent-account-login-failed'),
        message: text,
        reportSource: 'agent-account',
      );
    }
    if (code == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          KitNotice(
            key: const ValueKey('agent-account-login-status'),
            icon: switch (status) {
              AccountLoginStatus.completed => AppIconography.checkCircle,
              AccountLoginStatus.uncertain => AppIconography.warning,
              _ => AppIconography.login,
            },
            tone: status == AccountLoginStatus.completed
                ? AppStatusTone.ok
                : AppStatusTone.neutral,
            message: text,
          ),
          if (cancel != null) ...[
            SizedBox(height: tokens.space2),
            Align(alignment: AlignmentDirectional.centerStart, child: cancel),
          ],
        ],
      );
    }
    final host = Uri.tryParse(code.verificationUrl)?.host ?? '';
    return KitSurface.panel(
      key: const ValueKey('agent-account-code'),
      title: text,
      icon: AppIconography.login,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          KitText(l.agentAccountCodeHint, role: KitTextRole.secondary),
          SizedBox(height: tokens.space3),
          Row(
            children: [
              Expanded(
                child: KitText.selectable(
                  code.userCode,
                  role: KitTextRole.title,
                  tabular: true,
                  semanticsLabel: code.userCode.split('').join(' '),
                ),
              ),
              KitIconButton.copy(
                key: const ValueKey('agent-account-copy-code'),
                text: () => code.userCode,
                tooltip: l.agentAccountCopyCode,
              ),
            ],
          ),
          SizedBox(height: tokens.space3),
          KitButton.secondary(
            key: const ValueKey('agent-account-open-sign-in'),
            label: l.agentAccountOpenSignIn,
            icon: AppIconography.externalLink,
            onPressed: () => openExternalLink(context, code.verificationUrl),
          ),
          if (host.isNotEmpty) ...[
            SizedBox(height: tokens.space1),
            KitText(KitBidi.ltr(host), role: KitTextRole.caption),
          ],
          if (cancel != null) ...[
            SizedBox(height: tokens.space2),
            Align(alignment: AlignmentDirectional.centerStart, child: cancel),
          ],
        ],
      ),
    );
  }

  /// One measured row per rate window; a window at its limit says when it
  /// resets.
  List<Widget> _limits(BuildContext context, AppLocalizations l) {
    final tokens = KitTokens.of(context);
    final limits = controller.limits;
    final known =
        limits?.where((b) => b.primary != null || b.secondary != null) ??
        const <AccountRateBucket>[];
    final windows = [
      for (final bucket in known)
        for (final window in [bucket.primary, bucket.secondary])
          if (window != null) (bucket, window),
    ];
    final reached = [
      for (final (_, window) in windows)
        if (window.usedPercent >= 100) window,
    ];
    return [
      KitRowGroup(
        margin: EdgeInsetsDirectional.zero,
        label: l.agentAccountLimits,
        leadingIcons: false,
        children: [
          if (controller.metricsLoading && limits == null)
            KitProgressRow(title: l.agentAccountAllowance, value: null)
          else if (windows.isEmpty)
            KitRow(
              title: l.agentAccountLimitsUnavailable,
              titleMaxLines: 3,
              enabled: false,
              disabledReason: l.agentAccountUsageNote,
            )
          else
            for (final (bucket, window) in windows)
              KitProgressRow(
                title: [
                  bucket.name ?? l.agentAccountAllowance,
                  window.durationMinutes == null
                      ? l.agentAccountWindowUnknown
                      : _duration(l, window.durationMinutes!),
                ].join(' · '),
                value: (window.usedPercent / 100).clamp(0, 1).toDouble(),
                valueLabel: [
                  l.agentAccountPercentUsed(window.usedPercent),
                  _reset(context, l, window.resetsAt, withDate: false),
                ].join(' · '),
              ),
        ],
      ),
      if (reached.isNotEmpty) ...[
        SizedBox(height: tokens.space3),
        KitNotice(
          key: const ValueKey('agent-account-limit-reached'),
          icon: AppIconography.blocked,
          message: l.agentAccountLimitReached(
            _reset(context, l, reached.first.resetsAt),
          ),
        ),
      ],
    ];
  }

  List<Widget> _usage(BuildContext context, AppLocalizations l) {
    final usage = controller.usage;
    final number = NumberFormat.decimalPattern(
      Localizations.localeOf(context).toLanguageTag(),
    );
    final rows = [
      if (usage?.lifetimeTokens case final value?)
        KitRow(
          title: l.agentAccountLifetimeTokens,
          trailing: KitRowValue(number.format(value), chevron: false),
        ),
      if (usage?.peakDailyTokens case final value?)
        KitRow(
          title: l.agentAccountPeakTokens,
          trailing: KitRowValue(number.format(value), chevron: false),
        ),
    ];
    return [
      KitRowGroup(
        margin: EdgeInsetsDirectional.zero,
        label: l.agentAccountUsage,
        leadingIcons: false,
        children: [
          if (controller.metricsLoading && rows.isEmpty)
            KitProgressRow(title: l.agentAccountUsage, value: null)
          else if (rows.isEmpty)
            KitRow(
              title: l.agentAccountUsageUnavailable,
              titleMaxLines: 3,
              enabled: false,
              disabledReason: l.agentAccountUsageNote,
            )
          else
            ...rows,
        ],
      ),
    ];
  }

  String _duration(AppLocalizations l, int minutes) =>
      minutes > 0 && minutes % 1440 == 0
      ? l.agentAccountWindowDays(minutes ~/ 1440)
      : minutes > 0 && minutes % 60 == 0
      ? l.agentAccountWindowHours(minutes ~/ 60)
      : l.agentAccountWindowMinutes(minutes);

  /// "Resets in 3 h (Sep 20, 6:00 PM)": the relative time first, the date
  /// for when the page is read later; a limit row shows the relative part
  /// only.
  String _reset(
    BuildContext context,
    AppLocalizations l,
    DateTime? at, {
    bool withDate = true,
  }) {
    if (at == null) return l.agentAccountResetUnknown;
    final left = at.difference(clock.now());
    final relative = left.isNegative
        ? l.agentAccountResetDue
        : left.inHours >= 48
        ? l.agentAccountResetInDays(left.inDays)
        : left.inMinutes >= 60
        ? l.agentAccountResetInHours(left.inHours)
        : l.agentAccountResetInMinutes(left.inMinutes < 1 ? 1 : left.inMinutes);
    return withDate
        ? l.agentAccountResetWhen(relative, _time(context, at))
        : relative;
  }

  String _time(BuildContext context, DateTime at) => DateFormat.yMMMd(
    Localizations.localeOf(context).toLanguageTag(),
  ).add_jm().format(at.toLocal());
}
