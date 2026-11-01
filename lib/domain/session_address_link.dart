import '../ui/kit/kit_redact.dart';
import 'session_handoff.dart';

/// Safe categories only: neither errors nor model diagnostics retain link data.
enum SessionAddressFailureCode {
  unavailable,
  invalidLink,
  tooLarge,
  credentials,
  consentRequired,
  privateRouteRequired,
  unreachable,
  timedOut,
  tlsRejected,
  redirectsRejected,
  accessDenied,
  invalidDescriptor,
  instanceMismatch,
  bindingRequired,
  ambiguousProfile,
  profileMissing,
  storage,
  signInRequired,
  unsafeLookup,
  sessionMissing,
  cancelled,
}

class SessionAddressFailure implements Exception {
  const SessionAddressFailure(this.code);
  final SessionAddressFailureCode code;

  @override
  String toString() => 'SessionAddressFailure(${code.name})';
}

/// A credential-free locator, never authority to contact or open a server.
/// Parsing has no I/O. Callers must separately enforce the disabled capability,
/// disclosure/contact consent, private transport, binding and scoped lookup.
class SessionAddressLink {
  const SessionAddressLink._(this.origin, this.instanceId, this.sessionId);

  static const maxLength = 1024;
  final String origin;
  final String instanceId;
  final String sessionId;

  static final _envelope = RegExp(
    r'^opencode-mobile://session/v2\?([^#]+)$',
    caseSensitive: false,
  );
  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  static final _label = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');

  static SessionAddressLink? parse(Object? raw) {
    try {
      return require(raw);
    } on SessionAddressFailure {
      return null;
    }
  }

  static SessionAddressLink require(Object? raw) {
    if (raw is! String) _fail(SessionAddressFailureCode.invalidLink);
    _boundedAscii(raw);
    _rejectSecrets(raw);
    // URI parsers can repair malformed escapes and normalize paths. Check the
    // exact envelope and escapes before decoding, with no recursive decoding.
    if (RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(raw)) {
      _fail(SessionAddressFailureCode.invalidLink);
    }
    final match = _envelope.firstMatch(raw);
    if (match == null || match.end != raw.length) {
      _fail(SessionAddressFailureCode.invalidLink);
    }
    // Only scheme/host are case insensitive; the version path is exact.
    if (!raw.substring(0, raw.indexOf('?')).endsWith('/v2')) {
      _fail(SessionAddressFailureCode.invalidLink);
    }
    final fields = <String, String>{};
    for (final pair in match.group(1)!.split('&')) {
      final at = pair.indexOf('=');
      if (at <= 0 || pair.indexOf('=', at + 1) >= 0) {
        _fail(SessionAddressFailureCode.invalidLink);
      }
      final key = pair.substring(0, at);
      if (!const {'server', 'instance', 'session'}.contains(key) ||
          fields.containsKey(key)) {
        _fail(SessionAddressFailureCode.invalidLink);
      }
      try {
        final value = Uri.decodeQueryComponent(pair.substring(at + 1));
        _rejectSecrets(value);
        if (value.isEmpty || value.codeUnits.any((c) => c < 0x21 || c > 0x7e)) {
          _fail(SessionAddressFailureCode.invalidLink);
        }
        fields[key] = value;
      } on FormatException {
        _fail(SessionAddressFailureCode.invalidLink);
      }
    }
    if (fields.length != 3) _fail(SessionAddressFailureCode.invalidLink);
    return _validated(
      fields['server']!,
      fields['instance']!,
      fields['session']!,
    );
  }

  static SessionAddressLink build({
    required String origin,
    required String instanceId,
    required String sessionId,
    required bool includeServerAddress,
  }) {
    if (!includeServerAddress) _fail(SessionAddressFailureCode.consentRequired);
    final link = _validated(origin, instanceId, sessionId);
    _boundedAscii(link.encode());
    return link;
  }

  static SessionAddressLink _validated(
    String origin,
    String instance,
    String session,
  ) {
    _boundedAscii(instance);
    _boundedAscii(session);
    _rejectSecrets(instance);
    _rejectSecrets(session);
    if (!validInstance(instance) ||
        !SessionResumeCommand.isSafeIdentifier(session)) {
      _fail(SessionAddressFailureCode.invalidLink);
    }
    final normalizedInstance = instance.toLowerCase();
    _rejectSecrets(normalizedInstance);
    return SessionAddressLink._(
      normalizeOrigin(origin),
      normalizedInstance,
      session,
    );
  }

  static bool validInstance(String value) =>
      _uuid.hasMatch(value) && !value.endsWith('\n');

  static String normalizeOrigin(String value) {
    _boundedAscii(value);
    _rejectSecrets(value);
    if (value.contains('@')) _fail(SessionAddressFailureCode.credentials);
    final match = RegExp(
      r'^https://([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?$',
      caseSensitive: false,
    ).firstMatch(value);
    if (match == null || match.end != value.length) {
      _fail(SessionAddressFailureCode.invalidLink);
    }
    final host = match.group(1)!.toLowerCase();
    final labels = host.split('.');
    if (host.length > 253 ||
        labels.length != 4 ||
        labels[2] != 'ts' ||
        labels[3] != 'net' ||
        labels.any((label) => !_label.hasMatch(label))) {
      _fail(SessionAddressFailureCode.invalidLink);
    }
    final port = match.group(2) == null ? 443 : int.parse(match.group(2)!);
    if (port < 1 || port > 65535) _fail(SessionAddressFailureCode.invalidLink);
    final normalized = 'https://$host${port == 443 ? '' : ':$port'}';
    _rejectSecrets(normalized);
    return normalized;
  }

  String encode() {
    // A credential can become known after construction; never serialize it.
    _rejectSecrets(origin);
    _rejectSecrets(instanceId);
    _rejectSecrets(sessionId);
    return Uri(
      scheme: 'opencode-mobile',
      host: 'session',
      path: '/v2',
      queryParameters: {
        'server': origin,
        'instance': instanceId,
        'session': sessionId,
      },
    ).toString();
  }

  static void _boundedAscii(String value) {
    if (value.length > maxLength) _fail(SessionAddressFailureCode.tooLarge);
    if (value.isEmpty || value.codeUnits.any((c) => c < 0x21 || c > 0x7e)) {
      _fail(SessionAddressFailureCode.invalidLink);
    }
  }

  static void _rejectSecrets(String value) {
    if (KitRedact.containsSecret(value)) {
      _fail(SessionAddressFailureCode.credentials);
    }
  }

  static Never _fail(SessionAddressFailureCode code) =>
      throw SessionAddressFailure(code);

  @override
  String toString() => 'SessionAddressLink';

  @override
  bool operator ==(Object other) =>
      other is SessionAddressLink &&
      origin == other.origin &&
      instanceId == other.instanceId &&
      sessionId == other.sessionId;

  @override
  int get hashCode => Object.hash(origin, instanceId, sessionId);
}
