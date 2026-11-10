import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api2/server_config_reload.dart';
import '../../builtin/builtin_linux.dart';
import '../../builtin/builtin_provider_store.dart';
import '../../builtin/builtin_provider_templates.dart';
import '../../builtin/builtin_server.dart' show looksLikeInAppServer;
import '../../builtin/provider_server_models.dart';
import '../../builtin/provider_server_scripts.dart';
import '../../domain/custom_provider.dart';
import '../../domain/custom_provider_record.dart';
import '../../domain/provider_balance.dart';
import '../../domain/provider_model_source.dart';
import '../../domain/provider_tls.dart';
import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import 'provider_test_screen.dart';
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
  late final ProviderServerModelSource _models = ProviderServerModelSource(
    linux: _linux,
    userAgent: ProviderServerScripts.userAgent(
      widget.controller.installedServerVersion ??
          widget.controller.profile?.serverVersion,
    ),
  );
  final ProviderBalanceClient _balanceClient = ProviderBalanceClient();

  ProviderProtocol _protocol = ProviderProtocol.chatCompletions;

  /// Where the key goes. The server reads the model list and sends the test
  /// itself, so the key has to be somewhere the server can read: in the
  /// config, which only the server's own account can open. `secretFile` is
  /// kept for entries written that way before this rule.
  late final ProviderKeyMode _keyMode =
      widget.editing?.keyMode ?? ProviderKeyMode.plaintext;

  /// True once this entry is in the config, whichever action put it there.
  /// The write before a model read happens on a new provider, and from then
  /// on saving is an edit of an entry that already exists.
  bool _existsOnServer = false;

  /// The key this form wrote into the config. A new provider has no
  /// [widget.editing] to read it back from, so a save that follows a write
  /// keeps it here instead of writing an entry without one.
  String? _savedKey;

  ResolvedProviderConfig? _resolved;
  List<CustomProviderModel> _listed = const [];
  final Set<String> _selected = {};

  /// The context window each model was given, by model id.
  ///
  /// Kept beside the list rather than inside it because it survives a re-read:
  /// fetching again must not throw away a number the person typed. Zero means
  /// "not stated" — nothing is written, and the server falls back to its own
  /// 200K assumption, which is what this map exists to avoid.
  final Map<String, int> _contexts = {};
  String _query = '';
  bool _fetching = false;
  String? _fetchError;

  /// Set while a transient failure is being retried: which attempt is next and
  /// how long the wait is. Without it the button just looks stuck.
  String? _fetchNote;

  /// Where the last successful read came from, and how many models it named.
  String? _fetchInfo;

  /// Set when the base URL was rewritten to the root the model list actually
  /// answered on, so the form can say so instead of changing a field quietly.
  String? _adoptedRoot;

  /// Every request the last read made: `host/path · status`.
  List<String> _fetchTrace = const [];

  bool _saving = false;
  String? _saveError;
  ProviderWriteReceipt? _receipt;

  /// The last write, whether it came from Save, the model read or the test.
  /// Only Save turns it into [_receipt] (the "written to …" screen).
  ProviderWriteReceipt? _lastReceipt;
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
    if (_savedKey != null) return true;
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
      _listed = [
        ...editing.models,
        // The ones the entry turned off stay in the list, unticked: they are
        // what a save has to keep off, and hiding them would make the list
        // look like the provider only ever had the ticked few.
        for (final id in editing.disabledModels) CustomProviderModel(id: id),
      ];
      _selected.addAll(editing.models.map((model) => model.id));
      for (final model in editing.models) {
        if (model.contextLimit > 0) _contexts[model.id] = model.contextLimit;
      }
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
    final id = CustomProviderDraft.normalizeProviderId(
      _id.text.isEmpty ? _name.text : _id.text,
    );
    // A key typed here is written into the config: the server is the one that
    // has to read it, for the model list and for every real request.
    final keyMode = typedKey.isNotEmpty ? ProviderKeyMode.plaintext : _keyMode;
    // What the server currently serves for this id, plus whatever this form
    // has listed. The ticked set alone is not enough: a provider saved
    // before this rule existed has two entries in its config and eighty
    // models on the server, so the other seventy-eight are only known from
    // the catalogue.
    final known = <String>{
      for (final model in _listed) model.id,
      for (final model in widget.controller.catalog?.models ?? const [])
        if (model.providerID == id) model.id,
    };
    return CustomProviderDraft(
      name: _name.text,
      id: id,
      protocol: _protocol,
      baseUrl: _baseUrl.text,
      apiKey: typedKey.isNotEmpty
          ? typedKey
          : keyMode == ProviderKeyMode.plaintext
          ? editing?.apiKey ?? _savedKey
          : null,
      keyMode: keyMode,
      keyPlaceholder: editing?.keyPlaceholder,
      keyFile: editing?.secretPath,
      models: [
        for (final modelID in _selected)
          _withWindow(
            _listed.firstWhere(
              (model) => model.id == modelID,
              orElse: () => CustomProviderModel(id: modelID),
            ),
          ),
      ],
      // Everything the server knows and the person did not tick. The config
      // merges onto the server's own catalogue, so leaving these out of the
      // entry would leave them enabled on the server — the "I saved two
      // models and still see eighty" that made this form look broken.
      disabledModelIDs: [
        for (final modelID in known)
          if (!_selected.contains(modelID)) modelID,
      ],
      headers: [
        for (final row in _headers)
          CustomProviderHeader(name: row.name.text, value: row.value.text),
      ],
    );
  }

  /// Headers for the app's own requests (model list, probes, balance). The
  /// sanitised map, not the raw one: a value this platform cannot send must
  /// not turn every call into a format error.
  Map<String, String> _headerMap() => _draft().requestHeaderMap;

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

  /// Reads the endpoint's model list — from the server, with the entry this
  /// form just wrote.
  ///
  /// The order is the whole point. The server asks the endpoint with the
  /// address, key and headers in its own config and with its own identity, so
  /// the entry is written and reloaded first; the phone never opens a
  /// connection to a provider. An entry with no models is a valid config, so
  /// the ticked list is written afterwards by Save.
  Future<void> _fetchModels() async {
    if (_fetching || _saving) return;
    final l10n = _l10nOf(context);
    if (_baseUrl.text.trim().isEmpty) {
      setState(() => _fetchError = l10n.providerModelsConfigFirst);
      return;
    }
    if (!_writable) {
      setState(() => _fetchError = l10n.providerAddCopyOnly);
      return;
    }
    setState(() {
      _fetching = true;
      _fetchError = null;
      _fetchInfo = null;
      _fetchNote = null;
      _adoptedRoot = null;
      _fetchTrace = const [];
    });
    final resolved = _resolved;
    if (!await _writeConfig(requireModels: false)) {
      if (!mounted) return;
      setState(() {
        _fetching = false;
        _fetchError = _saveError;
      });
      return;
    }
    final written = _resolved ?? resolved;
    try {
      if (written == null) {
        throw const ProviderModelFetchFailure(
          'The server\u2019s configuration could not be found',
          kind: ProviderModelFetchKind.serverUnavailable,
        );
      }
      final listing = await readProviderModelsWithRetry(
        () => _models.fetch(
          configPath: _store.pathOf(written),
          providerID: _draft().id,
          baseUrl: CustomProviderDraft.normalizeBaseUrl(_baseUrl.text, _protocol),
          protocol: _protocol,
          onTrace: (trace) {
            if (!mounted) return;
            setState(() => _fetchTrace = trace);
          },
        ),
        onRetry: (attempt, pause) {
          if (!mounted) return;
          setState(() {
            _fetchNote = l10n.providerModelsRetrying(attempt, pause.inSeconds);
          });
        },
      );
      if (!mounted) return;
      final adopted = _adoptListedRoot(listing.url);
      setState(() {
        _listed = listing.models;
        // What the endpoint says its models hold, for the ones the person has
        // not given a number of their own. A gateway that states it saves
        // typing; one that does not leaves the field empty on purpose.
        for (final model in listing.models) {
          if ((_contexts[model.id] ?? 0) <= 0 && model.contextLimit > 0) {
            _contexts[model.id] = model.contextLimit;
          }
        }
        _fetching = false;
        _fetchNote = null;
        _adoptedRoot = adopted;
        _fetchInfo = _l10nOf(
          context,
        ).providerModelsFrom(listing.url.toString(), listing.models.length);
        // A first fetch selects everything: the common case is "all of this
        // gateway", and unticking a few is less work than ticking many.
        if (_selected.isEmpty) {
          _selected.addAll(listing.models.map((model) => model.id));
        }
      });
    } on ProviderModelFetchFailure catch (error) {
      if (!mounted) return;
      setState(() {
        _fetchError = _describeFailure(error);
        _fetchTrace = error.trace;
        _fetchNote = null;
        _fetching = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _fetchError = '$error';
        _fetchNote = null;
        _fetching = false;
      });
    }
  }

  /// The failure in the form's language, not the domain's English fallback.
  String _describeFailure(ProviderModelFetchFailure error) {
    final l10n = _l10nOf(context);
    final status = error.statusCode ?? 0;
    return switch (error.kind) {
      ProviderModelFetchKind.badUrl => l10n.providerModelsFetchBadUrl,
      ProviderModelFetchKind.missingKey => l10n.providerModelsFetchNoKey,
      ProviderModelFetchKind.refusedKey => l10n.providerModelsFetchRefused(
        status,
      ),
      ProviderModelFetchKind.notFound => l10n.providerModelsFetchNotFound(
        error.path ?? '',
      ),
      ProviderModelFetchKind.notJson => l10n.providerModelsFetchNotJson,
      ProviderModelFetchKind.emptyList => l10n.providerModelsFetchEmpty,
      ProviderModelFetchKind.timeout => l10n.providerModelsFetchTimeout,
      ProviderModelFetchKind.network => l10n.providerModelsFetchNetwork,
      ProviderModelFetchKind.tls => [
        l10n.providerModelsFetchTls,
        if (error.trustWasPinned) l10n.providerTlsChanged,
        _tlsReason(l10n, error.tlsProblem),
      ].join(' '),
      ProviderModelFetchKind.serverError => l10n.providerModelsFetchServer(
        status,
      ),
      ProviderModelFetchKind.serverUnavailable =>
        l10n.providerModelsFetchServerDown(error.message),
      ProviderModelFetchKind.notConfigured =>
        l10n.providerModelsFetchNotConfigured,
      ProviderModelFetchKind.unknown => error.message,
    };
  }

  String _tlsReason(AppLocalizations l10n, ProviderTlsProblem? problem) =>
      switch (problem) {
        ProviderTlsProblem.selfSigned => l10n.providerTlsSelfSigned,
        ProviderTlsProblem.unknownIssuer => l10n.providerTlsUnknownIssuer,
        ProviderTlsProblem.expired => l10n.providerTlsExpired,
        ProviderTlsProblem.notYetValid => l10n.providerTlsNotYetValid,
        ProviderTlsProblem.hostnameMismatch => l10n.providerTlsHostname,
        ProviderTlsProblem.other || null => l10n.providerTlsOther,
      };

  /// The fingerprint this address was trusted with, if any.
  String? _trustedFingerprintFor(String baseUrl) =>
      widget.controller.providerTrustFor(providerOrigin(baseUrl));

  /// A stored fingerprint in the same readable grouping the trust sheet uses.
  String _displayFingerprint(String fingerprint) => RegExp(r'.{2}')
      .allMatches(fingerprint.toUpperCase())
      .map((match) => match.group(0))
      .join(':');

  Future<void> _revokeTrust() async {
    final base = CustomProviderDraft.normalizeBaseUrl(_baseUrl.text, _protocol);
    await widget.controller.setProviderTrust(providerOrigin(base), null);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(_l10nOf(context).providerTlsRevoked)),
    );
  }

  /// The models tab is where a list belongs, so the action on the
  /// configuration tab only opens it and starts the read: the same request,
  /// in the place a person looks first.
  void _fetchFromConfigTab() {
    setState(() {
      _tab = _Tab.models;
      _visited.add(_Tab.models);
    });
    unawaited(_fetchModels());
  }

  /// The base URL the model list proved is the right one. The chat request
  /// appends to this field, so the address a list answered on is the address
  /// to send messages to.
  String? _adoptListedRoot(Uri listed) {
    final adopted = CustomProviderDraft.adoptModelRoot(
      _baseUrl.text,
      listed,
      _protocol,
    );
    if (adopted != null) _baseUrl.text = adopted;
    return adopted;
  }

  /// Writes this form into the server's config and reloads it once.
  ///
  /// Returns false with [_saveError] set. Save, the model read and the test
  /// all start here: the server is what reads models and sends messages, so
  /// the entry has to be on disk — with the key in it — before any of them
  /// can run. Nothing in this flow falls back to a request from the phone.
  Future<bool> _writeConfig({required bool requireModels}) async {
    if (_saving) return false;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final draft = _draft();
      draft.validate(requireModels: requireModels);
      final resolved = _resolved ?? await _store.resolve();
      final receipt = await _store.save(
        draft,
        resolved: resolved,
        // The write before a model read puts a new entry on disk, so every
        // later save is an edit of an entry that already exists.
        replace: _editing || _existsOnServer,
        requireModels: requireModels,
      );
      final reloaded = await _tryReload();
      if (!mounted) return false;
      setState(() {
        _resolved = resolved;
        _existsOnServer = true;
        if (draft.hasKey) _savedKey = draft.apiKey;
        _lastReceipt = receipt;
        _reloaded = reloaded;
        _saving = false;
      });
      return true;
    } catch (error) {
      if (!mounted) return false;
      setState(() {
        _saveError = error is ProviderWriteRefused
            ? _refusedMessage(error)
            : _messageFor(error);
        _saving = false;
      });
      // A refusal may mean the file changed outside the app: re-read it so
      // the next attempt merges into what is actually there.
      if (error is ProviderWriteRefused) _prepare();
      return false;
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!await _writeConfig(requireModels: true)) return;
    final draft = _draft();
    try {
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
      // The same ticks, for this phone's picker: the config entry is what the
      // server reads, this is what the app reads. Saving them together means
      // an entry the server never picks up still changes which models the
      // picker offers.
      await widget.controller.setModelsEnabled(
        draft.id,
        enabled: [for (final model in draft.models) model.id],
        disabled: draft.effectiveDisabledModelIDs,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _saveError = _messageFor(error));
    }
    if (!mounted) return;
    // The reload re-reads the config, but the catalogue the app shows is its
    // own snapshot: without this the picker keeps the pre-save list until it
    // goes stale, which reads as "the change did nothing".
    if (_reloaded) unawaited(widget.controller.refreshCatalog());
    setState(() => _receipt = _lastReceipt);
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
    // The server's own trust rules, not a bare client: a remote server with a
    // certificate the person verified would otherwise fail here and turn a
    // working reload into "restart the server".
    return reloadServerConfig(
      baseUrl: profile.baseUrl,
      password: profile.password,
      username: profile.username.isEmpty ? 'opencode' : profile.username,
      cleartextConfirmedOrigin: profile.cleartextConfirmedOrigin,
      certificatePinSha256: profile.certificatePinSha256,
    );
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

  /// The windows worth one tap. Anything larger, or odd, goes through the
  /// dialog on the row.
  static const _contextPresets = <int>[
    128000,
    200000,
    256000,
    400000,
    1000000,
  ];

  /// `200000` as people say it: `200K`, `1M`. Zero is the server's own
  /// assumption, spelled out rather than left blank.
  String _windowLabel(AppLocalizations l10n, int tokens) {
    if (tokens <= 0) return l10n.providerModelsContextUnset;
    if (tokens % 1000000 == 0) return '${tokens ~/ 1000000}M';
    if (tokens % 1000 == 0) return '${tokens ~/ 1000}K';
    return '$tokens';
  }

  /// The model as it will be saved: with the window this form gave it, or the
  /// one the endpoint stated, or none at all.
  CustomProviderModel _withWindow(CustomProviderModel model) {
    final window = _contexts[model.id] ?? model.contextLimit;
    return window > 0 ? model.withContext(window) : model;
  }

  /// The window to show on a row: what this form set, else what the endpoint
  /// stated, else nothing.
  int _windowOf(CustomProviderModel model) =>
      _contexts[model.id] ?? model.contextLimit;

  void _setWindow(String modelID, int window) {
    setState(() {
      if (window > 0) {
        _contexts[modelID] = window;
      } else {
        _contexts.remove(modelID);
      }
    });
  }

  /// One number for every ticked model: the quick way out of "all of them say
  /// 200K".
  void _setWindowForSelected(int window) {
    setState(() {
      for (final id in _selected) {
        if (window > 0) {
          _contexts[id] = window;
        } else {
          _contexts.remove(id);
        }
      }
    });
  }

  Future<void> _editWindow(CustomProviderModel model) async {
    final l10n = _l10nOf(context);
    final current = _windowOf(model);
    final typed = await showKitInputDialog(
      context,
      title: l10n.providerModelsContextTitle,
      label: l10n.providerModelsContextField,
      hint: l10n.providerModelsContextFieldHint,
      helper: l10n.providerModelsContextHelper,
      confirmLabel: l10n.commonSave,
      initial: current > 0 ? '$current' : '',
      kind: KitFieldKind.number,
      maxLength: 9,
      dialogKey: const ValueKey('custom-provider-window-dialog'),
      fieldKey: const ValueKey('custom-provider-window-field'),
      confirmKey: const ValueKey('custom-provider-window-confirm'),
      validate: (value) {
        final window = int.tryParse(value.trim().replaceAll(',', '')) ?? 0;
        if (window <= 0) return null; // empty or 0 clears it
        if (window < 1024) return l10n.providerModelsContextTooSmall;
        if (window > 20000000) return l10n.providerModelsContextTooLarge;
        return null;
      },
    );
    if (typed == null || !mounted) return;
    _setWindow(model.id, int.tryParse(typed.trim().replaceAll(',', '')) ?? 0);
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
      final base = CustomProviderDraft.normalizeBaseUrl(
        _baseUrl.text,
        _protocol,
      );
      final reading = await _balanceClient.fetch(
        balance: ProviderBalance(
          enabled: true,
          url: _balanceUrl.text,
          resultPath: _balancePath.text,
        ),
        baseUrl: base,
        apiKey: key,
        headers: _headerMap(),
        trustedFingerprint: _trustedFingerprintFor(base),
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

  /// Opens the real test: the server opens a session with this model, sends
  /// one message and deletes the session again.
  ///
  /// The entry is written first, for the same reason the model read is: the
  /// server can only test what its config holds.
  Future<void> _testNow() async {
    final models = _selected.toList();
    if (models.isEmpty || _saving) return;
    final l10n = _l10nOf(context);
    if (!_writable) {
      setState(() => _saveError = l10n.providerProbeServerOnly);
      return;
    }
    if (!await _writeConfig(requireModels: true)) return;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProviderTestScreen(
          controller: widget.controller,
          providerID: _draft().id,
          providerName: _name.text.trim().isEmpty
              ? _id.text.trim()
              : _name.text.trim(),
          models: models,
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
        onChanged: (value) {
          setState(() {
            _tab = value;
            _visited.add(value);
          });
        },
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
    Padding(
      padding: EdgeInsetsDirectional.only(top: _space(context) / 2),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: KitButton.tertiary(
          key: const ValueKey('custom-provider-fetch-from-config'),
          label: _fetching ? l10n.providerAddFetching : l10n.providerAddFetch,
          icon: AppIconography.retry,
          onPressed: _fetching || _baseUrl.text.trim().isEmpty
              ? null
              : _fetchFromConfigTab,
        ),
      ),
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

  List<Widget> _balanceSection(BuildContext context, AppLocalizations l10n) => [
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
        onPressed: _fetching || _baseUrl.text.trim().isEmpty || !_writable
            ? null
            : _fetchModels,
      ),
      if (!_existsOnServer && _baseUrl.text.trim().isNotEmpty) ...[
        SizedBox(height: _space(context) / 2),
        Text(
          l10n.providerAddNeedSave,
          key: const ValueKey('custom-provider-fetch-saves'),
          style: KitText.styleOf(context, KitTextRole.caption),
        ),
      ],
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
        if (_listed.isNotEmpty) ...[
          SizedBox(height: _space(context) / 2),
          Text(
            l10n.providerModelsKeptPrevious(_listed.length),
            key: const ValueKey('custom-provider-fetch-kept'),
            style: KitText.styleOf(context, KitTextRole.caption),
          ),
        ],
        if (_fetchTrace.isNotEmpty) ...[
          SizedBox(height: _space(context) / 2),
          _traceLines(context, l10n, _fetchTrace),
        ],
      ],
      if (_fetching && _fetchNote != null) ...[
        _gap(context),
        Text(
          _fetchNote!,
          key: const ValueKey('custom-provider-fetch-retry'),
          style: KitText.styleOf(context, KitTextRole.caption),
        ),
      ],
      if (_fetchInfo != null) ...[
        _gap(context),
        KitNotice(
          key: const ValueKey('custom-provider-fetch-ok'),
          tone: AppStatusTone.ok,
          icon: AppIconography.check,
          message: _fetchInfo!,
        ),
      ],
      if (_adoptedRoot != null) ...[
        SizedBox(height: _space(context) / 2),
        KitNotice(
          key: const ValueKey('custom-provider-root-adopted'),
          icon: AppIconography.info,
          message: l10n.providerModelsRootAdopted(_adoptedRoot!),
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
        // One number for every ticked model, then per-row editing below: the
        // common case is "all of this gateway holds a million", the exception
        // is one small model among them.
        Padding(
          padding: EdgeInsets.only(bottom: _space(context)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.providerModelsContextTitle,
                style: KitText.styleOf(context, KitTextRole.caption),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final window in _contextPresets)
                    KitButton.tertiary(
                      key: ValueKey('custom-provider-window-all-$window'),
                      label: _windowLabel(l10n, window),
                      onPressed: _selected.isEmpty
                          ? null
                          : () => _setWindowForSelected(window),
                    ),
                  KitButton.tertiary(
                    key: const ValueKey('custom-provider-window-all-default'),
                    label: l10n.providerModelsContextUnset,
                    onPressed: _selected.isEmpty
                        ? null
                        : () => _setWindowForSelected(0),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                l10n.providerModelsContextHelper,
                style: KitText.styleOf(context, KitTextRole.caption),
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
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The window is per model, so it is edited on the row: a
                    // gateway serves a 32K model beside a 1M one, and one
                    // number for all of them is the bug this replaces.
                    GestureDetector(
                      key: ValueKey('custom-provider-window-${model.id}'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _editWindow(model),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          _windowLabel(l10n, _windowOf(model)),
                          style: KitText.styleOf(context, KitTextRole.caption)
                              .copyWith(
                                color: _windowOf(model) > 0
                                    ? null
                                    : KitTokens.of(context).muted,
                              ),
                        ),
                      ),
                    ),
                    Icon(
                      _selected.contains(model.id)
                          ? AppIconography.checkboxChecked
                          : AppIconography.checkboxEmpty,
                      size: 20,
                      color: _selected.contains(model.id)
                          ? KitTokens.of(context).accent
                          : KitTokens.of(context).muted,
                    ),
                  ],
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

  List<Widget> _advancedTab(BuildContext context, AppLocalizations l10n) {
    final trusted = _trustedFingerprintFor(
      CustomProviderDraft.normalizeBaseUrl(_baseUrl.text, _protocol),
    );
    return [
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
          key: ValueKey(
            'custom-provider-header-value-${_headers.indexOf(row)}',
          ),
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
      KitSectionLabel(l10n.providerTlsSection, gapBefore: _space(context) * 2),
      if (trusted != null)
        KitRow(
          key: const ValueKey('custom-provider-trust'),
          title: l10n.providerTlsTrusted,
          supporting: TextSpan(
            text:
                '${l10n.providerTlsTrustedBody} ${_displayFingerprint(trusted)}',
          ),
          supportingMaxLines: 3,
          action: KitAction(
            key: const ValueKey('custom-provider-trust-revoke'),
            label: l10n.providerTlsRevoke,
            destructive: true,
            onPressed: _revokeTrust,
          ),
        )
      else
        Text(
          l10n.providerTlsNotTrusted,
          style: KitText.styleOf(context, KitTextRole.caption),
        ),
      KitSectionLabel(l10n.providerEditTest, gapBefore: _space(context) * 2),
      KitButton.secondary(
        key: const ValueKey('custom-provider-test'),
        label: l10n.providerEditTest,
        icon: AppIconography.play,
        onPressed: _selected.isEmpty ? null : _testNow,
      ),
      if ((_previewText ?? '').isNotEmpty) ...[
        KitSectionLabel(
          l10n.providerAddPreview,
          gapBefore: _space(context) * 2,
        ),
        KitCodeBlock(
          key: const ValueKey('custom-provider-preview'),
          text: _previewText!,
          language: 'json',
          maxLines: 18,
        ),
      ],
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
                      builder: (_) => ProviderTestScreen(
                        controller: widget.controller,
                        providerID: _draft().id,
                        providerName: _name.text.trim().isEmpty
                            ? _id.text.trim()
                            : _name.text.trim(),
                        models: _selected.toList(),
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

  /// What the read asked and what came back, one line per request. Shown
  /// only when it failed: "401" on its own leaves a person guessing which
  /// address was even tried.
  Widget _traceLines(
    BuildContext context,
    AppLocalizations l10n,
    List<String> trace,
  ) {
    final shown = trace.length > 6 ? trace.sublist(trace.length - 6) : trace;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.providerModelsAttempts,
          style: KitText.styleOf(context, KitTextRole.caption),
        ),
        for (final line in shown)
          Padding(
            padding: EdgeInsetsDirectional.only(top: 2),
            child: Text(
              line,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: KitText.styleOf(context, KitTextRole.mono),
            ),
          ),
      ],
    );
  }

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
