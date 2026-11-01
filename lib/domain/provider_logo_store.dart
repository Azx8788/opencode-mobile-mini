import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'mark_catalog.dart';

/// One fetched logo response, reduced to what the store checks.
class ProviderLogoResponse {
  const ProviderLogoResponse({
    required this.status,
    required this.contentType,
    required this.body,
  });

  final int status;
  final String? contentType;
  final Uint8List body;
}

/// Fetches [url]; null on any network failure. The store enforces the size
/// and type limits again on what comes back, so a fake fetcher is held to
/// the same rules as the real one.
typedef ProviderLogoFetch = Future<ProviderLogoResponse?> Function(Uri url);

/// Where logos live on disk; null means "memory only".
typedef ProviderLogoDirectory = Future<Directory?> Function();

/// A provider id reduced to a safe file/URL slug (`[a-z0-9._-]`, no `..`,
/// at most 64 characters, not starting with `.`), or null when the id
/// cannot be one. The slug is the only part of the logo URL that comes from
/// outside the app, and it is only ever used after this check.
String? providerLogoSlug(String providerID) {
  final id = providerID.trim().toLowerCase();
  if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$').hasMatch(id)) return null;
  if (id.contains('..')) return null;
  return id;
}

/// The app-authored models.dev monochrome logo URL, or null for an id that
/// is not a safe slug.
Uri? providerLogoUrl(String providerID) {
  final slug = providerLogoSlug(providerID);
  if (slug == null) return null;
  return Uri.https('models.dev', '/logos/$slug.svg');
}

/// models.dev answers an unknown provider id with one generic "sparkle" SVG
/// rather than a 404. This is the MD5 of that body as of 2026-10-13: a body
/// with this digest means "no logo for this provider" and shows initials.
/// If models.dev ever changes the sparkle, the only effect is that the new
/// sparkle is drawn as a logo until this constant is updated; nothing fails.
const String modelsDevDefaultLogoMd5 = 'f14bc05bbdcf56f04949d1df83e67300';

/// Largest logo body accepted, in bytes.
const int providerLogoMaxBytes = 64 * 1024;

/// How long a cached logo is used before a refresh is attempted.
const Duration providerLogoRefreshAfter = Duration(days: 7);

/// How long a failed fetch (offline, 5xx) is not retried in this session.
const Duration _failureBackoff = Duration(minutes: 10);

/// Provider logos (SVG text): a bundled mark first, the models.dev download
/// as the fallback, initials (null) last.
///
/// A provider with a bundled mark (`assets/marks/`, see [providerMarkSlug])
/// is answered from the app bundle with no network request. Every other
/// provider is fetched as below.
///
/// Fetch-once, keep-on-disk store for the fallback logos (SVG text).
///
/// A logo is fetched at most weekly per provider. A fresh cache file is
/// returned without touching the network; a stale one is returned if the
/// refresh fails; with nothing cached and no network the answer is null and
/// the caller shows initials. "No logo" (models.dev's generic sparkle) is
/// remembered on disk too, as an empty `.none` marker with the same weekly
/// refresh.
class ProviderLogoStore {
  ProviderLogoStore({
    ProviderLogoFetch? fetch,
    ProviderLogoDirectory? directory,
    DateTime Function()? now,
    String defaultLogoMd5 = modelsDevDefaultLogoMd5,
    Future<String> Function(String assetPath)? loadBundled,
  }) : _loadBundled = loadBundled ?? rootBundle.loadString,
       _defaultMd5 = defaultLogoMd5,
       _fetch = fetch ?? _dioFetch,
       _directory = directory ?? _supportLogoDirectory,
       _now = now ?? DateTime.now;

  /// The app's store.
  static final ProviderLogoStore shared = ProviderLogoStore();

  final Future<String> Function(String assetPath) _loadBundled;
  final ProviderLogoFetch _fetch;
  final ProviderLogoDirectory _directory;
  final DateTime Function() _now;
  final String _defaultMd5;

  final Map<String, Future<String?>> _inFlight = {};
  final Map<String, String?> _resolved = {};
  final Map<String, DateTime> _failedAt = {};
  Future<Directory?>? _dirFuture;

  /// The logo's SVG text, or null when the provider has none, the id is not
  /// a safe slug, or nothing could be fetched or read.
  Future<String?> svgFor(String providerID) {
    final slug = providerLogoSlug(providerID);
    if (slug == null) return Future.value(null);
    if (_resolved.containsKey(slug)) return Future.value(_resolved[slug]);
    return _inFlight[slug] ??= _bundledOrFetched(slug).whenComplete(() {
      // A block body: returning remove()'s future would make this wait on
      // itself.
      _inFlight.remove(slug);
    });
  }

  Future<String?> _bundledOrFetched(String slug) async {
    final mark = providerMarkSlug(slug);
    if (mark != null) {
      try {
        return _remember(slug, await _loadBundled(markAssetPath(mark)));
      } catch (_) {
        // A mark that cannot be read falls through to the download.
      }
    }
    return _resolve(slug);
  }

  Future<String?> _resolve(String slug) async {
    try {
      final failedAt = _failedAt[slug];
      final dir = await (_dirFuture ??= _openDirectory());
      final svgFile = dir == null ? null : File('${dir.path}/$slug.svg');
      final noneFile = dir == null ? null : File('${dir.path}/$slug.none');

      String? cached;
      var fresh = false;
      if (svgFile != null && await svgFile.exists()) {
        cached = await svgFile.readAsString();
        fresh = _isFresh(await svgFile.lastModified());
      } else if (noneFile != null && await noneFile.exists()) {
        fresh = _isFresh(await noneFile.lastModified());
      }
      if (fresh) return _remember(slug, cached);
      if (failedAt != null && _now().difference(failedAt) < _failureBackoff) {
        return cached;
      }

      final response = await _fetchSafely(slug);
      if (response == null) {
        _failedAt[slug] = _now();
        return cached;
      }
      _failedAt.remove(slug);
      final body = response.body;
      if (md5.convert(body).toString() == _defaultMd5) {
        if (svgFile != null && await svgFile.exists()) await svgFile.delete();
        await noneFile?.writeAsBytes(const []);
        return _remember(slug, null);
      }
      final text = utf8.decode(body, allowMalformed: false);
      if (svgFile != null) {
        await svgFile.writeAsString(text);
        if (noneFile != null && await noneFile.exists()) {
          await noneFile.delete();
        }
      }
      return _remember(slug, text);
    } catch (_) {
      _failedAt[slug] = _now();
      return null;
    }
  }

  String? _remember(String slug, String? svg) {
    _resolved[slug] = svg;
    return svg;
  }

  bool _isFresh(DateTime modified) =>
      _now().difference(modified) < providerLogoRefreshAfter;

  Future<ProviderLogoResponse?> _fetchSafely(String slug) async {
    final url = providerLogoUrl(slug)!;
    final ProviderLogoResponse? response;
    try {
      response = await _fetch(url);
    } catch (_) {
      return null;
    }
    if (response == null || response.status != 200) return null;
    if (response.body.isEmpty || response.body.length > providerLogoMaxBytes) {
      return null;
    }
    final type = (response.contentType ?? '').toLowerCase();
    if (!type.contains('image/svg')) return null;
    if (md5.convert(response.body).toString() == _defaultMd5) {
      return response;
    }
    final String text;
    try {
      text = utf8.decode(response.body);
    } on FormatException {
      return null;
    }
    if (!_looksLikePlainSvg(text)) return null;
    return response;
  }

  Future<Directory?> _openDirectory() async {
    try {
      return await _directory();
    } catch (_) {
      return null;
    }
  }
}

/// A logo is drawn as a picture only: anything that carries script, embedded
/// HTML or an image reference is refused before it reaches the renderer.
bool _looksLikePlainSvg(String text) {
  final lower = text.toLowerCase();
  if (!lower.contains('<svg')) return false;
  for (final banned in const [
    '<script',
    '<foreignobject',
    '<image',
    '<use',
    'javascript:',
    'onload=',
    'onclick=',
    '<!entity',
  ]) {
    if (lower.contains(banned)) return false;
  }
  return true;
}

Future<Directory?> _supportLogoDirectory() async {
  final support = await getApplicationSupportDirectory();
  return Directory('${support.path}/provider_logos').create(recursive: true);
}

Future<ProviderLogoResponse?> _dioFetch(Uri url) async {
  final cancel = CancelToken();
  try {
    final response = await Dio().getUri<List<int>>(
      url,
      cancelToken: cancel,
      options: Options(
        responseType: ResponseType.bytes,
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
        followRedirects: false,
        validateStatus: (_) => true,
      ),
      onReceiveProgress: (received, _) {
        if (received > providerLogoMaxBytes) cancel.cancel('too large');
      },
    );
    return ProviderLogoResponse(
      status: response.statusCode ?? 0,
      contentType: response.headers.value(Headers.contentTypeHeader),
      body: Uint8List.fromList(response.data ?? const []),
    );
  } catch (_) {
    return null;
  }
}
