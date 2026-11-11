/// Runs the model-list request inside the server, and answers in the shape
/// the form's existing reader already speaks.
///
/// The split is deliberate: [ProviderModelSource] keeps deciding *what* to ask
/// — which spellings of `/models`, which auth scheme first, what a 401 or an
/// HTML page means — and this class only carries one request at a time into
/// the server's environment, where the key already is.
library;

import 'dart:convert';

import '../diagnostics/app_log.dart';
import '../domain/custom_provider.dart';
import '../domain/provider_model_source.dart';
import 'builtin_linux.dart';
import 'builtin_provider_store.dart' show BuiltinScriptRunner;
import 'provider_server_scripts.dart';

/// What the saved entry looks like from the server's side.
class ProviderServerDescription {
  const ProviderServerDescription({
    required this.baseUrl,
    required this.hasKey,
    required this.keySource,
  });

  /// The address the config holds — the one the server will actually use.
  /// Empty when the entry has none.
  final String baseUrl;

  /// True when a key is there and the script could read it.
  final bool hasKey;

  /// `config`, `file`, `env` or `none`. `env` is the one case the app cannot
  /// see: the server keeps that key in its own environment.
  final String keySource;

  bool get keyIsOnServer => keySource == 'env';
}

/// The auth scheme one attempt asks for, read from the header names
/// [ProviderModelSource] built.
///
/// Only the names matter: the value in Dart is a placeholder, because the real
/// key is on the server and must not travel through a shell command. Keeping
/// the choice here means the "try `x-api-key`, then bearer" policy stays in
/// one place, already covered by tests.
String providerServerAuthScheme(Map<String, String> headers) {
  var scheme = 'none';
  for (final name in headers.keys) {
    switch (name.toLowerCase()) {
      case 'x-api-key':
        return 'x-api-key';
      case 'x-goog-api-key':
        return 'x-goog-api-key';
      case 'authorization':
        scheme = 'bearer';
    }
  }
  return scheme;
}

/// The value [ProviderModelSource] puts in its auth headers. It is never sent
/// anywhere: [providerServerAuthScheme] reads the header names, and the script
/// reads the key from the config.
const providerServerKeyPlaceholder = 'server';

class ProviderServerModelSource {
  ProviderServerModelSource({
    BuiltinLinux? linux,
    BuiltinScriptRunner? run,
    String? userAgent,
  }) : _run =
           run ?? ((script, timeout) => linux!.run(script, timeout: timeout)),
       _userAgent = userAgent ?? ProviderServerScripts.userAgent(null);

  final BuiltinScriptRunner _run;
  final String _userAgent;

  /// Reads the entry's address and whether a key is there.
  Future<ProviderServerDescription> describe({
    required String configPath,
    required String providerID,
  }) async {
    final answer = await _invoke(
      ProviderServerScripts.describe(
        configPath: configPath,
        providerID: providerID,
        userAgent: _userAgent,
      ),
      const Duration(seconds: 45),
    );
    final baseUrl = answer['baseUrl'];
    return ProviderServerDescription(
      baseUrl: baseUrl is String ? baseUrl.trim() : '',
      hasKey: answer['hasKey'] == true,
      keySource: answer['keySource'] is String
          ? answer['keySource'] as String
          : 'none',
    );
  }

  /// Reads the endpoint's model list the way the server would.
  ///
  /// Throws [ProviderModelFetchFailure]; the form already knows how to word
  /// every kind.
  Future<ProviderModelListing> fetch({
    required String configPath,
    required String providerID,
    required String baseUrl,
    required ProviderProtocol protocol,
    void Function(List<String> trace)? onTrace,
  }) async {
    final description = await describe(
      configPath: configPath,
      providerID: providerID,
    );
    // The config is what the server will use, so its address wins over the
    // one on screen: an entry edited by hand is not this form's to override.
    final root = description.baseUrl.isNotEmpty
        ? description.baseUrl
        : baseUrl;
    final source = ProviderModelSource(
      get: (url, headers, timeout) => _get(
        configPath: configPath,
        providerID: providerID,
        url: url,
        auth: providerServerAuthScheme(headers),
        timeout: timeout,
      ),
    );
    return source.fetch(
      baseUrl: root,
      protocol: protocol,
      // Presence, not value: the script picks the real key out of the config.
      apiKey: description.hasKey ? providerServerKeyPlaceholder : null,
      onTrace: onTrace,
    );
  }

  Future<ProviderHttpAnswer> _get({
    required String configPath,
    required String providerID,
    required Uri url,
    required String auth,
    required Duration timeout,
  }) async {
    final answer = await _invoke(
      ProviderServerScripts.get(
        configPath: configPath,
        providerID: providerID,
        userAgent: _userAgent,
        url: url,
        auth: auth,
        timeout: timeout,
      ),
      timeout + const Duration(seconds: 20),
    );
    final error = answer['error'];
    if (error is String) {
      throw ProviderModelFetchFailure(
        switch (error) {
          'tls' => 'The server could not verify the address\u2019s certificate',
          'timeout' => 'The server did not get an answer in time',
          _ => 'The server could not reach the address',
        },
        kind: switch (error) {
          'tls' => ProviderModelFetchKind.tls,
          'timeout' => ProviderModelFetchKind.timeout,
          _ => ProviderModelFetchKind.network,
        },
      );
    }
    final status = answer['status'];
    final body = answer['body'];
    if (status is! num) {
      throw const ProviderModelFetchFailure(
        'The server sent no answer',
        kind: ProviderModelFetchKind.serverUnavailable,
      );
    }
    return ProviderHttpAnswer(
      statusCode: status.toInt(),
      body: body is String ? body : '',
    );
  }

  /// One script run, decoded. Every failure that is not the provider's own
  /// answer becomes [ProviderModelFetchKind.serverUnavailable] — the rule the
  /// whole flow rests on: no silent fallback to a request from the phone.
  Future<Map<String, Object?>> _invoke(String script, Duration timeout) async {
    final BuiltinLinuxRunResult result;
    try {
      result = await _run(script, timeout);
    } on Object catch (error) {
      AppLog.warn('provider', 'server model read could not start', {
        'error': '$error',
      });
      throw const ProviderModelFetchFailure(
        'The server could not run the request',
        kind: ProviderModelFetchKind.serverUnavailable,
      );
    }
    final marker = result.output.indexOf(ProviderServerScripts.marker);
    if (marker >= 0) {
      final payload = result.output
          .substring(marker + ProviderServerScripts.marker.length)
          .split(RegExp(r'\s'))
          .firstWhere((part) => part.isNotEmpty, orElse: () => '');
      final decoded = _decode(payload);
      if (decoded != null) return decoded;
    }
    // No answer: the exit code says which part of the environment is missing.
    final reason = switch (result.exitCode) {
      20 => 'The server has no python3 to run the request with',
      21 => 'The server\u2019s configuration could not be read',
      22 => 'The provider is not in the server\u2019s configuration yet',
      23 || 24 => 'The request could not be prepared',
      _ => 'The server did not answer',
    };
    AppLog.warn('provider', 'server model read failed', {
      'exit': result.exitCode,
      'answer': marker >= 0,
    });
    throw ProviderModelFetchFailure(
      reason,
      kind: result.exitCode == 22
          ? ProviderModelFetchKind.notConfigured
          : ProviderModelFetchKind.serverUnavailable,
    );
  }

  static Map<String, Object?>? _decode(String payload) {
    if (payload.isEmpty) return null;
    try {
      final value = jsonDecode(utf8.decode(base64Decode(payload)));
      return value is Map ? {for (final e in value.entries) '${e.key}': e.value} : null;
    } catch (_) {
      return null;
    }
  }
}
