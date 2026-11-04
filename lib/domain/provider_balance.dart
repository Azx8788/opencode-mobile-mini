/// Reads an account balance from an endpoint a provider documents.
///
/// Balance is not part of the model API: every gateway spells it differently
/// (DeepSeek `balance_infos[0].total_balance`, OpenRouter `/credits`
/// `data.total_credits`). So the person declares the address and the JSON
/// path once, and this file only does the boring part: substitute
/// `{{baseUrl}}` and `{{apiKey}}`, send the key the way gateways expect, and
/// walk the path.
///
/// Nothing here is stored on the server: a balance is a local convenience,
/// and the key never leaves the request it was needed for.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Where to ask, and which value in the answer is the balance.
class ProviderBalance {
  const ProviderBalance({
    this.enabled = false,
    this.url = '',
    this.resultPath = '',
  });

  final bool enabled;

  /// May contain `{{baseUrl}}` and `{{apiKey}}`.
  final String url;

  /// Dotted path into the JSON answer: `data.balance`,
  /// `balance_infos[0].total_balance`.
  final String resultPath;

  bool get isConfigured =>
      url.trim().isNotEmpty && resultPath.trim().isNotEmpty;

  ProviderBalance copyWith({bool? enabled, String? url, String? resultPath}) =>
      ProviderBalance(
        enabled: enabled ?? this.enabled,
        url: url ?? this.url,
        resultPath: resultPath ?? this.resultPath,
      );

  Map<String, Object> toJson() => {
    'enabled': enabled,
    if (url.isNotEmpty) 'url': url,
    if (resultPath.isNotEmpty) 'resultPath': resultPath,
  };

  factory ProviderBalance.fromJson(Object? value) {
    if (value is! Map) return const ProviderBalance();
    final url = value['url'];
    final path = value['resultPath'];
    return ProviderBalance(
      enabled: value['enabled'] == true,
      url: url is String ? url : '',
      resultPath: path is String ? path : '',
    );
  }
}

/// One successful reading, in words a settings page can show.
class ProviderBalanceReading {
  const ProviderBalanceReading({
    required this.value,
    required this.statusCode,
    required this.elapsed,
  });

  final String value;
  final int statusCode;
  final Duration elapsed;
}

/// A balance that could not be read, with its reason.
class ProviderBalanceFailure implements Exception {
  const ProviderBalanceFailure(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class ProviderBalanceAnswer {
  const ProviderBalanceAnswer({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

typedef ProviderBalanceGet =
    Future<ProviderBalanceAnswer> Function(
      Uri url,
      Map<String, String> headers,
      Duration timeout,
    );

class ProviderBalanceClient {
  ProviderBalanceClient({ProviderBalanceGet? get}) : _get = get ?? _defaultGet;

  final ProviderBalanceGet _get;

  static const timeout = Duration(seconds: 20);

  Future<ProviderBalanceReading> fetch({
    required ProviderBalance balance,
    required String baseUrl,
    String apiKey = '',
    Map<String, String> headers = const {},
  }) async {
    if (!balance.isConfigured) {
      throw const ProviderBalanceFailure(
        'Set the balance URL and the JSON path first',
      );
    }
    final base = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final key = apiKey.trim();
    final raw = balance.url
        .trim()
        .replaceAll('{{baseUrl}}', base)
        .replaceAll('{{apiKey}}', Uri.encodeComponent(key));
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      throw const ProviderBalanceFailure(
        'The balance URL is not a valid address',
      );
    }
    final started = DateTime.now();
    // Custom headers first, then the bearer the gateways expect: a header the
    // person added must not silently break authentication.
    final requestHeaders = <String, String>{
      ...headers,
      'accept': 'application/json',
      if (key.isNotEmpty) 'authorization': 'Bearer $key',
    };
    final ProviderBalanceAnswer answer;
    try {
      answer = await _get(uri, requestHeaders, timeout);
    } on TimeoutException {
      throw const ProviderBalanceFailure('The balance endpoint did not answer');
    } on SocketException {
      throw const ProviderBalanceFailure('Could not reach the balance endpoint');
    } on HandshakeException {
      throw const ProviderBalanceFailure(
        'The balance endpoint\u2019s certificate could not be verified',
      );
    }
    if (answer.statusCode < 200 || answer.statusCode >= 300) {
      throw ProviderBalanceFailure(
        'HTTP ${answer.statusCode}${_excerpt(answer.body)}',
        statusCode: answer.statusCode,
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(answer.body.trim());
    } on FormatException {
      throw const ProviderBalanceFailure('The answer is not JSON');
    }
    final value = walkBalanceJson(decoded, balance.resultPath);
    if (value == null) {
      throw ProviderBalanceFailure(
        'No value at "${balance.resultPath.trim()}" in the answer',
      );
    }
    return ProviderBalanceReading(
      value: renderBalanceValue(value),
      statusCode: answer.statusCode,
      elapsed: DateTime.now().difference(started),
    );
  }

  /// `a.b[0].c` → the value there, or null when the path meets a different
  /// shape. Numbers may index a list or name a map key, because gateways
  /// disagree even on that.
  static Object? walkBalanceJson(Object? root, String path) {
    Object? current = root;
    final tokens = RegExp(
      r'([^.\[\]]+)|\[(\d+)\]',
    ).allMatches(path.trim().replaceAll(RegExp(r'^\.+'), ''));
    for (final token in tokens) {
      final name = token.group(1);
      final index = token.group(2);
      if (index != null) {
        final i = int.tryParse(index);
        if (current is List && i != null && i >= 0 && i < current.length) {
          current = current[i];
        } else {
          return null;
        }
        continue;
      }
      if (name == null) continue;
      if (current is Map) {
        if (current.containsKey(name)) {
          current = current[name];
        } else {
          return null;
        }
      } else {
        return null;
      }
    }
    return current;
  }

  static String renderBalanceValue(Object? value) {
    if (value is String) return value.trim();
    if (value is num) {
      final text = value.toString();
      return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
    }
    if (value is bool) return value ? 'true' : 'false';
    if (value is Map || value is List) return jsonEncode(value);
    return '$value';
  }

  static String _excerpt(String body) {
    final collapsed = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.isEmpty) return '';
    final short = collapsed.length <= 120
        ? collapsed
        : '${collapsed.substring(0, 117)}…';
    return ': $short';
  }

  static Future<ProviderBalanceAnswer> _defaultGet(
    Uri url,
    Map<String, String> headers,
    Duration timeout,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
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
      return ProviderBalanceAnswer(
        statusCode: response.statusCode,
        body: body,
      );
    } finally {
      client.close(force: true);
    }
  }
}
