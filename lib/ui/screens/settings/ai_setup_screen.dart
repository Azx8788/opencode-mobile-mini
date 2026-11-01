import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../domain/setup_assistant.dart';
import '../../../domain/setup_suggestions.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/connection.dart';
import '../../../state/setup_session.dart';
import '../../app_theme.dart';
import '../../kit/kit.dart';

/// "AI setup" for one server, review only (owner decision 2026-09-28): the
/// settings that apply, the MCP tool servers and what state each is in, and
/// suggestions for what could change. Nothing on this page applies, proposes
/// to the server or undoes a change; the one line at the top says changes
/// are made on the server for now.
///
/// One list, most urgent first: suggestions (what needs the person), then
/// the tools ordered by urgency, then the configuration. OpenCode 1 servers
/// show their effective (merged) settings; OpenCode 2 servers show their
/// ordered sources as they are, never an invented merge. Every value comes
/// from the setup controller's redacted snapshot: provider credentials,
/// headers, environment values and URL sign-ins never render.
///
/// States: loading, ready, empty, offline (with and without the last read),
/// unsupported, needs sign-in, error.
class AiSetupScreen extends StatefulWidget {
  const AiSetupScreen({
    super.key,
    required this.controller,
    required this.serverName,
    this.session,
  });

  final ConnectionController controller;

  /// The server this page is about, as its settings page names it.
  final String serverName;

  /// Injected by tests; null builds the session for [controller].
  final SetupSession? session;

  @override
  State<AiSetupScreen> createState() => _AiSetupScreenState();
}

class _AiSetupScreenState extends State<AiSetupScreen> {
  late final SetupSession _session =
      widget.session ?? SetupSession(widget.controller);

  @override
  void initState() {
    super.initState();
    _session.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _session.removeListener(_changed);
    if (widget.session == null) _session.dispose();
    super.dispose();
  }

  bool get _loading => switch (_session.snapshot.phase) {
    SetupPhase.idle ||
    SetupPhase.loading ||
    SetupPhase.applying ||
    SetupPhase.verifying ||
    SetupPhase.undoing => true,
    _ => false,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final snapshot = _session.snapshot;
    // Reading again is offered only over a page that shows a read: a
    // failure's own Try again, the sign-in action and the offline line
    // cover the other states, so the action never appears twice.
    final canRefresh =
        _session.online &&
        (snapshot.phase == SetupPhase.ready ||
            snapshot.phase == SetupPhase.empty);
    return KitScreen(
      topBar: KitTopBar(
        title: l10n.aiSetupTitle,
        subtitle: widget.serverName,
        actions: [
          if (canRefresh)
            KitAction(
              key: const ValueKey('ai-setup-refresh'),
              icon: AppIconography.retry,
              label: l10n.aiSetupRefresh,
              onPressed: () => unawaited(_session.refresh()),
            ),
        ],
      ),
      width: KitScreenWidth.reading,
      loading: _loading,
      loadingLabel: l10n.aiSetupLoading,
      body: _body(context, l10n, snapshot),
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    SetupSnapshot snapshot,
  ) {
    final hasData = snapshot.config.isNotEmpty || snapshot.servers.isNotEmpty;
    switch (snapshot.phase) {
      case SetupPhase.idle ||
          SetupPhase.loading ||
          SetupPhase.applying ||
          SetupPhase.verifying ||
          SetupPhase.undoing:
        if (!hasData) {
          return KitStateView(
            key: const ValueKey('ai-setup-loading'),
            icon: AppIconography.waiting,
            tone: AppStatusTone.progress,
            title: l10n.aiSetupLoading,
          );
        }
      case SetupPhase.unsupported:
        return KitStateView(
          key: const ValueKey('ai-setup-unsupported'),
          icon: AppIconography.locked,
          title: l10n.aiSetupUnsupportedTitle,
          body: l10n.aiSetupUnsupportedBody,
        );
      case SetupPhase.needsSignIn:
        return KitStateView(
          key: const ValueKey('ai-setup-needs-sign-in'),
          icon: AppIconography.login,
          title: l10n.aiSetupSignInTitle,
          body: l10n.aiSetupSignInBody(widget.serverName),
          primary: KitAction(
            key: const ValueKey('ai-setup-change-sign-in'),
            label: l10n.serverSettingsChangeSignIn(widget.serverName),
            icon: AppIconography.person,
            onPressed: () => Navigator.of(
              context,
            ).pushNamed('/servers', arguments: 'edit-active'),
          ),
        );
      case SetupPhase.error || SetupPhase.uncertain:
        return KitStateView.error(
          key: const ValueKey('ai-setup-error'),
          title: l10n.aiSetupErrorTitle,
          body: l10n.aiSetupErrorBody,
          details: snapshot.reason,
          retry: _session.online
              ? KitAction(
                  key: const ValueKey('ai-setup-try-again'),
                  label: l10n.aiSetupTryAgain,
                  icon: AppIconography.retry,
                  onPressed: () => unawaited(_session.refresh()),
                )
              : null,
        );
      case SetupPhase.offline:
        if (!hasData) {
          return KitStateView(
            key: const ValueKey('ai-setup-offline'),
            icon: AppIconography.cloudOff,
            title: l10n.aiSetupOfflineTitle,
            body: l10n.aiSetupOfflineBody(widget.serverName),
          );
        }
      case SetupPhase.empty:
        return KitStateView(
          key: const ValueKey('ai-setup-empty'),
          icon: AppIconography.settings,
          title: l10n.aiSetupEmptyTitle,
          body: l10n.aiSetupEmptyBody,
        );
      case SetupPhase.ready:
        break;
    }
    return _list(context, l10n, snapshot);
  }

  Widget _list(
    BuildContext context,
    AppLocalizations l10n,
    SetupSnapshot snapshot,
  ) {
    final tokens = KitTokens.of(context);
    final suggestions = setupSuggestions(snapshot);
    final servers = [...snapshot.servers]
      ..sort(
        (a, b) =>
            setupToolUrgency(a.status).compareTo(setupToolUrgency(b.status)),
      );
    final config = snapshot.config;
    return ListView(
      key: const ValueKey('ai-setup-list'),
      padding: EdgeInsets.only(
        top: tokens.space3,
        bottom: KitScreen.endPadding(context),
      ),
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.gutter),
          child: snapshot.phase == SetupPhase.offline
              ? KitNotice(
                  key: const ValueKey('ai-setup-offline-notice'),
                  icon: AppIconography.cloudOff,
                  message: l10n.aiSetupOfflineStale(widget.serverName),
                )
              : KitNotice(
                  key: const ValueKey('ai-setup-review-only'),
                  icon: AppIconography.info,
                  message: l10n.aiSetupReviewOnly,
                  liveRegion: false,
                ),
        ),
        if (suggestions.isNotEmpty)
          KitRowGroup(
            key: const ValueKey('ai-setup-suggestions'),
            label: l10n.aiSetupSuggestionsLabel,
            children: [
              for (final suggestion in suggestions)
                _SuggestionRow(suggestion: suggestion),
            ],
          ),
        if (servers.isNotEmpty)
          KitRowGroup(
            key: const ValueKey('ai-setup-tools'),
            label: l10n.aiSetupToolsLabel,
            labelTerm: l10n.aiSetupToolsTerm,
            children: [for (final server in servers) _ToolRow(server: server)],
          ),
        if (setupConfigIsLayered(config))
          ..._sources(context, l10n, config['sources'])
        else if (config.isNotEmpty)
          ..._effective(context, l10n, config),
      ],
    );
  }

  /// OpenCode 1: the settings in effect, the few a person looks for first,
  /// then everything (redacted) under one fold.
  List<Widget> _effective(
    BuildContext context,
    AppLocalizations l10n,
    Map<String, Object?> config,
  ) {
    final tokens = KitTokens.of(context);
    String? text(Object? value) =>
        value is String && value.trim().isNotEmpty ? value : null;
    final model = text(config['model']);
    final smallModel = text(config['small_model']);
    final agent = text(config['default_agent']);
    final providers = config['provider'];
    final permission = config['permission'];
    return [
      KitRowGroup(
        key: const ValueKey('ai-setup-effective'),
        label: l10n.aiSetupEffectiveLabel,
        labelTerm: l10n.aiSetupEffectiveTerm,
        children: [
          _FactRow(
            icon: AppIconography.model,
            title: l10n.aiSetupModel,
            value: model ?? l10n.aiSetupServerDefault,
          ),
          if (smallModel != null)
            _FactRow(
              icon: AppIconography.speed,
              title: l10n.aiSetupSmallModel,
              value: smallModel,
            ),
          if (agent != null)
            _FactRow(
              icon: AppIconography.agent,
              title: l10n.aiSetupDefaultAgent,
              value: agent,
            ),
          if (providers is Map && providers.isNotEmpty)
            _FactRow(
              icon: AppIconography.cloud,
              title: l10n.aiSetupProviders,
              value: providers.keys.join(', '),
            ),
          if (permission is Map && permission.isNotEmpty)
            _FactRow(
              icon: AppIconography.permissions,
              title: l10n.aiSetupPermissions,
              value: l10n.aiSetupPermissionRules(permission.length),
            )
          else if (text(permission) != null)
            _FactRow(
              icon: AppIconography.permissions,
              title: l10n.aiSetupPermissions,
              value: permission! as String,
            ),
        ],
      ),
      Padding(
        padding: EdgeInsetsDirectional.only(
          start: tokens.gutter,
          top: tokens.space3,
          end: tokens.gutter,
        ),
        child: KitDetailsFold(
          key: const ValueKey('ai-setup-all-settings'),
          label: l10n.aiSetupAllSettings,
          text: _json(config),
        ),
      ),
    ];
  }

  /// OpenCode 2: the ordered sources exactly as the server reports them.
  List<Widget> _sources(
    BuildContext context,
    AppLocalizations l10n,
    Object? sources,
  ) {
    final tokens = KitTokens.of(context);
    final list = sources is List ? sources : const <Object?>[];
    return [
      KitRowGroup(
        key: const ValueKey('ai-setup-sources'),
        label: l10n.aiSetupSourcesLabel,
        labelTerm: l10n.aiSetupSourcesTerm,
        children: [
          if (list.isEmpty)
            KitRow(
              leading: KitRow.icon(context, AppIconography.fileText),
              title: l10n.aiSetupNoSources,
              supporting: TextSpan(text: l10n.aiSetupNoSourcesDetail),
              supportingMaxLines: 2,
            ),
          for (final (index, source) in list.indexed)
            _SourceRow(position: index + 1, source: source),
        ],
      ),
      if (list.isNotEmpty)
        Padding(
          padding: EdgeInsetsDirectional.only(
            start: tokens.gutter,
            top: tokens.space3,
            end: tokens.gutter,
          ),
          child: KitDetailsFold(
            key: const ValueKey('ai-setup-all-settings'),
            label: l10n.aiSetupAllSources,
            text: _json(list),
          ),
        ),
    ];
  }

  /// The already-redacted snapshot, indented. KitDetailsFold redacts again.
  static String _json(Object? value) =>
      const JsonEncoder.withIndent('  ').convert(value);
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({required this.suggestion});

  final SetupSuggestion suggestion;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final name = suggestion.subject ?? '';
    final (icon, tone, title, detail) = switch (suggestion.kind) {
      SetupSuggestionKind.signInTool => (
        AppIconography.login,
        AppStatusTone.neutral,
        l10n.aiSetupSuggestSignInTitle(name),
        l10n.aiSetupSuggestSignInDetail,
      ),
      SetupSuggestionKind.fixTool => (
        AppIconography.error,
        AppStatusTone.failure,
        l10n.aiSetupSuggestFixTitle(name),
        l10n.aiSetupSuggestFixDetail,
      ),
      SetupSuggestionKind.chooseModel => (
        AppIconography.model,
        AppStatusTone.neutral,
        l10n.aiSetupSuggestModelTitle,
        l10n.aiSetupSuggestModelDetail,
      ),
      SetupSuggestionKind.addTools => (
        AppIconography.extensions,
        AppStatusTone.neutral,
        l10n.aiSetupSuggestToolsTitle,
        l10n.aiSetupSuggestToolsDetail,
      ),
    };
    return KitRow(
      leading: KitRow.icon(
        context,
        icon,
        color: tone == AppStatusTone.neutral
            ? null
            : KitTokens.toneColor(tokens.roles, tone),
      ),
      title: title,
      titleMaxLines: 2,
      supporting: TextSpan(text: detail),
      supportingMaxLines: 3,
    );
  }
}

class _ToolRow extends StatelessWidget {
  const _ToolRow({required this.server});

  final SetupMcpStatus server;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final (icon, tone, word) = switch (server.status) {
      'connected' => (
        AppIconography.checkCircle,
        AppStatusTone.ok,
        l10n.aiSetupToolConnected,
      ),
      'pending' => (
        AppIconography.waiting,
        AppStatusTone.progress,
        l10n.aiSetupToolWaiting,
      ),
      'disabled' => (
        AppIconography.removeCircle,
        AppStatusTone.neutral,
        l10n.aiSetupToolOff,
      ),
      'failed' => (
        AppIconography.error,
        AppStatusTone.failure,
        l10n.aiSetupToolFailed,
      ),
      'needs_auth' || 'needs_client_registration' => (
        AppIconography.login,
        AppStatusTone.neutral,
        l10n.aiSetupToolNeedsSignIn,
      ),
      _ => (
        AppIconography.question,
        AppStatusTone.neutral,
        l10n.aiSetupToolUnknown,
      ),
    };
    return KitRow(
      leading: KitRow.icon(
        context,
        icon,
        color: tone == AppStatusTone.neutral
            ? null
            : KitTokens.toneColor(tokens.roles, tone),
      ),
      title: server.name,
      supporting: TextSpan(text: word),
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) => KitRow(
    leading: KitRow.icon(context, icon),
    title: title,
    supporting: TextSpan(text: value),
    supportingMaxLines: 2,
  );
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.position, required this.source});

  final int position;
  final Object? source;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final entry = source is Map ? source! as Map : const {};
    final path = entry['path'];
    final type = entry['type'];
    final info = entry['info'];
    final keys = info is Map ? info.keys.map((k) => '$k').toList() : const [];
    return KitRow(
      leading: KitRow.icon(context, AppIconography.fileText),
      title: path is String && path.isNotEmpty
          ? path
          : l10n.aiSetupSourceUnnamed(type is String ? type : ''),
      titleMaxLines: 2,
      supporting: TextSpan(
        text: keys.isEmpty
            ? l10n.aiSetupSourceEmpty(position)
            : l10n.aiSetupSourceSets(position, keys.join(', ')),
      ),
      supportingMaxLines: 2,
    );
  }
}
