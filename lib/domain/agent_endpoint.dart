/// A third-party, Anthropic-compatible endpoint for Claude Code.
///
/// Claude Code reads `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN` from the
/// `env` block of its own settings file (`$CLAUDE_CONFIG_DIR/settings.json`).
/// This value is that block, checked before it can become a file. The key is
/// write-only: [toString] never carries it, and the sheet only remembers
/// whether one is stored, never what it was.
library;

import 'server_gateway/value_types_catalog.dart';

/// Whether [agentId]'s own settings file takes a gateway endpoint.
///
/// Claude Code documents the `env` block; the other pinned agents do not, and
/// guessing a key for them would write a file that silently does nothing.
bool agentSupportsEndpoint(String agentId) => agentId == 'claude';

final class AgentEndpoint {
  AgentEndpoint({required String baseUrl, String? apiKey, String? model})
    : baseUrl = _baseUrl(baseUrl),
      apiKey = _apiKey(apiKey),
      model = _model(model);

  /// Normalized: `http(s)://host[:port][/path]`, no trailing slash, no query
  /// and no fragment. Claude Code appends `/v1/messages` itself.
  final String baseUrl;

  /// Write-only. Never logged, never echoed by the host, never persisted in
  /// app preferences: the settings file is its only home.
  ///
  /// Null keeps the key already saved in that file, so changing the address
  /// or the model does not ask for a secret the app cannot read back.
  final String? apiKey;

  /// The model Claude Code asks for by default; null leaves its own choice.
  final String? model;

  Uri get uri => Uri.parse(baseUrl);
  String get host => uri.host;
  bool get isSecure => uri.scheme == 'https';

  static String _baseUrl(String value) {
    final text = value.trim();
    if (text.isEmpty) {
      throw const ProductException('Enter the endpoint\u2019s base URL');
    }
    if (text.length > 2048 || RegExp(r'[\x00-\x20\x7f]').hasMatch(text)) {
      throw const ProductException('This base URL is not valid');
    }
    final uri = Uri.tryParse(text);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const ProductException(
        'Use an address like https://gateway.example.com',
      );
    }
    final path = uri.path.replaceAll(RegExp(r'/+$'), '');
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: path,
    ).toString();
  }

  static String? _apiKey(String? value) {
    if (value == null) return null;
    final text = value.trim();
    if (text.isEmpty) {
      throw const ProductException('Enter the endpoint\u2019s key');
    }
    if (text.length > 4096 || RegExp(r'[\x00-\x20\x7f]').hasMatch(text)) {
      throw const ProductException(
        'This key contains characters that cannot be saved',
      );
    }
    return text;
  }

  static String? _model(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    if (text.length > 200 ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$').hasMatch(text)) {
      throw const ProductException('This model name is not valid');
    }
    return text;
  }

  /// Host and model only: the key never appears in a log line or an error.
  @override
  String toString() => 'AgentEndpoint($host${model == null ? '' : ', $model'})';
}

/// What the phone's settings file says now. The key is reported as presence
/// only, so the form can say "a key is saved" without ever reading it back.
final class AgentEndpointStatus {
  const AgentEndpointStatus({
    required this.baseUrl,
    required this.model,
    required this.hasKey,
  });

  static const absent = AgentEndpointStatus(
    baseUrl: null,
    model: null,
    hasKey: false,
  );

  final String? baseUrl;
  final String? model;
  final bool hasKey;

  bool get configured => baseUrl != null && hasKey;

  @override
  String toString() => 'AgentEndpointStatus($baseUrl)';
}
