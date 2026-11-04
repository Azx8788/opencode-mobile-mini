import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../builtin/builtin_linux.dart';
import '../../builtin/builtin_provider_store.dart';
import '../../builtin/builtin_provider_templates.dart';
import '../../builtin/builtin_server.dart' show looksLikeInAppServer;
import '../../domain/custom_provider.dart';
import '../../domain/custom_provider_record.dart';
import '../../domain/provider_balance.dart';
import '../../domain/provider_model_source.dart';
import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import 'provider_probe_screen.dart';
import '../app_iconography.dart';
import '../app_theme.dart' show AppStatusTone;
import '../kit/kit.dart';

AppLocalizations _l10nOf(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

enum _Tab { config, models, advanced }

/// One provider, in three tabs the way the person thinks about it:
/// configuration, models, advanced.
///
/// The address, key and protocol live on the first tab; the second asks the
/// provider for its own model list with exactly those values — saved or not
/// — and ticks what to enable; the third holds what only some gateways need
/// (extra headers) and the three connection checks.
///
/// This is config-file work, not API work: the entry is written into the
/// in-app server's `opencode.json`. On a server whose files the app cannot
/// reach, the same form still produces the snippet to paste, and says why it
/// cannot write.
class CustomProviderScreen extends StatefulWidget {
  final ConnectionController controller;

  /// The in-app server bridge. Null means "make one" — instances are cheap.
  final BuiltinLinux? linux;

  /// An entry to edit. Null adds a new one.
  ///
  /// Editing keeps the id: renaming a provider means removing it and adding
  /// another, because every conversation pinned to it would lose its model.
  final CustomProviderRecord? editing;

  /// A template the person chose for a new entry: it prefills the name, the
  /// address and the protocol; nothing is written until Save.
  final BuiltinProviderTemplate? template;

  const CustomProviderScreen({
    super.key,
    required this.controller,
    this.linux,
    this.editing,
    this.template,
  });

  @override
  State<CustomProviderScreen> createState() => _CustomProviderScreenState();
}

class _CustomProviderScreenState extends State<CustomProviderScreen> {
  final _name = TextEditingController();
  final _id = TextEditingController();
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  final _manualModel = TextEditingController();
  final _search = TextEditingController();
  final _balanceUrl = TextEditingController();
  final _balancePath = TextEditingController();
  final List<_HeaderRow> _headers = [];

  late final BuiltinLinux _linux = widget.linux ?? BuiltinLinux();
  late final BuiltinProviderStore _store = BuiltinProviderStore(linux: _linux);
  late final ProviderModelSource _models = ProviderModelSource();
  final ProviderBalanceClient _balanceClient = ProviderBalanceClient();

  ProviderProtocol _protocol = ProviderProtocol.chatCompletions;
  ResolvedProviderConfig? _resolved;
  List<CustomProviderModel> _listed = const [];
  final Set<String> _selected = {};
  String _query = '';
  bool _fetching = false;
  String? _fetchError;
  bool _saving = false;
  String? _saveError;
  ProviderWriteReceipt? _receipt;
  bool _reloaded = false;
  bool _autoID = true;
  String? _resolveError;
  _Tab _tab = _Tab.config;

  /// Tabs that have been opened once. They stay mounted after that, so the
  /// key field is not rebuilt with a value it must not be prefilled with,
  /// and a model search survives a look at another tab.
  final Set<_Tab> _visited = {_Tab.config};

  /// The provider-level switch: local to this phone, never written to the
  /// server's config.
  bool _enabled = true;
  bool _balanceEnabled = false;
  bool _balanceLoading = false;
  ProviderBalanceReading? _balanceReading;
  String? _balanceError;

  /// True when this profile is the server the app itself runs, whose files
  /// this app may write.
  bool get _writable => looksLikeInAppServer(widget.controller.profile);

  /// True when editing an entry already in the config.
  bool get _editing => widget.editing != null;

  /// True when the id is not the person's to type: an entry already saved
  /// keeps its id, and a shipped provider keeps the one the app ships it
  /// under (so `openai` cannot become a second OpenAI beside itself).
  bool get _idLocked => _editing || widget.template != null;

  /// True when the entry already has a key somewhere; the field then shows
  /// "Saved · Replace" instead of an empty box that looks like a lost key.
  bool get _hasStoredKey {
    final editing = widget.editing;
    if (editing == null) return false;
    return (editing.apiKey?.isNotEmpty ?? false) ||
        editing.secretPath != null ||
        editing.keyPlaceholder != null;
  }

  /// True when the key belongs to the server (a `{env:…}` reference or a
  /// server sign-in) and this app cannot read it.
  bool get _keyOnServer => widget.editing?.keyMode == ProviderKeyMode.external;

  ProviderConfigFormat get _format =>
      _resolved?.format ?? ProviderConfigFormat.v2;

  /// The template this entry came from, if any: its address is what "restore
  /// default" restores.
  BuiltinProviderTemplate? get _template {
    final id = _editing ? widget.editing!.id : widget.template?.id;
    if (id == null) return widget.template;
    return providerTemplateFor(id) ?? widget.template;
  }

  String get _defaultBaseUrl => _template?.baseUrl ?? '';

  bool get _canResetBaseUrl =>
      _defaultBaseUrl.isNotEmpty && _baseUrl.text.trim() != _defaultBaseUrl;

  @override
  void initState() {
    super.initState();
    final editing = widget.editing;
    final template = widget.template;
    if (editing != null) {
      _name.text = editing.name;
      _id.text = editing.id;
      _baseUrl.text = editing.baseUrl;
      _protocol = editing.protocol;
      _listed = editing.models;
      _selected.addAll(editing.models.map((model) => model.id));
      _autoID = false;
      for (final header in editing.headers) {
        _headers.add(_HeaderRow(name: header.name, value: header.value));
      }
      _enabled = !widget.controller.isProviderHidden(editing.id);
      final balance = widget.controller.balanceFor(editing.id);
      if (balance != null) {
        _balanceEnabled = balance.enabled;
        _balanceUrl.text = balance.url;
        _balancePath.text = balance.resultPath;
      }
    } else if (template != null) {
      _name.text = template.name;
      _id.text = template.id;
      _baseUrl.text = template.baseUrl;
      _protocol = template.protocol;
      // A shipped provider keeps the id it is shipped under: `openai` must
      // stay `openai`, or saving it would add a second OpenAI beside the one
      // the model picker already knows.
      _autoID = false;
      final balance = template.balance;
      if (balance != null) {
        _balanceUrl.text = balance.url;
        _balancePath.text = balance.resultPath;
      }
    }
    _id.addListener(() {
      final fixed = CustomProviderDraft.normalizeProviderId(_id.text);
      if (_id.text == fixed) return;
      // The field shows what will be saved: a typed id with a space does not
      // look accepted and then change under the person on save.
      final at = _id.selection.baseOffset;
      _id.value = TextEditingValue(
        text: fixed,
        selection: TextSelection.collapsed(offset: at.clamp(0, fixed.length)),
      );
    });
    _prepare();
  }

  Future<void> _prepare() async {
    if (!_writable) return;
    try {
      final resolved = await _store.resolve();
      if (!mounted) return;
      setState(() {
        _resolved = resolved;
        _resolveError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _resolveError = '$error');
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _id.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _manualModel.dispose();
    _search.dispose();
    _balanceUrl.dispose();
    _balancePath.dispose();
    for (final row in _headers) {
      row.dispose();
    }
    super.dispose();
  }

  CustomProviderDraft _draft() {
    final typedKey = _apiKey.text.trim();
    final editing = widget.editing;
    final keyMode = typedKey.isNotEmpty
        ? ProviderKeyMode.secretFile
        : editing?.keyMode ?? ProviderKeyMode.secretFile;
    return CustomProviderDraft(
      name: _name.text,
      id: _id.text.isEmpty ? _name.text : _id.text,
      protocol: _protocol,
      baseUrl: _baseUrl.text,
      apiKey: typedKey.isNotEmpty
          ? typedKey
          : keyMode == ProviderKeyMode.plaintext
          ? editing?.apiKey
          : null,
      keyMode: keyMode,
      keyPlaceholder: editing?.keyPlaceholder,
      keyFile: editing?.secretPath,
      models: [
        for (final id in _selected)
          _listed.firstWhere(
            (model) => model.id == id,
            orElse: () => CustomProviderModel(id: id),
          ),
      ],
      headers: [
        for (final row in _headers)
          CustomProviderHeader(name: row.name.text, value: row.value.text),
      ],
    );
  }

  Map<String, String> _headerMap() => _draft().headerMap;

  /// The key for the app's own requests: what was just typed, else what the
  /// entry already has (a value in the config, or a file this app can read).
  Future<String> _resolveKey() async {
    final typed = _apiKey.text.trim();
    if (typed.isNotEmpty) return typed;
    final editing = widget.editing;
    if (editing == null) return '';
    if (editing.apiKey case final key? when key.isNotEmpty) return key;
    final path = editing.secretPath;
    if (path != null) {
      final key = await _store.readSecret(path);
      if (key != null) return key;
    }
    return '';
  }

  /// The snippet to show and to copy. Null until the form says enough to
  /// produce one — a preview of half a provider teaches nothing. Empty when
  /// the form is not ready yet.
  String? get _previewText {
    if (!_formReady) return '';
    try {
      return const JsonEncoder.withIndent(
        '  ',
      ).convert(_draft().toDocument(_format));
    } catch (_) {
      return null;
    }
  }

  bool get _formReady =>
      _name.text.trim().isNotEmpty &&
      _baseUrl.text.trim().isNotEmpty &&
      _selected.isNotEmpty;

  Future<void> _fetchModels() async {
    if (_fetching) return;
    setState(() {
      _fetching = true;
      _fetchError = null;
    });
    try {
      final key = await _resolveKey();
      final models = await _models.fetch(
        baseUrl: CustomProviderDraft.normalizeBaseUrl(_baseUrl.text, _protocol),
        protocol: _protocol,
        apiKey: key,
        headers: _headerMap(),
      );
      if (!mounted) return;
      setState(() {
        _listed = models;
        _fetching = false;
        // A first fetch selects everything: the common case is "all of this
        // gateway", and unticking a few is less work than ticking many.
        if (_selected.isEmpty) {
          _selected.addAll(models.map((model) => model.id));
        }
      });
    } on ProviderModelFetchFailure catch (error) {
      if (!mounted) return;
      setState(() {
        _fetchError = error.message;
        _fetching = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _fetchError = '$error';
        _fetching = false;
      });
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final draft = _draft();
      draft.validate();
      final resolved = _resolved ?? await _store.resolve();
      final receipt = await _store.save(
        draft,
        resolved: resolved,
        replace: _editing,
      );
      // The provider-level switch and the balance endpoint are local
      // preferences, not part of the config: save them beside the entry.
      await widget.controller.setProviderHidden(draft.id, !_enabled);
      await widget.controller.setBalance(
        draft.id,
        ProviderBalance(
          enabled: _balanceEnabled,
          url: _balanceUrl.text.trim(),
          resultPath: _balancePath.text.trim(),
        ),
      );
      final reloaded = await _tryReload();
      if (!mounted) return;
      setState(() {
        _receipt = receipt;
        _reloaded = reloaded;
        _saving = false;
        _resolved = resolved;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saveError = error is ProviderWriteRefused
            ? _refusedMessage(error)
            : _messageFor(error);
        _saving = false;
      });
      // A refusal may mean the file changed outside the app: re-read it so
      // the next attempt merges into what is actually there.
      if (error is ProviderWriteRefused) _prepare();
    }
  }

  Future<void> _delete() async {
    final editing = widget.editing;
    if (editing == null || _saving) return;
    final l10n = _l10nOf(context);
    final agreed = await showKitConfirm(
      context,
      title: l10n.providerManageDeleteTitle(editing.name),
      body: l10n.providerManageDeleteBody,
      confirmLabel: l10n.providerManageDelete,
      kind: KitConfirmKind.destructive,
      icon: AppIconography.delete,
      confirmKey: const ValueKey('provider-detail-delete-confirm'),
    );
    if (!agreed || !mounted) return;
    setState(() => _saving = true);
    try {
      final resolved = _resolved ?? await _store.resolve();
      await _store.remove(editing.id, resolved: resolved);
      await widget.controller.setProviderHidden(editing.id, false);
      await widget.controller.setBalance(editing.id, const ProviderBalance());
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = '$error';
      });
    }
  }

  /// v2 can reload its configuration without dropping the process, so a new
  /// provider appears without disconnecting. An older server answers 404 and
  /// the confirmation says to restart instead.
  Future<bool> _tryReload() async {
    final profile = widget.controller.profile;
    if (profile == null) return false;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final url = Uri.parse('${profile.baseUrl}/api/location/reload');
      final request = await client
          .postUrl(url)
          .timeout(const Duration(seconds: 5));
      if (profile.username.isNotEmpty) {
        final token = base64Encode(
          utf8.encode('${profile.username}:${profile.password}'),
        );
        request.headers.set(HttpHeaders.authorizationHeader, 'Basic $token');
      }
      request.headers.contentLength = 0;
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      await response.drain<void>();
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  String _refusedMessage(ProviderWriteRefused error) {
    final l10n = _l10nOf(context);
    if (error.reason == 'jsonc') return l10n.providerAddWithComments;
    if (error.reason == 'merge' && '$error'.contains('already exists')) {
      return l10n.providerAddExists;
    }
    return error.message;
  }

  String _messageFor(Object error) {
    final text = '$error';
    if (text.contains('already exists')) {
      return _l10nOf(context).providerAddExists;
    }
    if (text.contains('comments')) {
      return _l10nOf(context).providerAddWithComments;
    }
    return text;
  }

  void _toggle(String id, bool on) {
    setState(() {
      if (on) {
        _selected.add(id);
      } else {
        _selected.remove(id);
      }
    });
  }

  void _addManualModel() {
    final id = _manualModel.text.trim();
    if (id.isEmpty) return;
    setState(() {
      if (!_listed.any((model) => model.id == id)) {
        _listed = [..._listed, CustomProviderModel(id: id)];
      }
      _selected.add(id);
      _manualModel.clear();
    });
  }

  void _addHeader() {
    setState(() => _headers.add(_HeaderRow()));
  }

  void _removeHeader(_HeaderRow row) {
    setState(() => _headers.remove(row));
    row.dispose();
  }

  void _switchProtocol(ProviderProtocol next) {
    if (next == _protocol) return;
    final switched = _draft().switchProtocol(next);
    setState(() {
      _protocol = next;
      _baseUrl.text = switched.baseUrl;
      _fetchError = null;
    });
  }

  Future<void> _pickHeaderPreset(_HeaderRow row) async {
    final l10n = _l10nOf(context);
    final chosen = await showKitSheet<String>(
      context,
      title: l10n.providerHeadersPresets,
      itemCount: providerHeaderPresets.length,
      itemBuilder: (sheetContext, index) {
        final name = providerHeaderPresets[index];
        return KitRow(
          title: name,
          onTap: () => Navigator.of(sheetContext).pop(name),
        );
      },
    );
    if (chosen == null || !mounted) return;
    setState(() => row.name.text = chosen);
  }

  Future<void> _queryBalance() async {
    if (_balanceLoading) return;
    setState(() {
      _balanceLoading = true;
      _balanceError = null;
      _balanceReading = null;
    });
    try {
      final key = await _resolveKey();
      final reading = await _balanceClient.fetch(
        balance: ProviderBalance(
          enabled: true,
          url: _balanceUrl.text,
          resultPath: _balancePath.text,
        ),
        baseUrl: CustomProviderDraft.normalizeBaseUrl(_baseUrl.text, _protocol),
        apiKey: key,
        headers: _headerMap(),
      );
      if (!mounted) return;
      setState(() {
        _balanceReading = reading;
        _balanceLoading = false;
      });
    } on ProviderBalanceFailure catch (error) {
      if (!mounted) return;
      setState(() {
        _balanceError = error.message;
        _balanceLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _balanceError = '$error';
        _balanceLoading = false;
      });
    }
  }

  Future<void> _testNow() async {
    final models = _selected.toList();
    if (models.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProviderProbeScreen(
          providerName: _name.text.trim().isEmpty
              ? _id.text.trim()
              : _name.text.trim(),
          model: models.first,
          models: models,
          baseUrl: CustomProviderDraft.normalizeBaseUrl(
            _baseUrl.text,
            _protocol,
          ),
          protocol: _protocol,
          apiKey: _apiKey.text,
          resolveKey: _resolveKey,
          headers: _headerMap(),
          autoRun: true,
        ),
      ),
    );
  }

  Future<void> _copySnippet() async {
    final text = _previewText;
    if (text == null || text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(_l10nOf(context).providerAddCopy)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10nOf(context);
    if (_receipt != null) return _savedScreen(context, l10n);
    final canSave = _writable && _formReady && !_saving;
    return KitScreen(
      width: KitScreenWidth.list,
      topBar: KitTopBar(
        // Named as soon as it has a name: a shipped provider opens titled
        // "OpenAI", not "Add a provider", because that is what is being
        // configured.
        title: _name.text.trim().isNotEmpty
            ? _name.text.trim()
            : (_editing ? l10n.providerEditTitle : l10n.providerAddTitle),
        subtitle: widget.controller.profile?.name,
        actions: [
          KitAction(
            key: const ValueKey('provider-detail-test-top'),
            label: l10n.providerEditTest,
            icon: AppIconography.play,
            onPressed: _selected.isEmpty ? null : _testNow,
            disabledReason: l10n.providerAddNeedModels,
          ),
        ],
      ),
      status: _saving
          ? KitStatus(
              kind: KitStatusKind.work,
              icon: AppIconography.waiting,
              message: l10n.providerAddSaving,
              tone: AppStatusTone.progress,
            )
          : _saveError == null
          ? null
          : KitStatus(
              kind: KitStatusKind.info,
              icon: AppIconography.warning,
              message: _saveError!,
              tone: AppStatusTone.failure,
            ),
      bottom: KitActionBlock(
        primary: KitAction(
          label: l10n.providerAddSave,
          icon: AppIconography.save,
          working: _saving,
          disabledReason: !_writable
              ? l10n.providerAddCopyOnly
              : !_formReady
              ? l10n.providerAddNeedModels
              : null,
          onPressed: canSave ? _save : null,
        ),
        secondary: KitAction(
          label: l10n.providerEditTest,
          icon: AppIconography.play,
          disabledReason: _selected.isEmpty ? l10n.providerAddNeedModels : null,
          onPressed: _selected.isEmpty ? null : _testNow,
        ),
        tertiary: [
          if ((_previewText ?? '').isNotEmpty)
            KitAction(
              label: l10n.providerAddCopy,
              icon: AppIconography.copy,
              onPressed: _copySnippet,
            ),
          if (_editing)
            KitAction(
              label: l10n.providerManageDelete,
              icon: AppIconography.delete,
              destructive: true,
              onPressed: _saving ? null : _delete,
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              _pad(context).start,
              _pad(context).top,
              _pad(context).end,
              0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!_writable)
                  KitNotice(
                    key: const ValueKey('custom-provider-copy-only'),
                    tone: AppStatusTone.attention,
                    icon: AppIconography.warning,
                    message: l10n.providerAddCopyOnly,
                  ),
                if (!_writable && _resolveError != null)
                  SizedBox(height: _space(context) / 2),
                if (_resolveError != null)
                  KitNotice(
                    key: const ValueKey('custom-provider-resolve-failed'),
                    tone: AppStatusTone.failure,
                    icon: AppIconography.warning,
                    message: _resolveError!,
                  ),
                if (!_writable || _resolveError != null)
                  SizedBox(height: _space(context)),
                _tabs(context, l10n),
              ],
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: _tab.index,
              children: [
                _tabList(context, _configTab(context, l10n)),
                _visited.contains(_Tab.models)
                    ? _tabList(context, _modelsTab(context, l10n))
                    : const SizedBox.shrink(),
                _visited.contains(_Tab.advanced)
                    ? _tabList(context, _advancedTab(context, l10n))
                    : const SizedBox.shrink(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  EdgeInsetsDirectional _pad(BuildContext context) =>
      KitScreen.padding(context);

  Widget _tabList(BuildContext context, List<Widget> children) {
    final pad = _pad(context);
    return ListView(
      padding: EdgeInsetsDirectional.fromSTEB(
        pad.start,
        _space(context),
        pad.end,
        pad.bottom,
      ),
      children: children,
    );
  }

  Widget _tabs(BuildContext context, AppLocalizations l10n) =>
      KitSegmented<_Tab>(
        segments: [
          KitSegment(value: _Tab.config, label: l10n.providerTabConfig),
          KitSegment(
            value: _Tab.models,
            label: l10n.providerTabModels,
            count: _selected.isEmpty ? null : _selected.length,
          ),
          KitSegment(value: _Tab.advanced, label: l10n.providerTabAdvanced),
        ],
        selected: _tab,
        semanticsLabel: l10n.providerAddTitle,
        onChanged: (value) => setState(() {
          _tab = value;
          _visited.add(value);
        }),
      );

  // ---------------- Configuration ----------------

  List<Widget> _configTab(BuildContext context, AppLocalizations l10n) => [
    KitSwitchRow(
      key: const ValueKey('provider-detail-enabled'),
      title: l10n.providerEnable,
      value: _enabled,
      supporting: l10n.providerEnableHint,
      switchKey: const ValueKey('provider-detail-enabled-switch'),
      onChanged: (value) => setState(() => _enabled = value),
    ),
    KitSectionLabel(l10n.providerAddConnection, gapBefore: _space(context)),
    KitField(
      label: l10n.providerAddName,
      controller: _name,
      hint: l10n.providerAddNameHint,
      textInputAction: TextInputAction.next,
      onChanged: (value) {
        if (_autoID) {
          _id.text = CustomProviderDraft.normalizeProviderId(value);
        }
        setState(() {});
      },
      fieldKey: const ValueKey('custom-provider-name'),
    ),
    _gap(context),
    KitField.secret(
      label: l10n.providerAddApiKey,
      controller: _apiKey,
      helper: l10n.providerAddApiKeyHelper,
      textInputAction: TextInputAction.next,
      saved: _hasStoredKey,
      onChanged: (_) => setState(() {}),
      fieldKey: const ValueKey('custom-provider-api-key'),
    ),
    _gap(context),
    KitField(
      label: l10n.providerAddBaseUrl,
      controller: _baseUrl,
      kind: KitFieldKind.url,
      hint: 'https://api.example.com/v1',
      helper: l10n.providerAddBaseUrlHelper,
      textInputAction: TextInputAction.next,
      action: _canResetBaseUrl
          ? KitAction(
              label: l10n.providerResetDefault,
              icon: AppIconography.restore,
              onPressed: () => setState(() => _baseUrl.text = _defaultBaseUrl),
            )
          : null,
      onChanged: (_) => setState(() {}),
      fieldKey: const ValueKey('custom-provider-base-url'),
    ),
    KitSectionLabel(l10n.providerAddProtocol, gapBefore: _space(context)),
    KitSegmented<ProviderProtocol>(
      segments: [
        KitSegment(
          value: ProviderProtocol.chatCompletions,
          label: l10n.providerAddProtocolChat,
        ),
        KitSegment(
          value: ProviderProtocol.responses,
          label: l10n.providerAddProtocolResponses,
        ),
        KitSegment(
          value: ProviderProtocol.anthropic,
          label: l10n.providerAddProtocolAnthropic,
        ),
        const KitSegment(value: ProviderProtocol.google, label: 'Google'),
      ],
      selected: _protocol,
      semanticsLabel: l10n.providerAddProtocol,
      onChanged: _switchProtocol,
    ),
    if (_protocol == ProviderProtocol.responses &&
        !_isOfficialOpenAIHost(_baseUrl.text)) ...[
      _gap(context),
      KitNotice(
        key: const ValueKey('custom-provider-responses-warning'),
        tone: AppStatusTone.attention,
        icon: AppIconography.warning,
        message: l10n.providerResponsesWarning,
      ),
    ],
    _gap(context),
    KitRowGroup(
      margin: EdgeInsets.zero,
      children: [
        KitRow(
          key: const ValueKey('custom-provider-path'),
          title: l10n.providerPath,
          supporting: TextSpan(
            text:
                '${CustomProviderDraft.normalizeBaseUrl(_baseUrl.text, _protocol)}'
                '${_protocol.chatPath}',
          ),
          supportingMaxLines: 2,
        ),
      ],
    ),
    Padding(
      padding: EdgeInsetsDirectional.only(top: _space(context) / 2),
      child: Text(
        l10n.providerPathHelper,
        style: KitText.styleOf(context, KitTextRole.caption),
      ),
    ),
    _gap(context),
    KitField(
      label: l10n.providerAddId,
      controller: _id,
      kind: KitFieldKind.mono,
      helper: _idLocked ? null : l10n.providerAddIdHelper,
      enabled: !_idLocked,
      disabledReason: _idLocked ? l10n.providerEditIdLocked : null,
      onChanged: (_) {
        _autoID = false;
        setState(() {});
      },
      fieldKey: const ValueKey('custom-provider-id'),
    ),
    ..._balanceSection(context, l10n),
  ];

  List<Widget> _balanceSection(
    BuildContext context,
    AppLocalizations l10n,
  ) => [
    KitSectionLabel(l10n.providerBalanceSection, gapBefore: _space(context)),
    KitSwitchRow(
      key: const ValueKey('provider-balance-enabled'),
      title: l10n.providerBalanceEnable,
      value: _balanceEnabled,
      supporting: l10n.providerBalancePathHelper,
      switchKey: const ValueKey('provider-balance-switch'),
      onChanged: (value) => setState(() => _balanceEnabled = value),
    ),
    if (_balanceEnabled) ...[
      _gap(context),
      KitField(
        label: l10n.providerBalanceUrl,
        controller: _balanceUrl,
        kind: KitFieldKind.url,
        hint: '${ProviderBalance.baseUrlToken}/user/balance',
        helper: l10n.providerBalanceUrlHelper(
          ProviderBalance.baseUrlToken,
          ProviderBalance.apiKeyToken,
        ),
        onChanged: (_) => setState(() {}),
        fieldKey: const ValueKey('provider-balance-url'),
      ),
      _gap(context),
      KitField(
        label: l10n.providerBalancePath,
        controller: _balancePath,
        kind: KitFieldKind.mono,
        hint: 'balance_infos[0].total_balance',
        onChanged: (_) => setState(() {}),
        fieldKey: const ValueKey('provider-balance-path'),
      ),
      _gap(context),
      KitButton.secondary(
        key: const ValueKey('provider-balance-query'),
        label: l10n.providerBalanceQuery,
        icon: AppIconography.usage,
        working: _balanceLoading,
        onPressed: _baseUrl.text.trim().isEmpty || _balanceLoading
            ? null
            : _queryBalance,
      ),
      if (_balanceError != null) ...[
        _gap(context),
        KitNotice.error(
          key: const ValueKey('provider-balance-error'),
          message: '${l10n.providerBalanceFailed}: $_balanceError',
          retry: KitAction(label: l10n.commonRetry, onPressed: _queryBalance),
        ),
      ],
      if (_balanceReading != null) ...[
        _gap(context),
        KitRowGroup(
          margin: EdgeInsets.zero,
          children: [
            KitRow(
              key: const ValueKey('provider-balance-value'),
              title: l10n.providerBalanceValue,
              trailing: Text(
                _balanceReading!.value,
                style: KitText.styleOf(context, KitTextRole.body),
              ),
            ),
          ],
        ),
      ],
    ],
  ];

  // ---------------- Models ----------------

  List<Widget> _modelsTab(BuildContext context, AppLocalizations l10n) {
    final filtered = _query.trim().isEmpty
        ? _listed
        : _listed
              .where(
                (model) =>
                    model.id.toLowerCase().contains(_query.toLowerCase()) ||
                    model.label.toLowerCase().contains(_query.toLowerCase()),
              )
              .toList();
    return [
      KitNotice(
        key: const ValueKey('custom-provider-models-hint'),
        icon: AppIconography.info,
        message: l10n.providerDetailModelsHint,
      ),
      if (_keyOnServer) ...[
        _gap(context),
        KitNotice(
          key: const ValueKey('custom-provider-models-key-server'),
          tone: AppStatusTone.attention,
          icon: AppIconography.warning,
          message: l10n.providerModelsKeyServer,
        ),
      ],
      _gap(context),
      KitButton.secondary(
        key: const ValueKey('custom-provider-fetch'),
        label: _fetching ? l10n.providerAddFetching : l10n.providerAddFetch,
        icon: AppIconography.retry,
        working: _fetching,
        onPressed: _fetching || _baseUrl.text.trim().isEmpty
            ? null
            : _fetchModels,
      ),
      if (_baseUrl.text.trim().isEmpty) ...[
        _gap(context),
        Text(
          l10n.providerModelsConfigFirst,
          style: KitText.styleOf(context, KitTextRole.caption),
        ),
      ],
      if (_fetchError != null) ...[
        _gap(context),
        KitNotice.error(
          key: const ValueKey('custom-provider-fetch-failed'),
          message: '${l10n.providerAddFetchFailed}: $_fetchError',
          retry: KitAction(label: l10n.commonRetry, onPressed: _fetchModels),
        ),
      ],
      if (_listed.isEmpty) ...[
        _gap(context),
        KitNotice(
          key: const ValueKey('custom-provider-models-empty'),
          icon: AppIconography.info,
          message: l10n.providerAddModelsEmpty,
        ),
      ] else ...[
        _gap(context),
        KitSearchField(
          label: l10n.providerAddSearch,
          controller: _search,
          fieldKey: const ValueKey('custom-provider-search'),
          clearKey: const ValueKey('custom-provider-search-clear'),
          onChanged: (value) => setState(() => _query = value),
        ),
        Padding(
          padding: EdgeInsets.symmetric(vertical: _space(context)),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${l10n.providerModelsSelected} ${_selected.length}'
                  ' / ${l10n.providerAddModelsFound(_listed.length)}',
                  style: KitText.styleOf(context, KitTextRole.caption),
                ),
              ),
              KitButton.tertiary(
                key: const ValueKey('custom-provider-select-all'),
                label: l10n.providerAddSelectAll,
                onPressed: () => setState(
                  () => _selected.addAll(filtered.map((model) => model.id)),
                ),
              ),
              KitButton.tertiary(
                key: const ValueKey('custom-provider-clear-all'),
                label: l10n.providerAddClearAll,
                onPressed: () => setState(_selected.clear),
              ),
            ],
          ),
        ),
        KitRowGroup(
          children: [
            // Capped for rendering only: Select all works on the filtered
            // list, not on this slice, so a gateway with hundreds of models
            // is still fully selectable without building hundreds of rows.
            for (final model in filtered.take(200))
              KitRow(
                key: ValueKey('custom-provider-model-${model.id}'),
                title: model.label,
                supporting: model.label == model.id
                    ? null
                    : TextSpan(text: model.id),
                selected: _selected.contains(model.id),
                onTap: () => _toggle(model.id, !_selected.contains(model.id)),
                trailing: Icon(
                  _selected.contains(model.id)
                      ? AppIconography.checkboxChecked
                      : AppIconography.checkboxEmpty,
                  size: 20,
                  color: _selected.contains(model.id)
                      ? KitTokens.of(context).accent
                      : KitTokens.of(context).muted,
                ),
              ),
          ],
        ),
      ],
      _gap(context),
      KitField(
        label: l10n.providerAddModelHint,
        controller: _manualModel,
        kind: KitFieldKind.mono,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _addManualModel(),
        action: KitAction(
          label: l10n.providerModelsAdd,
          icon: AppIconography.add,
          onPressed: _addManualModel,
        ),
        fieldKey: const ValueKey('custom-provider-manual-model'),
      ),
    ];
  }

  // ---------------- Advanced ----------------

  List<Widget> _advancedTab(BuildContext context, AppLocalizations l10n) => [
    KitSectionLabel(l10n.providerHeadersSection),
    Text(
      l10n.providerHeadersHint,
      style: KitText.styleOf(context, KitTextRole.caption),
    ),
    if (_headers.isEmpty) ...[
      _gap(context),
      KitNotice(
        key: const ValueKey('custom-provider-headers-empty'),
        icon: AppIconography.info,
        message: l10n.providerHeadersEmpty,
      ),
    ],
    for (final row in _headers) ...[
      _gap(context),
      KitField(
        key: ValueKey('custom-provider-header-name-${_headers.indexOf(row)}'),
        label: l10n.providerHeadersName,
        controller: row.name,
        kind: KitFieldKind.mono,
        hint: 'HTTP-Referer',
        action: KitAction(
          label: l10n.providerHeadersPresets,
          icon: AppIconography.chevronDown,
          onPressed: () => _pickHeaderPreset(row),
        ),
      ),
      _gap(context),
      KitField(
        key: ValueKey('custom-provider-header-value-${_headers.indexOf(row)}'),
        label: l10n.providerHeadersValue,
        controller: row.value,
        kind: KitFieldKind.mono,
        action: KitAction(
          label: l10n.providerManageDelete,
          icon: AppIconography.delete,
          destructive: true,
          onPressed: () => _removeHeader(row),
        ),
      ),
    ],
    _gap(context),
    KitButton.secondary(
      key: const ValueKey('custom-provider-header-add'),
      label: l10n.providerHeadersAdd,
      icon: AppIconography.add,
      onPressed: _addHeader,
    ),
    KitSectionLabel(l10n.providerEditTest, gapBefore: _space(context) * 2),
    KitButton.secondary(
      key: const ValueKey('custom-provider-test'),
      label: l10n.providerEditTest,
      icon: AppIconography.play,
      onPressed: _selected.isEmpty ? null : _testNow,
    ),
    if ((_previewText ?? '').isNotEmpty) ...[
      KitSectionLabel(l10n.providerAddPreview, gapBefore: _space(context) * 2),
      KitCodeBlock(
        key: const ValueKey('custom-provider-preview'),
        text: _previewText!,
        language: 'json',
        maxLines: 18,
      ),
    ],
  ];

  Widget _savedScreen(BuildContext context, AppLocalizations l10n) {
    final receipt = _receipt!;
    return KitScreen(
      width: KitScreenWidth.list,
      topBar: KitTopBar(title: l10n.providerAddTitle),
      body: ListView(
        padding: KitScreen.padding(context),
        children: [
          KitStateView(
            key: const ValueKey('custom-provider-saved'),
            size: KitStateSize.page,
            icon: AppIconography.checkCircle,
            title: _editing
                ? l10n.providerEditSaved(_name.text.trim())
                : l10n.providerAddSaved(_name.text.trim(), receipt.configPath),
            body: _reloaded
                ? l10n.providerAddRestarted
                : l10n.providerAddRestartHint,
            tertiary: [
              if (_selected.isNotEmpty)
                KitAction(
                  label: l10n.providerProbeOpen,
                  icon: AppIconography.play,
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ProviderProbeScreen(
                        providerName: _name.text.trim().isEmpty
                            ? _id.text.trim()
                            : _name.text.trim(),
                        model: _selected.first,
                        models: _selected.toList(),
                        baseUrl: _baseUrl.text.trim(),
                        protocol: _protocol,
                        resolveKey: _resolveKey,
                        headers: _headerMap(),
                      ),
                    ),
                  ),
                ),
              KitAction(
                label: l10n.providerAddDone,
                onPressed: () => Navigator.of(context).maybePop(true),
              ),
            ],
          ),
        ],
      ),
    );
  }

  double _space(BuildContext context) => KitTokens.of(context).space3;

  Widget _gap(BuildContext context) => SizedBox(height: _space(context));

  static bool _isOfficialOpenAIHost(String baseUrl) {
    final uri = Uri.tryParse(baseUrl.trim());
    return uri?.host.toLowerCase() == 'api.openai.com';
  }
}

/// One editable custom header row: its two controllers, disposed with it.
class _HeaderRow {
  _HeaderRow({String name = '', String value = ''})
    : name = TextEditingController(text: name),
      value = TextEditingController(text: value);

  final TextEditingController name;
  final TextEditingController value;

  void dispose() {
    name.dispose();
    value.dispose();
  }
}
