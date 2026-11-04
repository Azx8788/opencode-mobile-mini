/// A provider the person declares themselves, rather than one the server's
/// own catalogue knows.
///
/// This is config-file work, not API work: OpenCode has no "create a
/// provider" endpoint (its `PUT /mcp/{name}` sibling does not exist for
/// providers), so a custom provider is an entry in `opencode.json`. The
/// builders here are pure so the wording of a saved file can be tested
/// without a phone, a server or a network.
///
/// Three protocols cover the market. Every OpenAI-compatible gateway
/// (NewAPI, OneAPI and the sites built on them) speaks Chat Completions;
/// newer ones also expose `/v1/responses`; Anthropic's Messages API is its
/// own shape. OpenCode selects the wire format by npm package, so choosing a
/// protocol chooses a package — the endpoint and the model list stay the
/// person's business.
library;

import 'server_gateway/value_types_catalog.dart' show ProductException;

/// The wire format a provider speaks, and the package that implements it.
///
/// `npm` is the v1 (and still supported) package name. `package` is the v2
/// spelling: v2 distinguishes a JavaScript provider from a built-in one by
/// the `aisdk:` prefix, and a bare `@ai-sdk/...` name is read as a native
/// provider id — it fails only when the first message is sent (upstream
/// #44881), which is why the prefix is not optional here.
enum ProviderProtocol {
  chatCompletions(
    npm: '@ai-sdk/openai-compatible',
    package: 'aisdk:@ai-sdk/openai-compatible',
    endpointSuffixes: ['/chat/completions', '/completions'],
    defaultPath: '/v1',
  ),
  responses(
    npm: '@ai-sdk/openai',
    package: 'aisdk:@ai-sdk/openai',
    endpointSuffixes: ['/responses'],
    defaultPath: '/v1',
  ),
  anthropic(
    npm: '@ai-sdk/anthropic',
    package: 'aisdk:@ai-sdk/anthropic',
    endpointSuffixes: ['/messages'],
    defaultPath: '/v1',
  ),
  google(
    npm: '@ai-sdk/google',
    package: 'aisdk:@ai-sdk/google',
    endpointSuffixes: ['/models'],
    defaultPath: '/v1beta',
  );

  const ProviderProtocol({
    required this.npm,
    required this.package,
    required this.endpointSuffixes,
    required this.defaultPath,
  });

  final String npm;
  final String package;

  /// The path a base URL usually ends with for this protocol. Switching the
  /// protocol swaps `/v1` and `/v1beta` where a base URL already ends with
  /// one, so a gateway does not keep the previous protocol's root by
  /// accident. Any other path is left exactly as typed.
  final String defaultPath;

  /// What a saved provider's chat request appends to its base URL. Shown
  /// read-only: the config has no field for a custom path, so offering an
  /// editable one would be a switch that does nothing.
  String get chatPath => switch (this) {
    chatCompletions => '/chat/completions',
    responses => '/responses',
    anthropic => '/messages',
    google => '/models/{model}:generateContent',
  };

  /// Paths people copy from an endpoint's docs by mistake. Base URLs are
  /// kept otherwise intact: gateways legitimately end in `/v1`, `/v4`,
  /// `/openai` or nothing at all, so forcing `/v1` invents endpoints that
  /// do not answer (Venice, DeepSeek and Bailing differ on exactly this).
  final List<String> endpointSuffixes;
}

/// Where the API key lives once the provider is saved.
enum ProviderKeyMode {
  /// `{file:...}` — verified to work for a custom provider's `apiKey`, while
  /// `{env:...}` there is a known upstream failure (#19946) that answers
  /// Unauthorized. The file lives on the server, which the app creates.
  secretFile,

  /// The key written into the config itself. Only on explicit request: the
  /// config is readable by anything that can read the server's home.
  plaintext,

  /// No key in the config at all; the person stores it through the server's
  /// own sign-in flow (`/connect`, or `PUT /auth/{id}` on v1).
  external,
}

/// Which config dialect to write.
enum ProviderConfigFormat {
  /// `provider` / `npm` / `options` / `tool_call`.
  v1,

  /// `providers` / `package` / `settings` / `capabilities`.
  v2;

  static ProviderConfigFormat forOpenCode2(bool isOpenCode2) =>
      isOpenCode2 ? ProviderConfigFormat.v2 : ProviderConfigFormat.v1;
}

/// One extra HTTP header a provider needs and its protocol does not carry.
///
/// Common on gateways that gate access by origin (`HTTP-Referer`,
/// `X-Title`) or that fingerprint clients (`User-Agent`). Names are matched
/// case-insensitively, as HTTP does; a later header with the same name wins.
class CustomProviderHeader {
  const CustomProviderHeader({required this.name, required this.value});

  final String name;
  final String value;

  bool get isEmpty => name.trim().isEmpty || value.trim().isEmpty;

  /// The header as the config and the app's own requests want it, or null
  /// when a half-filled row should be ignored.
  MapEntry<String, String>? get entry =>
      isEmpty ? null : MapEntry(name.trim(), value.trim());

  @override
  bool operator ==(Object other) =>
      other is CustomProviderHeader &&
      other.name.trim().toLowerCase() == name.trim().toLowerCase() &&
      other.value.trim() == value.trim();

  @override
  int get hashCode => name.trim().toLowerCase().hashCode ^ value.hashCode;

  Map<String, String> toJson() => {'name': name, 'value': value};

  factory CustomProviderHeader.fromJson(Object? value) {
    if (value is! Map) {
      return const CustomProviderHeader(name: '', value: '');
    }
    final name = value['name'];
    final headerValue = value['value'];
    return CustomProviderHeader(
      name: name is String ? name : '',
      value: headerValue is String ? headerValue : '',
    );
  }
}

/// Header names worth offering: the ones gateways actually ask for. The
/// field still accepts any name — this is a shortcut, not a whitelist.
const providerHeaderPresets = <String>[
  'User-Agent',
  'HTTP-Referer',
  'X-Title',
  'Referer',
  'Origin',
];

/// Reads the header map a config entry holds, dropping entries that are not
/// `{name: value}` strings.
List<CustomProviderHeader> readProviderHeaders(Object? raw) {
  if (raw is! Map) return const [];
  final headers = <CustomProviderHeader>[];
  for (final entry in raw.entries) {
    final name = '${entry.key}'.trim();
    final value = entry.value;
    if (name.isEmpty || value is! String || value.trim().isEmpty) continue;
    headers.add(CustomProviderHeader(name: name, value: value.trim()));
  }
  return List.unmodifiable(headers);
}

/// One model the endpoint listed.
class CustomProviderModel {
  const CustomProviderModel({required this.id, this.name});

  final String id;

  /// The endpoint's display name, when it sent one (`display_name` on
  /// Anthropic-shaped lists, `name` on some gateways).
  final String? name;

  String get label => (name?.trim().isNotEmpty ?? false) ? name!.trim() : id;

  @override
  bool operator ==(Object other) =>
      other is CustomProviderModel && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Everything the add-provider form collects, in the form it is saved.
class CustomProviderDraft {
  CustomProviderDraft({
    required this.name,
    required String id,
    required this.protocol,
    required String baseUrl,
    this.apiKey,
    this.keyMode = ProviderKeyMode.secretFile,
    List<CustomProviderModel> models = const [],
    List<CustomProviderHeader> headers = const [],
    this.timeoutMs = 600000,
    String? keyFile,
    this.keyPlaceholder,
  }) : id = normalizeProviderId(id),
       baseUrl = normalizeBaseUrl(baseUrl, protocol),
       models = normalizeModels(models),
       headers = normalizeHeaders(headers),
       _keyFile = keyFile;

  final String name;
  final String id;
  final ProviderProtocol protocol;
  final String baseUrl;
  final String? apiKey;
  final ProviderKeyMode keyMode;
  final List<CustomProviderModel> models;
  final List<CustomProviderHeader> headers;
  final int timeoutMs;

  /// Where an existing entry keeps its key. Null for a new provider, which
  /// uses the standard location. An entry read back from the config may
  /// point anywhere, and moving it on edit would leave the key behind.
  final String? _keyFile;

  /// The original `{env:…}`-style reference an entry used instead of a key
  /// of its own. Kept so editing an entry does not silently drop it.
  final String? keyPlaceholder;

  /// The server-side path holding the key, or null when the key is not a
  /// file. `/root` because the in-app server runs as root; `{file:}` needs an
  /// absolute path so no shell ever has to expand `~`.
  String? get secretPath => keyMode == ProviderKeyMode.secretFile
      ? (_keyFile ?? '/root/.secrets/$id.key')
      : null;

  /// True when this draft carries a key to write. An edit that leaves the
  /// key box empty keeps the file the config already points at.
  bool get hasKey => apiKey?.trim().isNotEmpty ?? false;

  /// The provider id as a file name would hold it: lowercase, no spaces and
  /// nothing a config key or a shell path would need quoted.
  static String normalizeProviderId(String raw) {
    final slug = raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll(RegExp(r'[^a-z0-9._-]'), '')
        .replaceAll(RegExp(r'^[-.]+'), '')
        .replaceAll(RegExp(r'[-.]+$'), '');
    return slug.isEmpty
        ? 'custom'
        : slug.length > 48
        ? slug.substring(0, 48)
        : slug;
  }

  /// A base URL the way a provider's `baseURL` wants it.
  ///
  /// Only the copy-pasted endpoint suffix is removed. A trailing slash is
  /// dropped, a missing scheme becomes `https://`, and the path is otherwise
  /// left alone — the point is to accept what the endpoint's docs print, not
  /// to guess a canonical form.
  static String normalizeBaseUrl(String raw, ProviderProtocol protocol) {
    var value = raw.trim();
    if (value.isEmpty) return '';
    if (!value.contains('://')) value = 'https://$value';
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasAuthority) return value;
    var path = uri.path;
    while (path.endsWith('/') && path.length > 1) {
      path = path.substring(0, path.length - 1);
    }
    for (final suffix in protocol.endpointSuffixes) {
      if (path.toLowerCase().endsWith(suffix)) {
        path = path.substring(0, path.length - suffix.length);
        break;
      }
    }
    while (path.endsWith('/') && path.length > 1) {
      path = path.substring(0, path.length - 1);
    }
    // Rebuilt rather than `uri.replace`: an empty query there renders as a
    // trailing `?#`, and `baseURL` is compared against endpoint docs verbatim.
    return Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: path,
    ).toString();
  }

  /// Deduplicated in the order the endpoint listed them; blanks dropped.
  static List<CustomProviderModel> normalizeModels(
    List<CustomProviderModel> models,
  ) {
    final seen = <String>{};
    return [
      for (final model in models)
        if (model.id.trim().isNotEmpty && seen.add(model.id.trim()))
          CustomProviderModel(id: model.id.trim(), name: model.name),
    ];
  }

  /// Deduplicated by name (the last value wins), blanks dropped, order kept.
  static List<CustomProviderHeader> normalizeHeaders(
    List<CustomProviderHeader> headers,
  ) {
    final byName = <String, CustomProviderHeader>{};
    for (final header in headers) {
      final entry = header.entry;
      if (entry == null) continue;
      byName[entry.key.toLowerCase()] = header;
    }
    return List.unmodifiable(byName.values);
  }

  /// The headers as an HTTP map for the app's own requests (model list,
  /// probes, balance).
  Map<String, String> get headerMap {
    final map = <String, String>{};
    for (final header in headers) {
      final entry = header.entry;
      if (entry != null) map[entry.key] = entry.value;
    }
    return map;
  }

  /// The same provider under another wire protocol: the key, models and
  /// headers carry over; only the package and a `/v1` ↔ `/v1beta` root
  /// change. A custom path is never rewritten.
  CustomProviderDraft switchProtocol(ProviderProtocol next) {
    if (next == protocol) return this;
    return CustomProviderDraft(
      name: name,
      id: id,
      protocol: next,
      baseUrl: convertBaseUrl(baseUrl, from: protocol, to: next),
      apiKey: apiKey,
      keyMode: keyMode,
      models: models,
      headers: headers,
      timeoutMs: timeoutMs,
      keyFile: _keyFile,
      keyPlaceholder: keyPlaceholder,
    );
  }

  /// [baseUrl] re-rooted for [to] when it already ends in [from]'s default
  /// path. Everything else is kept byte for byte: gateways legitimately end
  /// in `/v4`, `/openai` or nothing at all, and guessing would invent a URL
  /// that does not answer.
  static String convertBaseUrl(
    String baseUrl, {
    required ProviderProtocol from,
    required ProviderProtocol to,
  }) {
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null || !uri.hasAuthority) return baseUrl;
    var path = uri.path;
    for (final suffix in from.endpointSuffixes) {
      if (path.toLowerCase().endsWith(suffix)) {
        path = path.substring(0, path.length - suffix.length);
        break;
      }
    }
    while (path.endsWith('/') && path.length > 1) {
      path = path.substring(0, path.length - 1);
    }
    final fromRoot = from.defaultPath;
    final toRoot = to.defaultPath;
    if (fromRoot != toRoot && path.toLowerCase().endsWith(fromRoot)) {
      path = path.substring(0, path.length - fromRoot.length) + toRoot;
    }
    return normalizeBaseUrl(
      Uri(
        scheme: uri.scheme,
        userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        path: path,
      ).toString(),
      to,
    );
  }

  /// Rejects what cannot be saved, with a reason the form can show.
  void validate() {
    if (name.trim().isEmpty) {
      throw const ProductException('Give the provider a name');
    }
    if (baseUrl.isEmpty) {
      throw const ProductException('Enter the provider\u2019s base URL');
    }
    final uri = Uri.tryParse(baseUrl);
    if (uri == null ||
        !uri.hasScheme ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const ProductException(
        'The base URL must start with http:// or https://',
      );
    }
    if (models.isEmpty) {
      throw const ProductException('Select at least one model');
    }
    if (keyMode == ProviderKeyMode.plaintext &&
        (apiKey?.trim().isEmpty ?? true)) {
      throw const ProductException('Enter the API key, or choose another way');
    }
    if (timeoutMs <= 0) {
      throw const ProductException('The timeout must be greater than zero');
    }
  }

  /// The provider entry alone, ready to be merged into a config document.
  Map<String, Object?> toProviderEntry(ProviderConfigFormat format) {
    validate();
    return switch (format) {
      ProviderConfigFormat.v1 => _v1Entry(),
      ProviderConfigFormat.v2 => _v2Entry(),
    };
  }

  Map<String, Object?> _v1Entry() => {
    'npm': protocol.npm,
    'name': name.trim(),
    'options': {
      'baseURL': baseUrl,
      if (keyMode == ProviderKeyMode.secretFile) 'apiKey': '{file:$secretPath}',
      if (keyMode == ProviderKeyMode.plaintext) 'apiKey': apiKey!.trim(),
      if (keyMode == ProviderKeyMode.external && keyPlaceholder != null)
        'apiKey': keyPlaceholder!,
      if (headerMap.isNotEmpty) 'headers': headerMap,
      'timeout': timeoutMs,
    },
    'models': {
      for (final model in models)
        model.id: {
          'name': model.label,
          'tool_call': true,
          'reasoning': protocol != ProviderProtocol.responses,
          'attachment': protocol != ProviderProtocol.chatCompletions,
          // Responses takes its sampling knobs per request, not per model.
          'temperature': protocol != ProviderProtocol.responses,
        },
    },
  };

  /// v2 keeps the key in `settings` (the schema has no explicit `baseURL`
  /// there — the extension slot carries it, which is how the official docs
  /// write it) and names model abilities under `capabilities`.
  ///
  /// The shape matters: `capabilities` is `additionalProperties: false`, with
  /// `input`/`output` as arrays of modality strings, `reasoning` as an object
  /// (`{supported: bool, …}`) rather than a boolean, and `temperature`/
  /// `tools` as booleans. The v1 spellings (`tool_call`, a bare `reasoning`)
  /// would be rejected here.
  ///
  /// `reasoning` is left out on purpose. A gateway serves reasoning and plain
  /// models from one endpoint, and this form cannot tell which is which;
  /// claiming support the endpoint lacks makes a request carry reasoning
  /// parameters it will refuse. Tools are always on (a coding client without
  /// them cannot work), images only where the protocol itself carries them.
  Map<String, Object?> _v2Entry() => {
    'package': protocol.package,
    'name': name.trim(),
    'settings': {
      'baseURL': baseUrl,
      if (keyMode == ProviderKeyMode.secretFile) 'apiKey': '{file:$secretPath}',
      if (keyMode == ProviderKeyMode.plaintext) 'apiKey': apiKey!.trim(),
      if (keyMode == ProviderKeyMode.external && keyPlaceholder != null)
        'apiKey': keyPlaceholder!,
      if (headerMap.isNotEmpty) 'headers': headerMap,
      'timeout': timeoutMs,
    },
    'models': {
      for (final model in models)
        model.id: {
          'name': model.label,
          'capabilities': {
            'tools': true,
            'input': _inputModalities,
            'output': const ['text'],
            if (protocol != ProviderProtocol.responses) 'temperature': true,
          },
        },
    },
  };

  /// Chat Completions has no agreed way to signal image input across
  /// gateways; Responses and Messages carry it in the protocol itself.
  List<String> get _inputModalities => switch (protocol) {
    ProviderProtocol.chatCompletions => const ['text'],
    _ => const ['text', 'image'],
  };

  /// The whole document, for a person who will paste it by hand.
  Map<String, Object?> toDocument(ProviderConfigFormat format) => {
    _rootKey(format): {id: toProviderEntry(format)},
  };

  /// `existing` with this provider added, or with an entry of the same id
  /// replaced when [replace] is set (the edit path).
  ///
  /// Adding refuses a duplicate id rather than replacing it: the person may
  /// be creating one they already rely on, and the form is not a place to
  /// lose a configuration quietly. Editing passes [replace], because there
  /// the duplicate is the point.
  Map<String, Object?> mergeInto(
    Map<String, Object?>? existing,
    ProviderConfigFormat format, {
    bool replace = false,
  }) {
    final entry = toProviderEntry(format);
    if (existing == null) return toDocument(format);
    final rootKey = _rootKey(format);
    final merged = <String, Object?>{...existing};
    final current = merged[rootKey];
    if (current == null) {
      merged[rootKey] = {id: entry};
      return merged;
    }
    if (current is! Map) {
      throw ProductException(
        'The server\u2019s "$rootKey" setting is not a list of providers',
      );
    }
    final providers = <String, Object?>{};
    current.forEach((key, value) => providers['$key'] = value);
    if (providers.containsKey(id) && !replace) {
      throw ProductException('A provider named "$id" already exists');
    }
    providers[id] = entry;
    merged[rootKey] = providers;
    return merged;
  }

  static String _rootKey(ProviderConfigFormat format) => switch (format) {
    ProviderConfigFormat.v1 => 'provider',
    ProviderConfigFormat.v2 => 'providers',
  };
}
