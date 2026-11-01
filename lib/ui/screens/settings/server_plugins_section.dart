import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/plugin_inventory.dart';
import '../../../domain/server_gateway.dart' show StreamStatus;
import '../../../l10n/app_localizations.dart';
import '../../../state/connection.dart';
import '../../app_theme.dart';
import '../../kit/kit.dart';

/// What the "On the server" section offers the Plugins page's top bar:
/// "Refresh plugins". The section fills it in; the page listens and builds
/// its top bar from it, so the section's action lives on the page it acts
/// on, not on a label.
class ServerPluginsActions extends ChangeNotifier {
  VoidCallback? _refresh;

  /// Reloads the server's plugins; null while it cannot run.
  VoidCallback? get refresh => _refresh;

  void _set(VoidCallback? refresh) {
    if ((refresh == null) == (_refresh == null)) {
      _refresh = refresh;
      return;
    }
    _refresh = refresh;
    notifyListeners();
  }
}

/// The "On the server" section of the one Plugins screen
/// (settings/plugins_screen.dart): the server's plugin inventory, carded in
/// one row group like "In this app". It is a section, not a page, so
/// Plugins has one home; the host only builds it when the server has a
/// plugin inventory. Its refresh goes to the page's top bar through
/// [actions].
///
/// The personal command links (map pages `plugins-mapping-dialog` and
/// `plugins-clear-mappings-sheet`) were removed by slice-P3.1: a plugin's
/// commands are run from the command sheet, which lists what the server
/// offers (target-ia §1.4).
class ServerPluginsSection extends StatefulWidget {
  const ServerPluginsSection({
    super.key,
    required this.controller,
    this.actions,
  });
  final ConnectionController controller;
  final ServerPluginsActions? actions;
  @override
  State<ServerPluginsSection> createState() => _ServerPluginsSectionState();
}

class _ServerPluginsSectionState extends State<ServerPluginsSection> {
  StreamSubscription<dynamic>? _events;
  Object? _source;
  List<PluginInfo>? _plugins;
  bool _loading = false;
  bool _failed = false;
  bool _reloadQueued = false;
  int _request = 0;

  ConnectionController get _controller => widget.controller;
  bool get _connected =>
      _controller.status == StreamStatus.connected &&
      _controller.isProfileReadable(_controller.profile?.id ?? '');
  bool get _supported =>
      _controller.capabilities.pluginInventory &&
      _controller.repository is PluginGateway;
  Object get _scope => (
    _controller.profile?.id,
    _controller.profile?.baseUrl,
    _controller.profile?.username,
    _controller.directory,
    _controller.workspace,
    _controller.locationRevision,
    _controller.connectionRevision,
    _controller.repository,
    _connected,
    _supported,
  );

  @override
  void initState() {
    super.initState();
    _attach();
    unawaited(_load());
  }

  void _attach() {
    _source = _scope;
    _controller.addListener(_changed);
    _controller.profileDataChanges.addListener(_changed);
    _events = _controller.events.listen((event) {
      if (event.type == 'plugin.added' || event.type == 'plugin.updated') {
        unawaited(_load());
      }
    });
  }

  void _detach(ConnectionController controller) {
    controller.removeListener(_changed);
    controller.profileDataChanges.removeListener(_changed);
    unawaited(_events?.cancel());
  }

  @override
  void didUpdateWidget(covariant ServerPluginsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _detach(oldWidget.controller);
      _request++;
      _plugins = null;
      _loading = false;
      _failed = false;
      _reloadQueued = false;
      _attach();
      unawaited(_load());
    }
  }

  void _changed() {
    if (!mounted || _source == _scope) return;
    setState(() {
      _source = _scope;
      _request++;
      _plugins = null;
      _loading = false;
      _failed = false;
      _reloadQueued = false;
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    if (!mounted || !_connected || !_supported) return;
    if (_loading) {
      _reloadQueued = true;
      return;
    }
    final scope = _scope;
    final request = ++_request;
    final gateway = _controller.repository as PluginGateway;
    setState(() {
      _loading = true;
      _failed = false;
    });
    bool current() => mounted && request == _request && scope == _scope;
    try {
      final result = await gateway.listPlugins();
      if (current()) setState(() => _plugins = result);
    } catch (_) {
      if (current()) setState(() => _failed = true);
    } finally {
      if (current()) {
        setState(() => _loading = false);
        if (_reloadQueued) {
          _reloadQueued = false;
          unawaited(_load());
        }
      }
    }
  }

  @override
  void dispose() {
    _request++;
    _detach(_controller);
    // The page may be going too: drop the callback without notifying.
    widget.actions?._refresh = null;
    super.dispose();
  }

  /// Publishes what the top bar can offer after this frame (never during a
  /// build).
  void _publishActions() {
    final actions = widget.actions;
    if (actions == null) return;
    final refresh = _connected && _supported && !_loading
        ? () {
            if (mounted) unawaited(_load());
          }
        : null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) actions._set(refresh);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final plugins = _plugins ?? const <PluginInfo>[];
    final builtIn = [
      for (final plugin in plugins)
        if (plugin.source == PluginSourceKind.builtin) plugin,
    ];
    final added = [
      for (final plugin in plugins)
        if (plugin.source != PluginSourceKind.builtin) plugin,
    ];
    final builtInActive = builtIn
        .where((plugin) => plugin.status == PluginStatus.active)
        .length;
    final builtInFailed = builtIn
        .where((plugin) => plugin.status == PluginStatus.failed)
        .length;
    _publishActions();
    final tokens = KitTokens.of(context);
    Widget group(List<Widget> children) => KitRowGroup(
      key: const ValueKey('plugins-section-server-group'),
      label: l10n.pluginsSectionOnServer,
      children: children,
    );
    return Column(
      key: const ValueKey('plugins-section-server'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        KitLoadingBar(
          loading: _connected && _supported && _loading,
          label: l10n.pluginsLoading,
        ),
        if (!_supported)
          group([_message(l10n.pluginsUnsupported)])
        else if (!_connected)
          group([_message(l10n.pluginsDisconnected)])
        else ...[
          if (_failed)
            Padding(
              padding: EdgeInsetsDirectional.only(
                start: tokens.gutter,
                end: tokens.gutter,
                bottom: tokens.space3,
              ),
              child: KitNotice(
                tone: AppStatusTone.failure,
                message: l10n.pluginsLoadFailed,
                actions: [
                  KitAction(
                    label: l10n.pluginsRetry,
                    onPressed: _loading ? null : _load,
                  ),
                ],
              ),
            ),
          if (_plugins == null && _loading && !_failed)
            const KitSkeletonRows(count: 3)
          else if (_plugins?.isEmpty == true && !_loading && !_failed)
            group([_message(l10n.pluginsEmpty)])
          else if (plugins.isNotEmpty)
            // What the person added is listed openly; the server's own
            // plugins fold into one row, open when one of them failed.
            group([
              for (final plugin in added) _row(plugin, l10n),
              if (builtIn.isNotEmpty)
                KitExpandRow(
                  key: ValueKey('plugins-builtin-${builtInFailed > 0}'),
                  headerKey: const ValueKey('plugins-builtin-group'),
                  initiallyExpanded: builtInFailed > 0,
                  leading: KitRow.icon(context, AppIconography.extensions),
                  title: l10n.pluginsBuiltinGroup,
                  supporting: TextSpan(
                    children: [
                      TextSpan(text: l10n.pluginsBuiltinActive(builtInActive)),
                      if (builtInFailed > 0)
                        TextSpan(
                          text:
                              ' · ${l10n.pluginsBuiltinFailed(builtInFailed)}',
                          style: KitText.styleOf(
                            context,
                            KitTextRole.secondary,
                            tone: KitTextTone.primary,
                          ),
                        ),
                    ],
                  ),
                  children: [for (final plugin in builtIn) _row(plugin, l10n)],
                ),
            ]),
        ],
      ],
    );
  }

  /// A state of the section as its one row: unsupported, disconnected or
  /// empty, in words.
  Widget _message(String text) => KitRow(
    key: const ValueKey('plugins-section-message'),
    title: text,
    titleMaxLines: 3,
  );

  /// One plugin as a kit row (§6): its state as the leading mark, a plain
  /// name, and one line that says where it stands. Tapping the row opens
  /// its details, where the raw id is.
  Widget _row(PluginInfo plugin, AppLocalizations l10n) {
    final id = plugin.id;
    final failed = plugin.status == PluginStatus.failed;
    return KitRow(
      key: ValueKey('plugin-row-${id ?? plugins.indexOf(plugin)}'),
      leading: KitStatusMark(
        state: switch (plugin.status) {
          PluginStatus.active => KitMarkState.done,
          PluginStatus.failed => KitMarkState.failed,
          PluginStatus.unknown => KitMarkState.waiting,
        },
      ),
      title: pluginDisplayName(plugin, l10n),
      titleKey: ValueKey('plugin-title-${id ?? ''}'),
      supporting: TextSpan(
        text: _statusWord(plugin, l10n),
        style: failed
            ? KitText.styleOf(
                context,
                KitTextRole.secondary,
                tone: KitTextTone.primary,
              )
            : null,
      ),
      trailing: const KitChevron(),
      onTap: () => unawaited(_details(plugin)),
    );
  }

  List<PluginInfo> get plugins => _plugins ?? const [];

  String _statusWord(PluginInfo plugin, AppLocalizations l10n) =>
      switch (plugin.status) {
        PluginStatus.active => l10n.pluginsStatusActive,
        PluginStatus.failed => l10n.pluginsStatusFailedToLoad,
        PluginStatus.unknown => l10n.pluginsStatusUnknown,
      };

  /// What a person may want to know about one plugin and rarely does:
  /// where it comes from, and the id the server knows it by, in mono.
  Future<void> _details(PluginInfo plugin) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final source = switch (plugin.source) {
      PluginSourceKind.builtin => l10n.pluginsSourceBuiltin,
      PluginSourceKind.package => l10n.pluginsSourcePackage,
      PluginSourceKind.local => l10n.pluginsSourceLocal,
      PluginSourceKind.sdk => l10n.pluginsSourceSdk,
      PluginSourceKind.unknown => l10n.pluginsSourceUnknown,
    };
    final failed = plugin.status == PluginStatus.failed;
    return showKitSheet<void>(
      context,
      title: pluginDisplayName(plugin, l10n),
      sheetKey: const ValueKey('plugin-details-sheet'),
      body: (sheetContext) {
        final tokens = KitTokens.of(sheetContext);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KitText(
              _statusWord(plugin, l10n),
              role: KitTextRole.secondary,
              tone: failed ? KitTextTone.primary : KitTextTone.secondary,
            ),
            if (failed) ...[
              SizedBox(height: tokens.space1),
              KitText(l10n.pluginsFailureDetail, role: KitTextRole.secondary),
            ],
            SizedBox(height: tokens.space3),
            // The package name only when it says more than the id below.
            KitText(
              plugin.packageName == null || plugin.packageName == plugin.id
                  ? source
                  : '$source · ${plugin.packageName}',
              role: KitTextRole.body,
            ),
            if (plugin.terminalUi)
              KitText(l10n.pluginsTerminalUi, role: KitTextRole.body),
            SizedBox(height: tokens.space3),
            KitDetailsFold(
              initiallyExpanded: true,
              values: [
                KitTechnicalValue(
                  l10n.pluginsDetailsId,
                  plugin.id ?? l10n.pluginsUnnamed,
                  key: const ValueKey('plugin-details-id'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// A plugin's name for people (docs/design/phone-server-screens-cleanup-
/// 2026-09-24.md §3). The server reports only an id, so the name is a
/// readable form of the id's last part: the namespace (`opencode.`) and
/// category words (`tool`, `config`) go, the rest is in sentence case with
/// the known acronyms in capitals. `opencode.tool.input.repair` is "Input
/// repair", `opencode.config.mcp` is "MCP", `@example/opencode-wakatime` is
/// "Wakatime". The raw id stays under the plugin's Details.
String pluginDisplayName(PluginInfo plugin, AppLocalizations l10n) {
  final id = plugin.id;
  if (id == null) return l10n.pluginsUnnamed;
  return readablePluginName(id);
}

/// [pluginDisplayName] for a known id.
String readablePluginName(String id) {
  var name = id.trim();
  if (name.startsWith('@')) {
    final slash = name.indexOf('/');
    if (slash > 0) name = name.substring(slash + 1);
  }
  final version = name.indexOf('@');
  if (version > 0) name = name.substring(0, version);
  if (name.contains('/')) name = name.split('/').last;
  var parts = name.split('.').where((part) => part.isNotEmpty).toList();
  if (parts.length > 1) parts = parts.sublist(1);
  const categories = {
    'tool',
    'tools',
    'config',
    'plugin',
    'plugins',
    'provider',
    'providers',
    'builtin',
    'core',
  };
  while (parts.length > 1 && categories.contains(parts.first.toLowerCase())) {
    parts.removeAt(0);
  }
  final words = [
    for (final part in parts)
      ...part
          .replaceAllMapped(
            RegExp(r'([a-z0-9])([A-Z])'),
            (match) => '${match[1]} ${match[2]}',
          )
          .split(RegExp(r'[-_\s]+'))
          .where((word) => word.isNotEmpty),
  ];
  while (words.length > 1 &&
      const {'opencode', 'plugin'}.contains(words.first.toLowerCase())) {
    words.removeAt(0);
  }
  if (words.isEmpty) return id;
  const acronyms = {
    'ai': 'AI',
    'api': 'API',
    'cli': 'CLI',
    'git': 'GIT',
    'http': 'HTTP',
    'https': 'HTTPS',
    'id': 'ID',
    'json': 'JSON',
    'llm': 'LLM',
    'lsp': 'LSP',
    'mcp': 'MCP',
    'pr': 'PR',
    'sdk': 'SDK',
    'ssh': 'SSH',
    'tui': 'TUI',
    'ui': 'UI',
    'url': 'URL',
  };
  final shown = <String>[];
  for (var i = 0; i < words.length; i++) {
    final word = words[i].toLowerCase();
    if (acronyms[word] case final acronym?) {
      shown.add(acronym);
    } else if (i == 0) {
      shown.add(KitText.sentenceCase(word));
    } else {
      shown.add(word);
    }
  }
  return shown.join(' ');
}
