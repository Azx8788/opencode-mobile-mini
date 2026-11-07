/// Fetches the model list an endpoint advertises.
///
/// This is the one part of adding a provider that needs no server support:
/// it is a plain HTTPS call from the phone using the key the person is
/// already typing. It matters because a hand-written config fails most often
/// on model ids — a gateway renames or aliases them freely — so reading the
/// endpoint's own list is more reliable than any documented list.
///
/// Gateways built on NewAPI and OneAPI answer `GET {base}/models` in the
/// OpenAI shape (`{"data":[{"id":...}]}`), some put it under `/v1` while the
/// person typed the bare host, and Gemini puts it under `/v1beta`. All three
/// spellings are tried, because the cost of a wrong guess is one cheap
/// request and the cost of not guessing is a person staring at "no models".
///
/// Every attempt is recorded, so a failure can say *where* it asked and
/// *what came back* instead of one sentence that fits every cause.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'custom_provider.dart';
import 'provider_tls.dart';
import 'server_trust.dart' show ServerCertificateInfo;

/// Why a model list could not be read. The message is an English fallback;
/// the form translates the kind, so the person reads a sentence in their own
/// language rather than a debug string.
enum ProviderModelFetchKind {
  /// The address is not a usable http(s) URL.
  badUrl,

  /// The endpoint wants a key and none was given.
  missingKey,

  /// The endpoint answered 401/403.
  refusedKey,

  /// No `/models` path answered at any spelling of the base URL.
  notFound,

  /// A 200 whose body is a web page, not JSON — a login wall or a firewall.
  notJson,

  /// A 200 that parsed but named no models.
  emptyList,

  /// The endpoint did not answer in time.
  timeout,

  /// DNS, TCP or TLS did not get as far as an answer.
  network,

  /// The certificate could not be verified.
  tls,

  /// The endpoint answered, but with a status that is not a model list.
  serverError,

  /// Anything else, reported with its text.
  unknown,
}

/// A model list that could not be read, in words the form can show.
class ProviderModelFetchFailure implements Exception {
  const ProviderModelFetchFailure(
    this.message, {
    this.kind = ProviderModelFetchKind.unknown,
    this.statusCode,
    this.canRetryWithoutKey = false,
    this.trace = const <String>[],
    this.path,
    this.tlsProblem,
    this.certificate,
    this.trustWasPinned = false,
  });

  /// English fallback, for logs and for a kind this build has no wording for.
  final String message;

  final ProviderModelFetchKind kind;
  final int? statusCode;

  /// The endpoint answered 401/403: worth letting the person fix the key
  /// without leaving the form.
  final bool canRetryWithoutKey;

  /// What was asked, in order: `host/path · status`.
  final List<String> trace;

  /// The last path tried, for a message that can point at it.
  final String? path;

  /// [ProviderModelFetchKind.tls] only: what the handshake said was wrong.
  final ProviderTlsProblem? tlsProblem;

  /// [ProviderModelFetchKind.tls] only: the certificate the endpoint sent, so
  /// the form can show its fingerprint and offer to trust it.
  final ServerCertificateInfo? certificate;

  /// True when a certificate had already been trusted for this origin and the
  /// endpoint now presents a different one. That is a warning, not the first
  /// question: something replaced the certificate the person checked.
  final bool trustWasPinned;

  @override
  String toString() => message;
}

/// One successful read: the models, and where they came from — the form says
/// so, because "2 models" with no address is not proof of anything.
class ProviderModelListing {
  const ProviderModelListing({
    required this.models,
    required this.url,
    required this.statusCode,
  });

  final List<CustomProviderModel> models;
  final Uri url;
  final int statusCode;
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
  ProviderModelSource({
    ProviderHttpGet? get,
    this.overallBudget = const Duration(seconds: 50),
  }) : _get = get;

  /// A test transport; null means the real one, built per call so it can
  /// carry the trust this fetch was given.
  final ProviderHttpGet? _get;

  /// The whole read, not one request. A gateway that hangs on the first
  /// spelling must not keep the button spinning for a minute.
  final Duration overallBudget;

  /// Reads the endpoint's models. Throws [ProviderModelFetchFailure].
  ///
  /// [onTrace] is called after every answer, so a slow endpoint shows its
  /// progress instead of a dead button.
  Future<ProviderModelListing> fetch({
    required String baseUrl,
    required ProviderProtocol protocol,
    String? apiKey,
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 20),
    String? trustedFingerprint,
    void Function(List<String> trace)? onTrace,
  }) async {
    final base = _cleanBase(baseUrl);
    if (base == null) {
      throw const ProviderModelFetchFailure(
        'The base URL is not a valid address',
        kind: ProviderModelFetchKind.badUrl,
      );
    }
    final key = cleanKey(apiKey);
    final extra = cleanHeaders(headers);
    final urls = candidateUrls(base, protocol);
    final attempts = _attempts(protocol, key, extra.headers);
    final trace = <String>[];
    final clock = Stopwatch()..start();
    ProviderModelFetchFailure? best;
    // A transport supplied by a test never touches TLS; the default one reads
    // the trust this call was given.
    final get =
        _get ??
        (url, requestHeaders, requestTimeout) => _defaultGet(
          url,
          requestHeaders,
          requestTimeout,
          trustedFingerprint: trustedFingerprint,
        );
    final pinned = (trustedFingerprint ?? '').trim().isNotEmpty;

    for (final url in urls) {
      for (final sent in attempts) {
        if (clock.elapsed > overallBudget) {
          throw best ??
              ProviderModelFetchFailure(
                'The endpoint did not answer in time',
                kind: ProviderModelFetchKind.timeout,
                trace: List.unmodifiable(trace),
              );
        }
        try {
          final answer = await get(url, sent, timeout);
          final code = answer.statusCode;
          trace.add('${_short(url)} · $code');
          onTrace?.call(List.unmodifiable(trace));

          if (code == 200) {
            final models = parseModelList(answer.body);
            if (models.isNotEmpty) {
              return ProviderModelListing(
                models: models,
                url: url,
                statusCode: code,
              );
            }
            // A 200 that names nothing: a login page served by a catch-all
            // route, or a real list that is empty. Either way another
            // spelling of the path may still answer.
            final html = looksLikeHtml(answer.body);
            best = ProviderModelFetchFailure(
              html
                  ? 'The endpoint returned a web page, not a model list'
                  : 'The endpoint listed no models',
              kind: html
                  ? ProviderModelFetchKind.notJson
                  : ProviderModelFetchKind.emptyList,
              statusCode: code,
              trace: List.unmodifiable(trace),
              path: url.path,
            );
            break;
          }
          if (code == 401 || code == 403) {
            best = ProviderModelFetchFailure(
              key.isEmpty
                  ? 'This endpoint needs an API key to list its models'
                  : 'The API key was refused ($code)',
              kind: key.isEmpty
                  ? ProviderModelFetchKind.missingKey
                  : ProviderModelFetchKind.refusedKey,
              statusCode: code,
              canRetryWithoutKey: true,
              trace: List.unmodifiable(trace),
              path: url.path,
            );
            // Another auth scheme may be the one this gateway reads.
            continue;
          }
          if (code == 404 || code == 405) {
            best ??= ProviderModelFetchFailure(
              'No model list at ${url.path}',
              kind: ProviderModelFetchKind.notFound,
              statusCode: code,
              trace: List.unmodifiable(trace),
              path: url.path,
            );
            // The path is wrong; a different header will not fix it.
            break;
          }
          best = ProviderModelFetchFailure(
            'The endpoint answered $code',
            kind: ProviderModelFetchKind.serverError,
            statusCode: code,
            trace: List.unmodifiable(trace),
            path: url.path,
          );
        } on TimeoutException {
          trace.add('${_short(url)} · timeout');
          onTrace?.call(List.unmodifiable(trace));
          throw ProviderModelFetchFailure(
            'The endpoint did not answer in time',
            kind: ProviderModelFetchKind.timeout,
            trace: List.unmodifiable(trace),
            path: url.path,
          );
        } on HandshakeException catch (error) {
          final tls = error is ProviderTlsException ? error : null;
          throw ProviderModelFetchFailure(
            'The endpoint\u2019s certificate could not be verified',
            kind: ProviderModelFetchKind.tls,
            tlsProblem: tls?.problem ?? classifyProviderTlsFailure(error),
            certificate: tls?.info,
            trustWasPinned: pinned,
            trace: List.unmodifiable(trace),
            path: url.path,
          );
        } on SocketException {
          throw ProviderModelFetchFailure(
            'Could not reach the endpoint. Check the address and the network.',
            kind: ProviderModelFetchKind.network,
            trace: List.unmodifiable(trace),
            path: url.path,
          );
        } on FormatException {
          throw ProviderModelFetchFailure(
            'The base URL is not a valid address',
            kind: ProviderModelFetchKind.badUrl,
            trace: List.unmodifiable(trace),
            path: url.path,
          );
        } catch (error) {
          best = ProviderModelFetchFailure(
            '$error',
            trace: List.unmodifiable(trace),
            path: url.path,
          );
        }
      }
      // Every header has been tried for this path; move to the next spelling.
      onTrace?.call(List.unmodifiable(trace));
    }
    if (best != null) {
      // The trace is only complete now: every spelling has been asked. A
      // failure captured mid-loop would report the first 404 as if it were
      // the last word.
      throw ProviderModelFetchFailure(
        best.message,
        kind: best.kind,
        statusCode: best.statusCode,
        canRetryWithoutKey: best.canRetryWithoutKey,
        trace: List.unmodifiable(trace),
        path: best.path,
      );
    }
    throw ProviderModelFetchFailure(
      'Could not read the model list',
      trace: List.unmodifiable(trace),
    );
  }

  /// The spellings of `{base}/models` worth asking, nearest first.
  ///
  /// A bare host is the common case: people paste `https://gw.example.com`
  /// and the list lives at `/v1/models`, while a NewAPI deployment answers
  /// the bare `/models` too.
  static List<Uri> candidateUrls(String base, ProviderProtocol protocol) {
    final trimmed = base.endsWith('/')
        ? base.substring(0, base.length - 1)
        : base;
    final lower = trimmed.toLowerCase();
    final paths = <String>[];
    void add(String value) {
      if (!paths.contains(value)) paths.add(value);
    }

    add('$trimmed/models');
    if (!lower.endsWith('/v1')) add('$trimmed/v1/models');
    if (protocol == ProviderProtocol.google) {
      if (!lower.endsWith('/v1beta')) {
        add('$trimmed/v1beta/models?pageSize=100');
      }
      add('$trimmed/models?pageSize=100');
    }
    return [for (final path in paths) Uri.parse(path)];
  }

  /// Header sets to try for one URL, most likely first. A 401 moves to the
  /// next set; a 404 does not.
  static List<Map<String, String>> _attempts(
    ProviderProtocol protocol,
    String key,
    Map<String, String> extra,
  ) {
    final out = <Map<String, String>>[];
    void add(Map<String, String> auth) {
      final map = <String, String>{...auth, ...extra};
      final duplicate = out.any(
        (existing) =>
            existing.length == map.length &&
            map.entries.every((entry) => existing[entry.key] == entry.value),
      );
      if (!duplicate) out.add(map);
    }

    if (key.isNotEmpty) {
      if (protocol == ProviderProtocol.anthropic) {
        add({
          'x-api-key': key,
          'anthropic-version': '2023-06-01',
          'Accept': 'application/json',
        });
      } else if (protocol == ProviderProtocol.google) {
        add({'x-goog-api-key': key, 'Accept': 'application/json'});
      }
      // Anthropic's own hosts read `x-api-key`; the many gateways that
      // translate Messages read the usual bearer token. Trying both covers
      // either without asking the person which kind of endpoint they have.
      add({'Authorization': 'Bearer $key', 'Accept': 'application/json'});
    }
    add({'Accept': 'application/json'});
    return out;
  }

  /// The base URL, with a scheme if it was typed without one. Null when
  /// nothing usable is left.
  static String? _cleanBase(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return null;
    if (!value.contains('://')) value = 'https://$value';
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    var path = uri.path;
    while (path.endsWith('/') && path.length > 1) {
      path = path.substring(0, path.length - 1);
    }
    return Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: path,
    ).toString();
  }

  /// Keys are pasted, and pasting wraps. A key never contains whitespace, so
  /// every kind of it is removed rather than only the ends: a newline inside
  /// the value makes `HttpClient` reject the request as a format error, which
  /// used to surface as "the base URL is not a valid address".
  static String cleanKey(String? raw) => normalizeProviderKey(raw);

  /// Custom headers, minus the ones `HttpClient` cannot send. The rule is
  /// the config layer's, so the form and this read drop the same rows.
  static ({Map<String, String> headers, List<String> dropped}) cleanHeaders(
    Map<String, String> raw,
  ) => sanitizeRequestHeaders(raw);

  /// True when a body is a web page rather than an API answer: a login wall,
  /// a captive portal or a firewall that answers 200 with HTML.
  static bool looksLikeHtml(String body) {
    final head = body.trimLeft();
    if (head.isEmpty) return false;
    if (head.startsWith('<')) return true;
    return head.toLowerCase().contains('<!doctype html');
  }

  static String _short(Uri url) {
    final path = url.path.isEmpty ? '/' : url.path;
    final query = url.hasQuery ? '?${url.query}' : '';
    return '${url.host}$path$query';
  }

  /// Reads the model list out of the shapes gateways actually return.
  ///
  /// OpenAI and NewAPI: `{"object":"list","data":[{"id":...}]}`. Some
  /// gateways: a bare array, or `{"models":[...]}`. Their entries vary too:
  /// `id`, `model`, or a plain string; the label is `display_name`,
  /// `displayName` or `label`.
  static List<CustomProviderModel> parseModelList(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty || looksLikeHtml(trimmed)) return const [];
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
          ? entry['display_name'] ?? entry['displayName'] ?? entry['label']
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
    Duration timeout, {
    String? trustedFingerprint,
  }) async {
    X509Certificate? rejected;
    final client = createProviderHttpClient(
      trustedFingerprint: trustedFingerprint,
      connectionTimeout: timeout,
      onUntrustedCertificate: (certificate) => rejected = certificate,
    );
    try {
      final request = await client.getUrl(url).timeout(timeout);
      request.followRedirects = true;
      headers.forEach(request.headers.set);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close().timeout(timeout);
      final bytes = await response
          .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk))
          .timeout(timeout);
      // `allowMalformed`: a gateway that answers in GBK, or an HTML error
      // page, must not turn into "the base URL is not a valid address".
      return ProviderHttpAnswer(
        statusCode: response.statusCode,
        body: utf8.decode(bytes, allowMalformed: true),
      );
    } on HandshakeException catch (error) {
      // `close(force: true)` below runs before this rethrow leaves the
      // method; the certificate is retained in the exception itself.
      if (rejected != null) {
        throw ProviderTlsException(
          error.message,
          certificate: rejected!,
          problem: classifyProviderTlsFailure(error),
        );
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
}
