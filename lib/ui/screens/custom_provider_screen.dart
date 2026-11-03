import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../builtin/builtin_linux.dart';
import '../../builtin/builtin_provider_store.dart';
import '../../builtin/builtin_server.dart' show looksLikeInAppServer;
import '../../domain/custom_provider.dart';
import '../../domain/provider_model_source.dart';
import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import 'provider_probe_screen.dart';
import '../app_iconography.dart';
import '../app_theme.dart' show AppStatusTone;
import '../kit/kit.dart';

AppLocalizations _l10nOf(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

/// Declares a provider the server's own catalogue does not know.
///
/// OpenCode has no "add a provider" endpoint, so this screen does the two
/// things that are actually possible: it reads the model list from the
/// endpoint itself (a plain HTTPS call, and the part that saves the most time
/// — gateway model ids are rarely the ones in any document), and writes the
/// config into the in-app server's `opencode.json`, where the app can already
/// run shell.
///
/// On a server whose files the app cannot reach, the same form still works as
/// a generator: it produces the snippet to paste, and says why it cannot
/// write. Saying that plainly is better than a Save that silently does
/// nothing.
class CustomProviderScreen extends StatefulWidget {
  final ConnectionController controller;

  /// The in-app server bridge. Null means "make one" — instances are cheap.
  final BuiltinLinux? linux;

  const CustomProviderScreen({super.key, required this.controller, this.linux});

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

  late final BuiltinLinux _linux = widget.linux ?? BuiltinLinux();
  late final BuiltinProviderStore _store = BuiltinProviderStore(linux: _linux);
  late final ProviderModelSource _models = ProviderModelSource();

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

  /// True when this profile is the server the app itself runs, whose files
  /// this app may write.
  bool get _writable => looksLikeInAppServer(widget.controller.profile);

  ProviderConfigFormat get _format =>
      _resolved?.format ?? ProviderConfigFormat.v2;

  @override
  void initState() {
    super.initState();
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
    super.dispose();
  }

  CustomProviderDraft _draft() => CustomProviderDraft(
    name: _name.text,
    id: _id.text.isEmpty ? _name.text : _id.text,
    protocol: _protocol,
    baseUrl: _baseUrl.text,
    apiKey: _apiKey.text,
    models: [
      for (final id in _selected)
        _listed.firstWhere(
          (model) => model.id == id,
          orElse: () => CustomProviderModel(id: id),
        ),
    ],
  );

  /// The snippet to show and to copy. Null until the form says enough to
  /// produce one — a preview of half a provider teaches nothing.
  String? get _previewText {
    if (!_formReady) return null;
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
      final models = await _models.fetch(
        baseUrl: CustomProviderDraft.normalizeBaseUrl(_baseUrl.text, _protocol),
        protocol: _protocol,
        apiKey: _apiKey.text,
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
      final receipt = await _store.save(draft, resolved: resolved);
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

  @override
  Widget build(BuildContext context) {
    final l10n = _l10nOf(context);
    if (_receipt != null) return _savedScreen(context, l10n);
    final canSave = _writable && _formReady && !_saving;
    return KitScreen(
      width: KitScreenWidth.list,
      topBar: KitTopBar(
        title: l10n.providerAddTitle,
        subtitle: widget.controller.profile?.name,
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
          icon: AppIconography.check,
          working: _saving,
          disabledReason: !_writable
              ? l10n.providerAddCopyOnly
              : !_formReady
              ? l10n.providerAddNeedModels
              : null,
          onPressed: canSave ? _save : null,
        ),
        secondary: KitAction(
          label: l10n.providerAddCopy,
          icon: AppIconography.copy,
          onPressed: _previewText == null ? null : _copySnippet,
        ),
      ),
      body: ListView(
        key: const ValueKey('custom-provider-form'),
        padding: KitScreen.padding(context),
        children: [
          KitNotice(
            key: const ValueKey('custom-provider-intro'),
            icon: AppIconography.info,
            message: l10n.providerAddIntro,
          ),
          if (!_writable) ...[
            _gap(context),
            KitNotice(
              key: const ValueKey('custom-provider-copy-only'),
              tone: AppStatusTone.attention,
              icon: AppIconography.warning,
              message: l10n.providerAddCopyOnly,
            ),
          ],
          if (_resolveError != null) ...[
            _gap(context),
            KitNotice(
              key: const ValueKey('custom-provider-resolve-failed'),
              tone: AppStatusTone.failure,
              icon: AppIconography.warning,
              message: _resolveError!,
            ),
          ],
          ..._connectionSection(context, l10n),
          ..._modelsSection(context, l10n),
          ..._previewSection(context, l10n),
        ],
      ),
    );
  }

  List<Widget> _connectionSection(
    BuildContext context,
    AppLocalizations l10n,
  ) => [
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
    KitField(
      label: l10n.providerAddId,
      controller: _id,
      kind: KitFieldKind.mono,
      helper: l10n.providerAddIdHelper,
      onChanged: (_) {
        _autoID = false;
        setState(() {});
      },
      fieldKey: const ValueKey('custom-provider-id'),
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
      ],
      selected: _protocol,
      semanticsLabel: l10n.providerAddProtocol,
      onChanged: (value) => setState(() {
        _protocol = value;
        // A list fetched for one protocol still names models, but its
        // existence says nothing about the other endpoint shape.
        _fetchError = null;
      }),
    ),
    _gap(context),
    KitField(
      label: l10n.providerAddBaseUrl,
      controller: _baseUrl,
      kind: KitFieldKind.url,
      hint: 'https://api.example.com/v1',
      helper: l10n.providerAddBaseUrlHelper,
      textInputAction: TextInputAction.next,
      onChanged: (_) => setState(() {}),
      fieldKey: const ValueKey('custom-provider-base-url'),
    ),
    _gap(context),
    KitField.secret(
      label: l10n.providerAddApiKey,
      controller: _apiKey,
      helper: l10n.providerAddApiKeyHelper,
      textInputAction: TextInputAction.done,
      onChanged: (_) => setState(() {}),
      fieldKey: const ValueKey('custom-provider-api-key'),
    ),
  ];

  List<Widget> _modelsSection(BuildContext context, AppLocalizations l10n) {
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
      KitSectionLabel(l10n.providerAddModels, gapBefore: _space(context)),
      KitButton.secondary(
        key: const ValueKey('custom-provider-fetch'),
        label: _fetching ? l10n.providerAddFetching : l10n.providerAddFetch,
        icon: AppIconography.retry,
        working: _fetching,
        onPressed: _fetching || _baseUrl.text.trim().isEmpty
            ? null
            : _fetchModels,
      ),
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
                  l10n.providerAddModelsFound(_selected.length),
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
        fieldKey: const ValueKey('custom-provider-manual-model'),
      ),
    ];
  }

  List<Widget> _previewSection(BuildContext context, AppLocalizations l10n) {
    final text = _previewText;
    if (text == null) return const [];
    return [
      KitSectionLabel(l10n.providerAddPreview, gapBefore: _space(context)),
      KitCodeBlock(
        key: const ValueKey('custom-provider-preview'),
        text: text,
        language: 'json',
        maxLines: 18,
      ),
    ];
  }

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
            title: l10n.providerAddSaved(_name.text.trim(), receipt.configPath),
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
                        baseUrl: _baseUrl.text.trim(),
                        protocol: _protocol,
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

  Future<void> _copySnippet() async {
    final text = _previewText;
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(_l10nOf(context).providerAddCopy)));
  }

  double _space(BuildContext context) => KitTokens.of(context).space3;

  Widget _gap(BuildContext context) => SizedBox(height: _space(context));
}
