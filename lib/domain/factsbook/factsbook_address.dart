/// Where a FactsBook node may be reached. The node binds to loopback; a
/// paired phone reaches it over loopback, the local network or a private
/// overlay (a tailnet). Anything else is refused: the bearer token travels
/// in clear text, so only a private path is acceptable (F42).
abstract final class FactsBookAddress {
  /// Parses what a person typed ("127.0.0.1:8787", "http://192.168.1.20:8787",
  /// "phone.local:8787") into a base URL, or null when it is not a private
  /// address the app will send a credential to.
  static Uri? parse(String input) {
    var text = input.trim();
    if (text.isEmpty || text.length > 200) return null;
    if (!text.contains('://')) text = 'http://$text';
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.fragment.isNotEmpty) {
      return null;
    }
    if (!isPrivateHost(uri.host)) return null;
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 8787);
    return Uri(scheme: uri.scheme, host: uri.host, port: port);
  }

  /// Loopback, RFC 1918, link-local, the 100.64.0.0/10 overlay range, and the
  /// names `.local` and `.ts.net`.
  static bool isPrivateHost(String host) {
    final lower = host.toLowerCase();
    if (lower == 'localhost' || lower == '::1' || lower == '[::1]') return true;
    if (lower.endsWith('.local') || lower.endsWith('.ts.net')) return true;
    final parts = lower.split('.');
    if (parts.length != 4) return false;
    final octets = [for (final p in parts) int.tryParse(p)];
    if (octets.any((o) => o == null || o < 0 || o > 255)) return false;
    final a = octets[0]!;
    final b = octets[1]!;
    return a == 127 ||
        a == 10 ||
        (a == 192 && b == 168) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 169 && b == 254) ||
        (a == 100 && b >= 64 && b <= 127);
  }
}
