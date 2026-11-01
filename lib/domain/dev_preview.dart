/// Dev-server preview: finding local links in conversation text and deciding
/// which address the phone should actually load for a given server.
///
/// Pure Dart, no widgets. The rules live here so they are unit-testable and
/// so the chat, the conversation menu and the preview screen cannot disagree.
library;

/// A link to a server running on "this machine": `localhost`, `127.0.0.1`,
/// `0.0.0.0` or `::1`, with an explicit port.
class DevPreviewLink implements Comparable<DevPreviewLink> {
  const DevPreviewLink({
    required this.port,
    this.scheme = 'http',
    this.path = '/',
    this.query,
  });

  final int port;

  /// `http` or `https` exactly as written.
  final String scheme;

  /// Always starts with `/`.
  final String path;
  final String? query;

  /// The path and query, for building a target on another host.
  String get pathAndQuery => query == null ? path : '$path?$query';

  /// The identity the conversation's port list de-duplicates on.
  String get key => '$scheme:$port';

  @override
  int compareTo(DevPreviewLink other) => port.compareTo(other.port);

  @override
  bool operator ==(Object other) =>
      other is DevPreviewLink &&
      other.port == port &&
      other.scheme == scheme &&
      other.path == path &&
      other.query == query;

  @override
  int get hashCode => Object.hash(port, scheme, path, query);

  @override
  String toString() => 'DevPreviewLink($scheme $port $pathAndQuery)';

  static const _hosts = {'localhost', '127.0.0.1', '0.0.0.0', '::1', '[::1]'};

  /// [value] as a local link, or null when it is anything else: another
  /// host, another scheme, a missing or impossible port, or embedded
  /// credentials. Null means "not ours": the caller sends it on through
  /// `openExternalLink` unchanged.
  static DevPreviewLink? parse(String? value) {
    if (value == null) return null;
    final text = value.trim();
    if (text.isEmpty || text.length > 2048) return null;
    final Uri uri;
    try {
      uri = Uri.parse(text);
    } on FormatException {
      return null;
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;
    if (uri.userInfo.isNotEmpty) return null;
    if (!_hosts.contains(uri.host.toLowerCase())) return null;
    if (!uri.hasPort || uri.port < 1 || uri.port > 65535) return null;
    return DevPreviewLink(
      port: uri.port,
      scheme: scheme,
      path: uri.path.isEmpty ? '/' : uri.path,
      query: uri.hasQuery && uri.query.isNotEmpty ? uri.query : null,
    );
  }

  static final _inText = RegExp(
    r'''https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]):\d{1,5}[^\s<>()\[\]`'"]*''',
    caseSensitive: false,
  );

  /// Every local link written in [text], in order, trailing punctuation
  /// left out.
  static List<DevPreviewLink> scan(String text) {
    final found = <DevPreviewLink>[];
    for (final match in _inText.allMatches(text)) {
      var raw = match.group(0)!;
      raw = raw.replaceFirst(RegExp(r'''[.,;:!?'"*_~]+$'''), '');
      final link = parse(raw);
      if (link != null) found.add(link);
    }
    return found;
  }

  /// The links from [texts] (oldest first), newest port first, one per
  /// scheme and port, at most [limit].
  static List<DevPreviewLink> recent(Iterable<String> texts, {int limit = 5}) {
    final seen = <String>{};
    final out = <DevPreviewLink>[];
    final all = <DevPreviewLink>[for (final text in texts) ...scan(text)];
    for (final link in all.reversed) {
      if (seen.add(link.key)) out.add(link);
      if (out.length >= limit) break;
    }
    return out;
  }
}

/// Why a link cannot be shown for the connected server.
enum DevPreviewBlock {
  /// No saved server (or a private lease): there is no address to rewrite to.
  noServer,

  /// The server's address has no usable host.
  noHost,
}

/// Where a link opens.
enum DevPreviewRoute {
  /// The phone's own server: loopback in the phone's network namespace.
  phone,

  /// A remote server: the link's host replaced by the server's host.
  remote,

  /// Cannot be shown; [DevPreviewTarget.block] says why.
  blocked,
}

/// What the preview loads for one [DevPreviewLink] on one server.
class DevPreviewTarget {
  const DevPreviewTarget._(this.route, this.uri, this.block, this.host);

  final DevPreviewRoute route;

  /// The address to load; null when [route] is blocked.
  final Uri? uri;
  final DevPreviewBlock? block;

  /// The server host shown in plain words for a remote target.
  final String? host;

  bool get isRemote => route == DevPreviewRoute.remote;

  /// A remote dev server must listen on 0.0.0.0 (all interfaces) to be seen
  /// from the phone; the preview says so.
  bool get needsAllInterfaces => isRemote;

  static bool _onThisPhone(String serverBaseUrl) {
    final host = Uri.tryParse(serverBaseUrl.trim())?.host ?? '';
    return host.isNotEmpty && isLoopbackHost(host);
  }

  static bool isLoopbackHost(String host) {
    final h = host.toLowerCase();
    return h == 'localhost' ||
        h == '::1' ||
        h == '[::1]' ||
        h == '0.0.0.0' ||
        h.startsWith('127.');
  }

  /// Resolves [link] for the connected server.
  ///
  /// - [serverBaseUrl] null, or [leased] true (a runtime-only private
  ///   transport) to another machine: blocked, nothing to rewrite to. A
  ///   leased transport to this phone's loopback (an agent such as Claude
  ///   Code in the in-app Linux) is still this phone: it opens there.
  /// - A loopback server (the in-app Ubuntu): the link opens on the phone's
  ///   own loopback, with `0.0.0.0` written as `127.0.0.1`.
  /// - Any other server: the same scheme, path and port on the server's
  ///   host.
  factory DevPreviewTarget.resolve(
    DevPreviewLink link, {
    required String? serverBaseUrl,
    bool leased = false,
  }) {
    if (serverBaseUrl == null ||
        serverBaseUrl.trim().isEmpty ||
        (leased && !_onThisPhone(serverBaseUrl))) {
      return const DevPreviewTarget._(
        DevPreviewRoute.blocked,
        null,
        DevPreviewBlock.noServer,
        null,
      );
    }
    Uri? server;
    try {
      server = Uri.parse(serverBaseUrl.trim());
    } on FormatException {
      server = null;
    }
    final host = server?.host ?? '';
    if (host.isEmpty) {
      return const DevPreviewTarget._(
        DevPreviewRoute.blocked,
        null,
        DevPreviewBlock.noHost,
        null,
      );
    }
    final remote = !isLoopbackHost(host);
    final target = Uri(
      scheme: link.scheme,
      host: remote ? host : '127.0.0.1',
      port: link.port,
      path: link.path,
      query: link.query,
    );
    return DevPreviewTarget._(
      remote ? DevPreviewRoute.remote : DevPreviewRoute.phone,
      target,
      null,
      remote ? host : null,
    );
  }
}

/// Whether the preview may load [target] when it was opened for [origin]:
/// the same host and port only. Everything else leaves through
/// `openExternalLink`.
bool devPreviewMayLoad(Uri target, Uri origin) {
  final scheme = target.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return false;
  if (target.userInfo.isNotEmpty) return false;
  return target.host.toLowerCase() == origin.host.toLowerCase() &&
      target.port == origin.port;
}
