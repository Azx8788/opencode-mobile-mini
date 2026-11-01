import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../ui/kit/kit_redact.dart';

/// Metadata only: registry content is untrusted and is never executed.
class RegistryEntry {
  RegistryEntry._({
    required this.name,
    required this.version,
    required this.description,
    required this.remotes,
    required this.packages,
    this.title = '',
  });

  final String name;
  final String version;
  final String description;

  /// The listing's display name (`title`), plain text; empty when absent.
  final String title;
  final List<RegistryRemote> remotes;
  final List<RegistryPackage> packages;
  String get id => '$name@$version';

  /// The UI must still ask the user to select the endpoint and review a diff.
  RegistryRemote? get connectableRemote =>
      remotes.where((remote) => !remote.requiresConfiguration).firstOrNull;

  String? get unsupportedReason {
    if (connectableRemote != null) return null;
    if (remotes.isNotEmpty) {
      return 'This server needs connection details. Set it up by hand.';
    }
    if (packages.isNotEmpty) {
      return 'Package installation needs a reviewed command on your server. Set it up by hand.';
    }
    return 'This listing has no supported HTTPS endpoint. Set it up by hand.';
  }

  static RegistryEntry? fromJson(Object? value) {
    if (value is! Map) return null;
    final name = _identifier(value['name']);
    final version = _identifier(value['version']);
    if (name == null || version == null) return null;
    return RegistryEntry._(
      name: name,
      version: version,
      description: _safeText(value['description'], 1000),
      title: _safeText(value['title'], 120),
      remotes: List.unmodifiable([
        for (final item in _items(value['remotes']))
          ?RegistryRemote.fromJson(item),
      ]),
      packages: List.unmodifiable([
        for (final item in _items(value['packages']))
          ?RegistryPackage.fromJson(item),
      ]),
    );
  }

  Map<String, Object?> toJson() => {
    'name': KitRedact.text(name),
    'version': KitRedact.text(version),
    'description': KitRedact.text(description),
    if (title.isNotEmpty) 'title': KitRedact.text(title),
    'remotes': remotes.map((entry) => entry.toJson()).toList(),
    'packages': packages.map((entry) => entry.toJson()).toList(),
  };
}

class RegistryRemote {
  RegistryRemote._(
    this.type,
    this.url,
    this.requiresConfiguration, {
    this.headers = const [],
  });
  final String type;
  final String url;

  /// Registry header values, defaults and descriptions are deliberately not
  /// retained. This is not evidence that OAuth is supported or that sign-in
  /// is required.
  final bool requiresConfiguration;

  /// The header names the listing declares (names only, never a value), so
  /// a form can ask for each value as a secret.
  final List<RegistryVariable> headers;

  static RegistryRemote? fromJson(Object? value) {
    if (value is! Map) return null;
    final type = value['type'];
    final raw = value['url'];
    if (type != 'streamable-http' && type != 'sse') return null;
    if (raw is! String || raw.length > 2048) return null;
    final url = Uri.tryParse(raw);
    if (url == null ||
        url.scheme != 'https' ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        raw.contains(RegExp(r'[{}\s]')) ||
        _unsafeEncodedUrl(raw)) {
      return null;
    }
    return RegistryRemote._(
      type as String,
      KitRedact.text(raw),
      value['requiresConfiguration'] == true ||
          (value['headers'] is List && (value['headers'] as List).isNotEmpty) ||
          (value['variables'] is Map && (value['variables'] as Map).isNotEmpty),
      headers: List.unmodifiable([
        for (final item in _items(value['headers']))
          ?RegistryVariable.fromJson(item, header: true),
      ]),
    );
  }

  /// A disabled candidate only. Applying it still needs the setup controller's
  /// validation, explicit confirmation and server capability checks.
  Map<String, Object?> toMcpConfig() {
    if (requiresConfiguration) {
      throw const SetupRegistryException(
        'This server needs connection details. Set it up by hand.',
      );
    }
    return {'type': 'remote', 'url': url, 'enabled': false};
  }

  Map<String, Object?> toJson() => {
    'type': KitRedact.text(type),
    'url': KitRedact.text(url),
    'requiresConfiguration': requiresConfiguration,
    if (headers.isNotEmpty)
      'headers': headers.map((entry) => entry.toJson()).toList(),
  };
}

/// A header or environment variable a listing declares: its name and
/// whether it is required or secret. The value, default, description and
/// format are never retained (registry text is untrusted, and a "value" or
/// "default" can carry a credential).
class RegistryVariable {
  const RegistryVariable._(
    this.name, {
    this.required = false,
    this.secret = false,
  });

  final String name;
  final bool required;
  final bool secret;

  static final _envName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$');
  static final _headerName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$');

  static RegistryVariable? fromJson(Object? value, {bool header = false}) {
    if (value is! Map) return null;
    final name = value['name'];
    if (name is! String ||
        !(header ? _headerName : _envName).hasMatch(name) ||
        KitRedact.containsSecret(name)) {
      return null;
    }
    return RegistryVariable._(
      name,
      required: value['isRequired'] == true,
      secret: value['isSecret'] == true,
    );
  }

  Map<String, Object?> toJson() => {
    'name': name,
    if (required) 'isRequired': true,
    if (secret) 'isSecret': true,
  };
}

class RegistryPackage {
  RegistryPackage._(
    this.registryType,
    this.identifier,
    this.version, {
    this.transport,
    this.runtimeHint,
    this.environment = const [],
    this.requiresArguments = false,
  });
  final String registryType;
  final String identifier;
  final String version;

  /// `stdio`, `streamable-http` or `sse`; null when the listing names none.
  final String? transport;

  /// The runner the listing suggests (`npx`, `uvx`, `docker`), an
  /// identifier only; null when absent.
  final String? runtimeHint;

  /// Environment variable names the package declares (never values).
  final List<RegistryVariable> environment;

  /// The listing declares required runtime or package arguments. Their
  /// values are never retained: an argument list is a command line.
  final bool requiresArguments;

  static RegistryPackage? fromJson(Object? value) {
    if (value is! Map) return null;
    final type = _identifier(value['registryType']);
    final identifier = _identifier(value['identifier']);
    final version = _identifier(value['version']);
    if (type == null || identifier == null || version == null) return null;
    final transport = value['transport'];
    final transportType = transport is Map
        ? transport['type']
        : value['transport'];
    bool required(Object? list) =>
        list is List &&
        list.any((item) => item is Map && item['isRequired'] == true);
    return RegistryPackage._(
      type,
      identifier,
      version,
      transport:
          const {'stdio', 'streamable-http', 'sse'}.contains(transportType)
          ? transportType as String
          : null,
      runtimeHint: _identifier(value['runtimeHint']),
      environment: List.unmodifiable([
        for (final item in _items(value['environmentVariables']))
          ?RegistryVariable.fromJson(item),
      ]),
      requiresArguments:
          value['requiresArguments'] == true ||
          required(value['runtimeArguments']) ||
          required(value['packageArguments']),
    );
  }

  Map<String, Object?> toJson() => {
    'registryType': KitRedact.text(registryType),
    'identifier': KitRedact.text(identifier),
    'version': KitRedact.text(version),
    'transport': ?transport,
    'runtimeHint': ?runtimeHint,
    if (environment.isNotEmpty)
      'environmentVariables': environment
          .map((entry) => entry.toJson())
          .toList(),
    if (requiresArguments) 'requiresArguments': true,
  };
}

/// Contains only fixed application copy, never an HTTP body or raw exception.
class SetupRegistryException implements Exception {
  const SetupRegistryException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Explicitly invoked, unauthenticated, single-page public catalog request.
/// Never pass a server's authenticated Dio to this client.
class SetupRegistryClient {
  SetupRegistryClient({HttpClientAdapter? adapter})
    : _dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 15))) {
    if (adapter != null) _dio.httpClientAdapter = adapter;
  }

  static const endpoint =
      'https://registry.modelcontextprotocol.io/v0.1/servers';
  static const maxResponseBytes = 512 * 1024;
  static const maxEntries = 100;
  final Dio _dio;

  /// [search] narrows the list on the registry's side (its `search`
  /// parameter, a substring match on the listing name); it is the person's
  /// own words, never a credential.
  Future<List<RegistryEntry>> fetch({
    CancelToken? cancelToken,
    String? search,
  }) async {
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      final response = await _dio
          .get<ResponseBody>(
            endpoint,
            queryParameters: {
              'limit': maxEntries,
              'version': 'latest',
              'search': ?_searchTerm(search),
            },
            cancelToken: cancelToken,
            options: Options(
              responseType: ResponseType.stream,
              followRedirects: false,
              maxRedirects: 0,
              receiveTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(seconds: 15),
              headers: const {'Accept': 'application/json'},
              validateStatus: (status) => status == 200,
            ),
          )
          .timeout(const Duration(seconds: 20));
      final body = response.data;
      if (body == null) throw const FormatException();
      final builder = BytesBuilder(copy: false);
      await for (final chunk in body.stream.timeout(
        const Duration(seconds: 15),
      )) {
        if (builder.length + chunk.length > maxResponseBytes ||
            DateTime.now().isAfter(deadline)) {
          throw const FormatException();
        }
        builder.add(chunk);
      }
      final decoded = jsonDecode(utf8.decode(builder.takeBytes()));
      if (decoded is! Map || decoded['servers'] is! List) {
        throw const FormatException();
      }
      final result = <RegistryEntry>[];
      for (final item in (decoded['servers'] as List).take(maxEntries)) {
        if (item is! Map) continue;
        final meta = item['_meta'];
        final official = meta is Map
            ? meta['io.modelcontextprotocol.registry/official']
            : null;
        if (official is Map &&
            (official['status'] == 'deleted' ||
                official['status'] == 'deprecated')) {
          continue;
        }
        final entry = RegistryEntry.fromJson(item['server']);
        if (entry != null) result.add(entry);
      }
      return List.unmodifiable(result);
    } catch (_) {
      throw const SetupRegistryException(
        'The public registry could not be loaded. Try again or set up by hand.',
      );
    }
  }

  void dispose() => _dio.close(force: true);
}

/// A search term the registry may see: trimmed, at most 100 characters,
/// and dropped when it looks like a credential (never sent anywhere).
String? _searchTerm(String? value) {
  final term = value?.trim() ?? '';
  if (term.isEmpty || term.length > 100 || KitRedact.containsSecret(term)) {
    return null;
  }
  return term;
}

Iterable<Object?> _items(Object? value) =>
    value is List ? value.take(10) : const [];

String _safeText(Object? value, int limit) {
  if (value is! String) return '';
  final safe = KitRedact.text(value).replaceAll(RegExp(r'[\x00-\x1f]'), ' ');
  return safe.length > limit ? safe.substring(0, limit) : safe;
}

String? _identifier(Object? value) {
  if (value is! String || value.isEmpty || value.length > 256) return null;
  // Identifiers are metadata, never URLs, command lines or credential values.
  if (!RegExp(r'^[A-Za-z0-9@._/+-]+$').hasMatch(value) ||
      KitRedact.containsSecret(value)) {
    return null;
  }
  return KitRedact.text(value);
}

bool _unsafeEncodedUrl(String value) {
  try {
    return KitRedact.containsSecret(Uri.decodeFull(value));
  } catch (_) {
    return true;
  }
}
