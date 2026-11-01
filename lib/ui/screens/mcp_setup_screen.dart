import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/product_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import '../app_iconography.dart';
import '../app_theme.dart' show AppStatusTone;
import '../kit/kit.dart';
import '../widgets/product_states.dart' show productErrorText;

AppLocalizations _l10nOf(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

/// The technical way to add an MCP server (map `mcp-setup`, proposal fix):
/// where it goes, its name and address first, headers as a name plus an
/// obscured value, and the rarer settings under Advanced. Built from kit
/// parts only (screen-library-2).
///
/// States: form; saving; save failed (the reason on the status line, the
/// draft kept); saved but the app did not reconnect (Try reconnecting
/// again); location changed while open (the draft kept, saving stopped);
/// not available on this server (explained, P7.4); discard question when
/// leaving with unsaved input; filled in from the MCP catalogue (P2.5).
///
/// The MCP catalogue opens this same form with [prefill], so a catalogue
/// server is saved by the same checks and the same Save as one typed by
/// hand: the person sees the address or command before anything is
/// written. A prefill carries names only for headers and environment
/// variables; their values are always typed here, in secret fields.
class McpSetupScreen extends StatefulWidget {
  final ConnectionController controller;

  /// The catalogue listing's starting point: name, how it runs, address or
  /// command, and the header / variable names it needs. Any values in it
  /// are ignored.
  final McpServerDraft? prefill;

  /// The listing's title, for the line that says where the form's values
  /// came from; shown only with [prefill].
  final String? prefillSource;

  const McpSetupScreen({
    super.key,
    required this.controller,
    this.prefill,
    this.prefillSource,
  });

  @override
  State<McpSetupScreen> createState() => _McpSetupScreenState();
}

class _McpSetupScreenState extends State<McpSetupScreen> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _command = TextEditingController();
  final _cwd = TextEditingController();
  // P0.1: a header's value is a secret (Authorization: Bearer …). One row
  // per pair, each value a secret KitField. Environment variables follow
  // the same rule (an API key is one, P2.5).
  final List<_PairRow> _headerRows = [];
  final List<_PairRow> _envRows = [];
  final _timeout = TextEditingController();

  late McpConfigScope _scope;
  late final String? _profileId;
  late final int _location;
  late final String? _directory, _workspace;
  late final bool _runtime;

  /// The server can add an MCP server at all (config write or runtime add)
  /// when the page opened; otherwise the page explains why (P7.4).
  late final bool _supported;
  bool _detached = false;
  McpServerKind _kind = McpServerKind.remote;
  bool _detectOAuth = true;
  bool _saving = false;
  bool _configurationSaved = false;
  bool _submitted = false;
  bool _advancedOpen = false;
  bool _leaving = false;
  String? _saveError;

  bool get _hasProject => _directory?.trim().isNotEmpty == true;

  /// The form's fields stay editable while it is shown: a location change
  /// only stops Save (the status line says why), and a saved server
  /// replaces the form with its saved state.
  bool get _editable => !_configurationSaved;
  bool get _scopeMatches =>
      widget.controller.profile?.id == _profileId &&
      widget.controller.locationRevision == _location &&
      widget.controller.directory == _directory &&
      widget.controller.workspace == _workspace;
  bool get _locationMatches =>
      _scopeMatches &&
      (_runtime
          ? widget.controller.capabilities.mcpRuntimeAdds
          : widget.controller.capabilities.mcpConfigWrites);

  /// Something typed that leaving would lose: anything that differs from
  /// how the form opened (empty, or a catalogue listing's starting point).
  bool get _hasInput =>
      !_configurationSaved && _inputSignature() != _startSignature;

  String _startSignature = '';

  String _inputSignature() =>
      [
            _name.text,
            _url.text,
            _command.text,
            _cwd.text,
            _timeout.text,
            for (final row in [..._headerRows, ..._envRows])
              '${row.key.text.trim()}=${row.value.text.trim()}',
          ]
          .map((text) => text.trim())
          .where((text) => text.isNotEmpty && text != '=')
          .join('\u0000');

  @override
  void initState() {
    super.initState();
    final capabilities = widget.controller.capabilities;
    _profileId = widget.controller.profile?.id;
    _location = widget.controller.locationRevision;
    _directory = widget.controller.directory;
    _workspace = widget.controller.workspace;
    _supported = capabilities.mcpConfigWrites || capabilities.mcpRuntimeAdds;
    _runtime = !capabilities.mcpConfigWrites && capabilities.mcpRuntimeAdds;
    _scope = _runtime
        ? McpConfigScope.runtimeLocation
        : _hasProject
        ? McpConfigScope.project
        : McpConfigScope.global;
    _detached = _supported && !_locationMatches;
    _applyPrefill(widget.prefill);
    if (_headerRows.isEmpty) _headerRows.add(_PairRow());
    if (_envRows.isEmpty) _envRows.add(_PairRow());
    _startSignature = _inputSignature();
    widget.controller.addListener(_connectionChanged);
  }

  /// A catalogue listing's starting point (P2.5). Names only: a header or
  /// variable value is never prefilled, so a secret is only ever typed
  /// into its own secret field (P0.1, SEC-3).
  void _applyPrefill(McpServerDraft? draft) {
    if (draft == null) return;
    _name.text = draft.normalizedName;
    _kind = draft.kind;
    if (draft.kind == McpServerKind.remote) {
      _url.text = draft.url ?? '';
      for (final name in draft.headers.keys) {
        _headerRows.add(_PairRow(name: name));
      }
    } else {
      _command.text = draft.command.join('\n');
      for (final name in draft.environment.keys) {
        _envRows.add(_PairRow(name: name));
      }
    }
  }

  void _connectionChanged() {
    if (!_supported) return;
    final matches = _configurationSaved ? _scopeMatches : _locationMatches;
    if (!_detached && !matches && mounted) {
      setState(() => _detached = true);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_connectionChanged);
    _name.dispose();
    _url.dispose();
    _command.dispose();
    _cwd.dispose();
    for (final row in [..._headerRows, ..._envRows]) {
      row.dispose();
    }
    _timeout.dispose();
    super.dispose();
  }

  // --- validation -----------------------------------------------------------

  String? get _nameError => _name.text.trim().isEmpty
      ? _l10nOf(context).e7LibraryEnterAServerName
      : null;

  String? get _urlError {
    if (_kind != McpServerKind.remote) return null;
    final uri = Uri.tryParse(_url.text.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.userInfo.isNotEmpty) {
      return _l10nOf(context).e7LibraryEnterAValidHTTPOrHTTPSURL;
    }
    return null;
  }

  String? get _commandError =>
      _kind == McpServerKind.local && _lines(_command.text).isEmpty
      ? _l10nOf(context).e7LibraryEnterACommand
      : null;

  String? get _headersError => _kind == McpServerKind.remote
      ? _requiredError(_headerRows) ??
            _pairError(
              _draftText(_headerRows),
              _l10nOf(context).e7LibraryHTTPHeader,
            )
      : null;

  String? get _environmentError => _kind == McpServerKind.local
      ? _requiredError(_envRows) ??
            _pairError(
              _draftText(_envRows),
              _l10nOf(context).e7LibraryEnvironmentVariable,
            )
      : null;

  /// A header or variable the catalogue listing requires, left empty.
  String? _requiredError(List<_PairRow> rows) {
    for (final row in rows) {
      if (row.prefilled && row.value.text.trim().isEmpty) {
        return _l10nOf(context).mcpSetupValueRequired(row.key.text.trim());
      }
    }
    return null;
  }

  /// The time limit in seconds (the server takes milliseconds).
  String? get _timeoutError {
    final text = _timeout.text.trim();
    if (text.isEmpty) return null;
    final timeout = int.tryParse(text);
    return timeout == null || timeout <= 0
        ? _l10nOf(context).e7LibraryEnterAValueGreaterThanZero
        : null;
  }

  /// Errors under Advanced: it opens so the reason is never hidden.
  bool get _advancedHasError => _timeoutError != null;

  bool get _formValid =>
      _nameError == null &&
      _urlError == null &&
      _commandError == null &&
      _headersError == null &&
      _environmentError == null &&
      _timeoutError == null;

  /// Only after the first Save, so an untouched form is never red.
  String? _shown(String? error) => _submitted ? error : null;

  void _edited([String _ = '']) => setState(() {});

  // --- save -----------------------------------------------------------------

  Future<void> _save() async {
    if (!_editable || _saving || _detached) return;
    if (!_formValid) {
      setState(() {
        _submitted = true;
        if (_advancedHasError) _advancedOpen = true;
      });
      return;
    }
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    final l10n = _l10nOf(context);
    setState(() {
      _submitted = true;
      _saving = true;
      _saveError = null;
    });
    try {
      final timeoutText = _timeout.text.trim();
      final draft = McpServerDraft(
        name: _name.text,
        kind: _kind,
        url: _kind == McpServerKind.remote ? _url.text : null,
        command: _kind == McpServerKind.local
            ? _lines(_command.text)
            : const [],
        cwd: _kind == McpServerKind.local ? _cwd.text : null,
        headers: _kind == McpServerKind.remote
            ? _pairs(_draftText(_headerRows), l10n.e7LibraryHTTPHeader)
            : const {},
        environment: _kind == McpServerKind.local
            ? _pairs(_draftText(_envRows), l10n.e7LibraryEnvironmentVariable)
            : const {},
        detectOAuth: _detectOAuth,
        timeoutMs: timeoutText.isEmpty ? null : int.parse(timeoutText) * 1000,
      );
      // Keep repository validation authoritative even if a field check is
      // changed later.
      draft.toConfigJson();
      final repository = await widget.controller.prepareActionRepository();
      if (!mounted || !_routeIsCurrent(route)) return;
      if (_detached || !_locationMatches) {
        _detached = true;
        throw ProductException(l10n.mcpLocationChanged);
      }
      if (repository == null) {
        throw ProductException(
          l10n.e7LibraryOpenCodeIsReconnectingTryAgainShortly,
        );
      }
      await repository.addMcpServer(draft, scope: _scope);
      _configurationSaved = true;
      if (!_scopeMatches) {
        _detached = true;
        throw ProductException(l10n.mcpLocationChanged);
      }
      // Runtime adds are already applied. Reconnecting the app is only needed
      // after the persistent v1 configuration write, and only in its location.
      if (!_runtime && _routeIsCurrent(route) && _scopeMatches) {
        await widget.controller.reloadAfterConfigurationChange();
        if (!_scopeMatches) {
          _detached = true;
          throw ProductException(l10n.mcpLocationChanged);
        }
        _throwIfReconnectFailed(l10n);
      }
      if (_routeIsActive(route)) {
        if (route!.isCurrent) {
          navigator.pop(true);
        } else {
          navigator.removeRoute(route, true);
        }
      }
    } catch (error) {
      if (mounted && _routeIsCurrent(route)) {
        if (!(_configurationSaved ? _scopeMatches : _locationMatches)) {
          setState(() => _detached = true);
          return;
        }
        setState(() => _saveError = productErrorText(error));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _retryReconnect() async {
    if (!_configurationSaved || _saving || _detached) return;
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    final l10n = _l10nOf(context);
    if (!_routeIsCurrent(route) || !_scopeMatches) {
      if (mounted && !_scopeMatches) setState(() => _detached = true);
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await widget.controller.reloadAfterConfigurationChange();
      if (!mounted || !_routeIsActive(route)) return;
      if (!_scopeMatches) {
        if (route!.isCurrent) setState(() => _detached = true);
        return;
      }
      _throwIfReconnectFailed(l10n);
      if (route!.isCurrent) {
        navigator.pop(true);
      } else {
        navigator.removeRoute(route, true);
      }
    } catch (error) {
      if (mounted && _routeIsCurrent(route)) {
        if (!_scopeMatches) {
          setState(() => _detached = true);
          return;
        }
        setState(() => _saveError = productErrorText(error));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool _routeIsCurrent(ModalRoute<dynamic>? route) =>
      _routeIsActive(route) && route!.isCurrent;

  bool _routeIsActive(ModalRoute<dynamic>? route) =>
      mounted &&
      route != null &&
      identical(ModalRoute.of(context), route) &&
      route.isActive;

  void _throwIfReconnectFailed(AppLocalizations l10n) {
    if (widget.controller.connectionError != null) {
      throw ProductException(l10n.mcpStillDisconnected);
    }
  }

  /// Back with unsaved input asks first (map actionsMissing "discard
  /// guard"); "Keep editing" is the default.
  Future<void> _confirmLeave() async {
    if (_leaving) return;
    final l10n = _l10nOf(context);
    final navigator = Navigator.of(context);
    final discard = await showKitConfirm(
      context,
      kind: KitConfirmKind.discard,
      icon: AppIconography.delete,
      title: l10n.mcpSetupDiscardTitle,
      body: l10n.mcpSetupDiscardBody,
      confirmLabel: l10n.mcpSetupDiscardConfirm,
    );
    if (!discard || !mounted) return;
    setState(() => _leaving = true);
    navigator.pop();
  }

  // --- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = _l10nOf(context);
    final glossary = KitAction(
      key: const ValueKey('mcp-glossary'),
      icon: AppIconography.info,
      label: l10n.e7LibraryWhatIsMCP,
      onPressed: () => showKitTerm(
        context,
        term: l10n.libraryMcpTitle,
        explanation: l10n.e7GlossaryMcpExplanation,
      ),
    );
    if (!_supported) {
      return KitScreen(
        width: KitScreenWidth.list,
        topBar: KitTopBar(
          title: l10n.mcpAdd,
          subtitle: widget.controller.profile?.name,
          actions: [glossary],
        ),
        body: KitStateView.missing(
          key: const ValueKey('mcp-setup-unavailable'),
          capability: 'mcp.any',
          icon: AppIconography.extensions,
          title: l10n.mcpSetupUnavailableTitle,
          why: l10n.mcpSetupUnavailableBody,
          size: KitStateSize.page,
        ),
      );
    }
    if (_configurationSaved) return _savedScreen(context, l10n);
    return PopScope<Object?>(
      canPop: _leaving || !_hasInput,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: KitScreen(
        width: KitScreenWidth.list,
        topBar: KitTopBar(
          title: l10n.mcpAdd,
          subtitle: widget.controller.profile?.name,
          actions: [glossary],
        ),
        status: _status(l10n),
        bottom: KitActionBlock(primary: _primary(l10n)),
        body: ListView(
          key: const ValueKey('mcp-setup-form'),
          padding: KitScreen.padding(context),
          children: [
            if (widget.prefill != null) ...[
              KitNotice(
                key: const ValueKey('mcp-setup-from-catalog'),
                icon: AppIconography.info,
                message: l10n.mcpSetupFromCatalog(
                  widget.prefillSource ?? widget.prefill!.normalizedName,
                  widget.controller.profile?.name ?? l10n.mcpSetupThisServer,
                ),
              ),
              _gap(context),
            ],
            ..._whereSection(context, l10n),
            _gap(context),
            KitField(
              label: l10n.e7LibraryServerName,
              controller: _name,
              kind: KitFieldKind.mono,
              hint: l10n.e7LibraryDocsOrBrowserTools,
              helper: l10n.e7LibraryUniqueWithinTheSelectedConfiguration,
              error: _shown(_nameError),
              enabled: _editable,
              disabledReason: _disabledReason(l10n),
              textInputAction: TextInputAction.next,
              onChanged: _edited,
              fieldKey: const ValueKey('mcp-name'),
            ),
            _gap(context),
            _label(context, l10n.mcpSetupHowItRuns),
            KitSegmented<McpServerKind>(
              key: const ValueKey('mcp-kind'),
              semanticsLabel: l10n.mcpSetupHowItRuns,
              selected: _kind,
              disabledReason: _disabledReason(l10n),
              onChanged: !_editable
                  ? null
                  : (value) => setState(() {
                      _kind = value;
                      _saveError = null;
                    }),
              segments: [
                KitSegment(
                  value: McpServerKind.remote,
                  icon: AppIconography.cloud,
                  label: l10n.e7LibraryRemoteURL,
                ),
                KitSegment(
                  value: McpServerKind.local,
                  icon: AppIconography.terminal,
                  label: l10n.e7LibraryLocalCommand,
                ),
              ],
            ),
            _gap(context),
            // Both sets stay mounted so switching back keeps what was
            // typed, and a header's secret field is never remounted with
            // a value in it (SEC-3).
            Visibility(
              visible: _kind == McpServerKind.remote,
              maintainState: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _remoteFields(context, l10n),
              ),
            ),
            Visibility(
              visible: _kind == McpServerKind.local,
              maintainState: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _localFields(context, l10n),
              ),
            ),
            _gap(context),
            KitRowGroup(
              margin: EdgeInsets.zero,
              children: [
                KitExpandRow(
                  headerKey: const ValueKey('mcp-advanced'),
                  title: l10n.mcpSetupAdvanced,
                  supporting: TextSpan(
                    text: _kind == McpServerKind.remote
                        ? l10n.mcpSetupAdvancedRemote
                        : l10n.mcpSetupAdvancedLocal,
                  ),
                  maintainState: true,
                  expanded: _advancedOpen,
                  onExpansionChanged: (open) =>
                      setState(() => _advancedOpen = open),
                  children: [_advanced(context, l10n)],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _gap(BuildContext context) =>
      SizedBox(height: KitTokens.of(context).space5);

  Widget _label(BuildContext context, String text) => Padding(
    padding: EdgeInsetsDirectional.only(bottom: KitTokens.of(context).space2),
    child: KitText(text, role: KitTextRole.label, tone: KitTextTone.secondary),
  );

  String? _disabledReason(AppLocalizations l10n) => _editable
      ? null
      : _configurationSaved
      ? l10n.mcpSavedStatus
      : _detached
      ? l10n.mcpSetupLocationChangedShort
      : l10n.e7LibrarySavingConfiguration;

  /// Saved in OpenCode, but the page is still open: the app did not
  /// reconnect, or the location changed after the write. The form gives
  /// way to what happened and the one thing left to do.
  Widget _savedScreen(BuildContext context, AppLocalizations l10n) {
    final error = _saveError;
    final name = _name.text.trim();
    return KitScreen(
      width: KitScreenWidth.list,
      topBar: KitTopBar(
        title: l10n.mcpAdd,
        subtitle: widget.controller.profile?.name,
      ),
      bottom: KitActionBlock(
        primary: KitAction(
          key: const ValueKey('mcp-save'),
          label: l10n.isolatedTaskClose,
          icon: AppIconography.check,
          onPressed: _saving ? null : () => Navigator.pop(context, true),
          disabledReason: _saving ? l10n.mcpReconnecting : null,
        ),
        secondary: error == null
            ? null
            : KitAction(
                key: const ValueKey('mcp-retry-reconnect'),
                label: l10n.mcpRetryReconnect,
                icon: AppIconography.retry,
                working: _saving,
                disabledReason: _detached || !_scopeMatches
                    ? l10n.mcpSetupLocationChangedShort
                    : null,
                onPressed: _saving || _detached || !_scopeMatches
                    ? null
                    : _retryReconnect,
              ),
      ),
      body: ListView(
        padding: KitScreen.padding(context),
        children: [
          KitStateView(
            key: const ValueKey('mcp-saved-status'),
            icon: error == null
                ? AppIconography.checkCircle
                : AppIconography.warning,
            tone: error == null ? AppStatusTone.ok : AppStatusTone.failure,
            title: name.isEmpty
                ? l10n.mcpSavedStatus
                : l10n.mcpSetupSavedNamed(name),
            body: error != null
                ? l10n.mcpSetupSavedNotConnectedBody(error)
                : l10n.mcpSetupSavedElsewhere,
            size: KitStateSize.inline,
          ),
        ],
      ),
    );
  }

  /// The one condition on the form, on the screen's status line.
  KitStatus? _status(AppLocalizations l10n) {
    final error = _saveError;
    if (_detached) {
      return KitStatus(
        id: 'mcp-setup:detached',
        kind: KitStatusKind.info,
        icon: AppIconography.warning,
        message: l10n.mcpLocationChanged,
      );
    }
    if (error != null) {
      return KitStatus(
        id: 'mcp-setup:save-failed',
        kind: KitStatusKind.info,
        icon: AppIconography.warning,
        tone: AppStatusTone.failure,
        message: l10n.mcpSetupSaveFailed,
        supporting: error,
      );
    }
    return null;
  }

  KitAction _primary(AppLocalizations l10n) {
    final name = _name.text.trim();
    return KitAction(
      key: const ValueKey('mcp-save'),
      label: _saving
          ? (_runtime ? l10n.mcpAdding : l10n.e7LibrarySavingConfiguration)
          : name.isEmpty
          ? (_runtime ? l10n.mcpAdd : l10n.e7LibrarySaveMCPServer)
          : (_runtime
                ? l10n.mcpSetupAddNamed(name)
                : l10n.mcpSetupSaveNamed(name)),
      icon: _runtime ? AppIconography.add : AppIconography.save,
      working: _saving,
      disabledReason: _detached ? l10n.mcpSetupLocationChangedShort : null,
      onPressed: _detached ? null : _save,
    );
  }

  List<Widget> _whereSection(BuildContext context, AppLocalizations l10n) {
    final tokens = KitTokens.of(context);
    if (_runtime) {
      final place = [
        if (_hasProject) _directory!,
        if (_workspace?.isNotEmpty == true)
          l10n.mcpWorkspaceLocation(_workspace!),
        if (!_hasProject && _workspace?.isNotEmpty != true)
          l10n.mcpDefaultLocation,
      ].join('\n');
      return [
        KitRowGroup(
          margin: EdgeInsets.zero,
          label: l10n.mcpSetupWhere,
          children: [
            KitRow(
              key: const ValueKey('mcp-location'),
              leading: KitRow.icon(context, AppIconography.clock),
              title: l10n.mcpRuntimeTitle,
              supporting: TextSpan(text: place),
              supportingMaxLines: 3,
            ),
          ],
        ),
        SizedBox(height: tokens.space2),
        KitText(
          l10n.mcpSetupRuntimeNote,
          role: KitTextRole.caption,
          tone: KitTextTone.secondary,
        ),
      ];
    }
    return [
      _label(context, l10n.mcpSetupWhere),
      KitSegmented<McpConfigScope>(
        key: const ValueKey('mcp-scope'),
        semanticsLabel: l10n.mcpSetupWhere,
        selected: _scope,
        disabledReason: _disabledReason(l10n),
        onChanged: !_editable
            ? null
            : (value) => setState(() => _scope = value),
        segments: [
          KitSegment(
            value: McpConfigScope.project,
            icon: AppIconography.files,
            label: l10n.e7LibraryThisProject,
            enabled: _hasProject,
            disabledReason: _hasProject ? null : l10n.mcpSetupNoProject,
          ),
          KitSegment(
            value: McpConfigScope.global,
            icon: AppIconography.globe,
            label: l10n.usageAllProjects,
          ),
        ],
      ),
      SizedBox(height: tokens.space2),
      KitText(
        _scope == McpConfigScope.project
            ? l10n.e7LibraryWritesOnlyTo(_directory ?? '')
            : l10n.e7LibraryWritesToThisOpenCodeServerSGlobal,
        role: KitTextRole.caption,
        tone: KitTextTone.secondary,
      ),
    ];
  }

  List<Widget> _remoteFields(BuildContext context, AppLocalizations l10n) {
    return [
      KitField(
        label: l10n.e7LibraryMCPEndpointURL,
        controller: _url,
        kind: KitFieldKind.url,
        hint: 'https://server.example/mcp',
        helper: l10n.e7LibraryHTTPIsAcceptedForLocalDevelopmentServers,
        error: _shown(_urlError),
        enabled: _editable,
        disabledReason: _disabledReason(l10n),
        textInputAction: TextInputAction.next,
        onChanged: _edited,
        fieldKey: const ValueKey('mcp-url'),
      ),
      _gap(context),
      ..._pairRows(context, l10n, _headerRows, header: true),
    ];
  }

  /// Name-and-secret-value rows (headers for a remote server, environment
  /// variables for a local one), with Add another under them.
  List<Widget> _pairRows(
    BuildContext context,
    AppLocalizations l10n,
    List<_PairRow> rows, {
    required bool header,
  }) {
    final tokens = KitTokens.of(context);
    return [
      _label(
        context,
        header ? l10n.mcpSetupHeaders : l10n.e7LibraryEnvironmentVariables,
      ),
      for (var index = 0; index < rows.length; index++) ...[
        _pairRow(context, l10n, rows, index, header: header),
        SizedBox(height: tokens.space4),
      ],
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: KitButton.tertiary(
          key: ValueKey(header ? 'mcp-header-add' : 'mcp-env-add'),
          label: header ? l10n.mcpAddHeader : l10n.mcpAddVariable,
          icon: AppIconography.add,
          onPressed: !_editable
              ? null
              : () => setState(() => rows.add(_PairRow())),
        ),
      ),
    ];
  }

  /// One header or variable: its name stays visible; its value is a
  /// secret field that is never prefilled (P0.1, SEC-3). The pair's error
  /// sits under the last value. A name the catalogue listing requires is
  /// fixed, and its row cannot be removed.
  Widget _pairRow(
    BuildContext context,
    AppLocalizations l10n,
    List<_PairRow> rows,
    int index, {
    required bool header,
  }) {
    final tokens = KitTokens.of(context);
    final row = rows[index];
    final denyNewlines = [FilteringTextInputFormatter.deny(RegExp(r'[\r\n]'))];
    final last = index == rows.length - 1;
    final prefix = header ? 'mcp-header' : 'mcp-env';
    return Column(
      key: ObjectKey(row),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: KitField(
                label: header ? l10n.mcpHeaderName : l10n.mcpVariableName,
                controller: row.key,
                kind: KitFieldKind.mono,
                hint: index == 0
                    ? (header ? 'Authorization' : 'API_KEY')
                    : null,
                enabled: _editable && !row.prefilled,
                disabledReason: row.prefilled && _editable
                    ? l10n.mcpSetupNameFromCatalog
                    : _disabledReason(l10n),
                inputFormatters: denyNewlines,
                onChanged: _edited,
                fieldKey: ValueKey('$prefix-key-$index'),
              ),
            ),
            if (rows.length > 1 && !row.prefilled) ...[
              SizedBox(width: tokens.space1),
              KitIconButton(
                key: ValueKey('$prefix-remove-$index'),
                icon: AppIconography.close,
                tooltip: header ? l10n.mcpRemoveHeader : l10n.mcpRemoveVariable,
                onPressed: !_editable
                    ? null
                    : () => setState(() {
                        rows[index].dispose();
                        rows.removeAt(index);
                      }),
              ),
            ],
          ],
        ),
        SizedBox(height: tokens.space2),
        KitField.secret(
          label: header ? l10n.mcpHeaderValue : l10n.mcpVariableValue,
          controller: row.value,
          hint: index == 0 && header && !row.prefilled ? 'Bearer token' : null,
          error: last
              ? _shown(header ? _headersError : _environmentError)
              : null,
          enabled: _editable,
          disabledReason: _disabledReason(l10n),
          inputFormatters: denyNewlines,
          onChanged: _edited,
          fieldKey: ValueKey('$prefix-value-$index'),
          revealKey: ValueKey('$prefix-reveal-$index'),
        ),
      ],
    );
  }

  List<Widget> _localFields(BuildContext context, AppLocalizations l10n) => [
    KitField(
      label: l10n.e7LibraryCommandAndArguments,
      controller: _command,
      kind: KitFieldKind.mono,
      maxLines: 8,
      hint: 'npx\n-y\n@package/mcp-server',
      helper: l10n.e7LibraryRunsOnTheOpenCodeServerNotThis,
      error: _shown(_commandError),
      enabled: _editable,
      disabledReason: _disabledReason(l10n),
      onChanged: _edited,
      fieldKey: const ValueKey('mcp-command'),
    ),
    _gap(context),
    ..._pairRows(context, l10n, _envRows, header: false),
  ];

  /// The rarer settings, folded (map proposal "the rest under Advanced").
  Widget _advanced(BuildContext context, AppLocalizations l10n) {
    final tokens = KitTokens.of(context);
    final gap = SizedBox(height: tokens.space4);
    return Padding(
      padding: EdgeInsetsDirectional.only(
        start: tokens.space4,
        end: tokens.space4,
        bottom: tokens.space4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_kind == McpServerKind.remote)
            KitSwitchRow(
              switchKey: const ValueKey('mcp-oauth-detection'),
              title: l10n.e7LibraryDetectOAuthAutomatically,
              supporting: l10n.e7LibraryTurnThisOffWhenTheServerUses,
              value: _detectOAuth,
              disabledReason: _disabledReason(l10n),
              onChanged: !_editable
                  ? null
                  : (value) => setState(() => _detectOAuth = value),
            )
          else ...[
            KitField(
              label: l10n.e7LibraryWorkingDirectory,
              controller: _cwd,
              kind: KitFieldKind.path,
              hint: l10n.e7LibraryOptionalServerPath,
              enabled: _editable,
              disabledReason: _disabledReason(l10n),
              textInputAction: TextInputAction.next,
              onChanged: _edited,
              fieldKey: const ValueKey('mcp-cwd'),
            ),
          ],
          gap,
          KitField(
            label: l10n.mcpSetupTimeoutSeconds,
            controller: _timeout,
            kind: KitFieldKind.number,
            hint: l10n.e7LibraryOptional,
            error: _shown(_timeoutError),
            enabled: _editable,
            disabledReason: _disabledReason(l10n),
            onChanged: _edited,
            fieldKey: const ValueKey('mcp-timeout'),
          ),
        ],
      ),
    );
  }

  /// The rows as `KEY=VALUE` lines, exactly what the old single field held,
  /// so [_pairs] and [_pairError] need no change. A row left entirely empty
  /// (the default extra row) never becomes a line.
  String _draftText(List<_PairRow> rows) => rows
      .where(
        (row) =>
            row.key.text.trim().isNotEmpty || row.value.text.trim().isNotEmpty,
      )
      .map((row) => '${row.key.text}=${row.value.text}')
      .join('\n');

  static List<String> _lines(String value) => value
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();

  Map<String, String> _pairs(String value, String label) {
    final l10n = _l10nOf(context);
    final result = <String, String>{};
    final lines = value.split('\n');
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].trim();
      if (line.isEmpty) continue;
      final separator = line.indexOf('=');
      if (separator < 1) {
        throw ProductException(
          l10n.e7LibraryInvalidOnLineUseKEYVALUE(label, '${index + 1}'),
        );
      }
      final key = line.substring(0, separator).trim();
      final content = line.substring(separator + 1).trim();
      if (key.isEmpty || key.contains(RegExp(r'[\r\n=]'))) {
        throw ProductException(
          l10n.e7LibraryInvalidNameOnLine(label, '${index + 1}'),
        );
      }
      if (result.containsKey(key)) {
        throw ProductException(l10n.e7LibraryDuplicateName(label, key));
      }
      result[key] = content;
    }
    return result;
  }

  String? _pairError(String value, String label) {
    try {
      _pairs(value, label);
      return null;
    } on ProductException catch (error) {
      return error.message;
    }
  }
}

/// One header or environment variable pair's editing state (P0.1). Its
/// value field masks itself (KitField.secret) until the person presses show
/// for that row. [prefilled]: the name came from a catalogue listing that
/// requires it, so the name is fixed and the value must be entered.
class _PairRow {
  _PairRow({String? name})
    : key = TextEditingController(text: name),
      value = TextEditingController(),
      prefilled = name != null;

  final TextEditingController key;
  final TextEditingController value;
  final bool prefilled;

  void dispose() {
    key.dispose();
    value.dispose();
  }
}
