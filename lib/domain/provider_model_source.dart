/// Fetches the model list an endpoint advertises.
///
/// This is the one part of adding a provider that needs no server support:
/// it is a plain HTTPS call from the phone using the key the person is
/// already typing. It matters because a hand-written config fails most often
/// on model ids — a gateway renames or aliases them freely — so reading the
/// endpoint's own list is more reliable than any documented list.
///
/// Gateways built on NewAPI and OneAPI answer `GET {base}/models` in the
/// OpenAI shape (`{"data":[{"id":...}]}`); a few deployments put it under
/// `/v1` while the person typed the bare host, so that spelling is tried
/// second. Anthropic's list is its own shape but the same envelope.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'custom_provider.dart';

/// A model list that could not be read, in words the form can show.
class ProviderModelFetchFailure implements Exception {
  const ProviderModelFetchFailure(
    this.message, {
    this.statusCode,
    this.canRetryWithoutKey = false,
  });

  final String message;
  final int? statusCode;

  /// The endpoint answered 401/403: worth letting the person fix the key
  /// without leaving the form.
  final bool canRetryWithoutKey;

  @override
  String toString() => message;
}

/// One HTTP answer, reduced to what parsing needs.
class ProviderHttpAnswer {
  const ProviderHttpAnswer({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

/// Signature of the transport, so tests can answer without a socket.
typedef ProviderHttpGet =
    Future<ProviderHttpAnswer> Function(
      Uri url,
      Map<String, String> headers,
      Duration timeout,
    );

class ProviderModelSource {
  ProviderModelSource({ProviderHttpGet? get}) : _get = get ?? _defaultGet;

  final ProviderHttpGet _get;

  /// Reads the endpoint's models. Throws [ProviderModelFetchFailure].
  Future<List<CustomProviderModel>> fetch({
    required String baseUrl,
    required ProviderProtocol protocol,
    String? apiKey,
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final base = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    if (base.isEmpty) {
      throw const ProviderModelFetchFailure('Enter the base URL first');
    }
    final key = apiKey?.trim() ?? '';
    final candidates = <Uri>[
      if (protocol == ProviderProtocol.google)
        Uri.parse('$base/models?pageSize=100')
      else ...[
        Uri.parse('$base/models'),
        if (!base.toLowerCase().endsWith('/v1')) Uri.parse('$base/v1/models'),
      ],
    ];
    ProviderModelFetchFailure? lastFailure;
    for (final url in candidates) {
      final attempts = <Map<String, String>>[
        if (key.isNotEmpty) {..._headers(protocol, key, anthropicStyle: true), ...headers},
        if (key.isNotEmpty && protocol != ProviderProtocol.google)
          {..._headers(protocol, key, anthropicStyle: false), ...headers},
        <String, String>{'Accept': 'application/json', ...headers},
      ];
      for (final headers in attempts) {
        try {
          final answer = await _get(url, headers, timeout);
          if (answer.statusCode == 401 || answer.statusCode == 403) {
            lastFailure = ProviderModelFetchFailure(
              key.isEmpty
                  ? 'This endpoint needs an API key to list its models'
                  : 'The API key was refused (${answer.statusCode})',
              statusCode: answer.statusCode,
              canRetryWithoutKey: true,
            );
            continue;
          }
          if (answer.statusCode == 404) {
            lastFailure = ProviderModelFetchFailure(
              'No model list at ${url.path}',
              statusCode: 404,
            );
            // The other spelling of the base URL may still answer.
            break;
          }
          if (answer.statusCode != 200) {
            lastFailure = ProviderModelFetchFailure(
              'The endpoint answered ${answer.statusCode}',
              statusCode: answer.statusCode,
            );
            break;
          }
          final models = parseModelList(answer.body);
          if (models.isEmpty) {
            lastFailure = ProviderModelFetchFailure(
              'The endpoint listed no models',
              statusCode: 200,
            );
            break;
          }
          return models;
        } on TimeoutException {
          lastFailure = const ProviderModelFetchFailure(
            'The endpoint did not answer in time',
          );
          break;
        } on SocketException {
          lastFailure = const ProviderModelFetchFailure(
            'Could not reach the endpoint. Check the address and the network.',
          );
          break;
        } on HandshakeException {
          lastFailure = const ProviderModelFetchFailure(
            'The endpoint\u2019s certificate could not be verified',
          );
          break;
        } on FormatException {
          lastFailure = const ProviderModelFetchFailure(
            'The base URL is not a valid address',
          );
          break;
        }
      }
    }
    throw lastFailure ??
        const ProviderModelFetchFailure('Could not read the model list');
  }

  static Map<String, String> _headers(
    ProviderProtocol protocol,
    String key, {
    required bool anthropicStyle,
  }) {
    if (protocol == ProviderProtocol.google) {
      return {
        'x-goog-api-key': key,
        'Accept': 'application/json',
      };
    }
    // Anthropic's own hosts read `x-api-key`, while the many gateways that
    // translate Messages read the usual bearer token. Sending the native
    // header first and falling back covers both without asking the person
    // which kind of endpoint they have.
    if (protocol == ProviderProtocol.anthropic && anthropicStyle) {
      return {
        'x-api-key': key,
        'anthropic-version': '2023-06-01',
        'Accept': 'application/json',
      };
    }
    return {'Authorization': 'Bearer $key', 'Accept': 'application/json'};
  }

  /// Reads the model list out of the shapes gateways actually return.
  ///
  /// OpenAI and NewAPI: `{"object":"list","data":[{"id":...}]}`. Some
  /// gateways: a bare array, or `{"models":[...]}`. Their entries vary too:
  /// `id`, `model`, or a plain string.
  static List<CustomProviderModel> parseModelList(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return const [];
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      return const [];
    }
    final entries = switch (decoded) {
      List<Object?> list => list,
      Map<String, Object?> map =>
        (map['data'] ?? map['models'] ?? map['result']) is List
            ? (map['data'] ?? map['models'] ?? map['result']) as List<Object?>
            : const <Object?>[],
      _ => const <Object?>[],
    };
    final models = <CustomProviderModel>[];
    for (final entry in entries) {
      final raw = switch (entry) {
        String value => value,
        Map<String, Object?> map => map['id'] ?? map['model'] ?? map['name'],
        _ => null,
      };
      if (raw is! String || raw.trim().isEmpty) continue;
      // Gemini lists its models as `models/gemini-2.5-pro`, while every
      // other endpoint uses the bare id. The request path wants the bare id.
      var id = raw.trim();
      if (id.startsWith('models/')) id = id.substring('models/'.length);
      if (id.isEmpty) continue;
      final name = entry is Map<String, Object?>
          ? entry['display_name'] ?? entry['displayName']
          : null;
      models.add(
        CustomProviderModel(id: id, name: name is String ? name : null),
      );
    }
    return CustomProviderDraft.normalizeModels(models);
  }

  static Future<ProviderHttpAnswer> _defaultGet(
    Uri url,
    Map<String, String> headers,
    Duration timeout,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      // The environment's proxy, not DIRECT: a person on a phone may only
      // reach a gateway through the proxy they configured, and this call is
      // made by the app rather than by the server.
      ..findProxy = HttpClient.findProxyFromEnvironment;
    try {
      final request = await client.getUrl(url).timeout(timeout);
      request.followRedirects = true;
      headers.forEach(request.headers.set);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close().timeout(timeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      return ProviderHttpAnswer(statusCode: response.statusCode, body: body);
    } finally {
      client.close(force: true);
    }
  }
}
