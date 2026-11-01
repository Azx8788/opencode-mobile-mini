import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/kit/kit_redact.dart';

/// The exact request and proposed standing-grant scope plus its session context.
/// Pass the gateway request's `patterns` AND `always` (as [alwaysPatterns]);
/// never substitute display text or a redacted description for these values.
class PermissionConsentScope {
  PermissionConsentScope({
    required this.sessionID,
    required this.permission,
    required List<String> patterns,
    List<String> alwaysPatterns = const [],
  }) : patterns = List.unmodifiable(patterns),
       alwaysPatterns = List.unmodifiable(alwaysPatterns);

  final String sessionID;
  final String permission;
  final List<String> patterns;
  final List<String> alwaysPatterns;

  String get _key => _digest([
    permission,
    [...patterns]..sort(),
    [...alwaysPatterns]..sort(),
  ]);
}

enum PermissionOfferDecision { notOffered, offered, accepted, declined }

class RepeatedPermissionStatus {
  const RepeatedPermissionStatus({
    this.offerAlwaysAllow = false,
    this.distinctAsks = 0,
    this.decision = PermissionOfferDecision.notOffered,
    this.storageAvailable = true,
  });

  /// A one-shot invitation only. This never authorizes a gateway reply.
  final bool offerAlwaysAllow;
  final int distinctAsks;
  final PermissionOfferDecision decision;
  final bool storageAvailable;

  /// Use a localized Settings explanation: permission is still asked each time.
  bool get explainDeclinedInSettings =>
      decision == PermissionOfferDecision.declined;
}

/// One owner per profile. Remembers invitation history, never permission grants.
///
/// Call [observe] on a real pending request, with the current gateway's
/// `persistentPermissionGrants` capability. On the third identical distinct
/// ask, the invitation is durably claimed before returning it. Reconnect
/// replays and later requests cannot offer it again, including after restart.
/// Invitation history is per profile and exact permission/patterns/always scope,
/// across sessions. Session IDs only distinguish request IDs for replay dedupe.
/// The caller still confirms scope/duration and explicitly replies through the
/// domain gateway. Only after that succeeds may it record `accepted`.
/// Never derive a grant's scope or duration from this invitation history.
///
/// Hashes exact scope/request values before storage; no request copy or
/// credential plaintext is stored. Profile deletion's `oc.*.<profileId>` sweep
/// removes this history. Corrupt/unwritable or full storage suppresses offers.
class RepeatedPermissionConsent {
  RepeatedPermissionConsent(this._preferences, {required String profileId})
    : storageKey = _storageKey(profileId);

  final SharedPreferences _preferences;
  final String storageKey;
  Future<void> _tail = Future.value();
  bool _blocked = false;
  bool _loaded = false;
  static const _limit = 256;
  static const _maxStoredCharacters = 128 * 1024;

  static String _storageKey(String profileId) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(profileId) ||
        KitRedact.text(profileId) != profileId) {
      // Do not attach the rejected value: it could contain credentials.
      throw ArgumentError('Invalid profile identifier');
    }
    return 'oc.permissionConsent.$profileId';
  }

  Future<RepeatedPermissionStatus> observe({
    required PermissionConsentScope scope,
    required String requestID,
    required bool supportsPersistentGrants,
  }) => _serialized(() async {
    if (!supportsPersistentGrants ||
        requestID.isEmpty ||
        scope.sessionID.isEmpty ||
        scope.permission.isEmpty) {
      return const RepeatedPermissionStatus();
    }
    final entries = _read();
    if (entries == null) return _unavailable;
    final key = scope._key;
    final entry =
        entries[key] ?? _Entry([], PermissionOfferDecision.notOffered);
    if (entry.decision != PermissionOfferDecision.notOffered) {
      return entry.status();
    }
    final request = _digest([scope.sessionID, requestID]);
    if (entry.requests.contains(request)) return entry.status();
    if (!entries.containsKey(key) && entries.length >= _limit) {
      return _unavailable;
    }
    entry.requests.add(request);
    final offer = entry.requests.length == 3;
    if (offer) entry.decision = PermissionOfferDecision.offered;
    entries[key] = entry;
    if (!await _write(entries)) return _unavailable;
    return entry.status(offer: offer);
  });

  /// Read remembered state for a Settings row without consuming an invitation.
  Future<RepeatedPermissionStatus> status(PermissionConsentScope scope) =>
      _serialized(() async {
        final entries = _read();
        if (entries == null) return _unavailable;
        return entries[scope._key]?.status() ??
            const RepeatedPermissionStatus();
      });

  /// Records only the invitation's answer. Does not create a permission grant.
  /// `accepted: true` is for a successful explicit gateway reply; `false` means
  /// the user declined the invitation and should keep seeing ordinary asks.
  Future<RepeatedPermissionStatus> recordDecision(
    PermissionConsentScope scope, {
    required bool accepted,
  }) => _serialized(() async {
    final entries = _read();
    if (entries == null) return _unavailable;
    final entry = entries[scope._key];
    if (entry == null) return const RepeatedPermissionStatus();
    if (entry.decision != PermissionOfferDecision.offered) {
      return entry.status();
    }
    entry.decision = accepted
        ? PermissionOfferDecision.accepted
        : PermissionOfferDecision.declined;
    if (!await _write(entries)) return _unavailable;
    return entry.status();
  });

  /// How many invitations were turned down or left unanswered, for the
  /// Settings row that explains them (those actions are still asked each
  /// time). Null when storage cannot be read.
  Future<int?> declinedCount() => _serialOr<int?>(() async {
    final entries = _read();
    if (entries == null) return null;
    return entries.values.where((entry) => entry._notAccepted).length;
  }, null);

  /// Forgets every invitation that was turned down or left unanswered, so
  /// each is offered again after three more identical asks. Accepted ones
  /// stay: their grants live in the server's saved rules. False when
  /// storage refused.
  Future<bool> forgetDeclined() => _serialOr<bool>(() async {
    final entries = _read();
    if (entries == null) return false;
    entries.removeWhere((_, entry) => entry._notAccepted);
    return _write(entries);
  }, false);

  /// Stops accepting changes and waits for a write in flight, so the profile
  /// deletion sweep that follows removes this history for good.
  Future<void> close() {
    final drained = _tail;
    _blocked = true;
    return drained;
  }

  static const _unavailable = RepeatedPermissionStatus(storageAvailable: false);

  Future<RepeatedPermissionStatus> _serialized(
    Future<RepeatedPermissionStatus> Function() action,
  ) => _serialOr(action, _unavailable);

  Future<T> _serialOr<T>(Future<T> Function() action, T fallback) {
    final result = _tail.then((_) async {
      if (_blocked) return fallback;
      try {
        if (!_loaded) {
          // SharedPreferences updates its cache even if a write is refused.
          // A new owner must start from durable storage, not that cache.
          await _preferences.reload();
          _loaded = true;
        }
        return await action();
      } catch (_) {
        _blocked = true;
        return fallback;
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Map<String, _Entry>? _read() {
    if (_blocked) return null;
    try {
      final raw = _preferences.getString(storageKey);
      if (raw == null) return {};
      if (raw.length > _maxStoredCharacters) throw const FormatException();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (json['version'] != 1) throw const FormatException();
      final rows = json['entries'] as Map<String, dynamic>;
      if (rows.length > _limit) throw const FormatException();
      final result = <String, _Entry>{};
      for (final row in rows.entries) {
        if (!_isDigest(row.key)) throw const FormatException();
        final value = row.value as Map<String, dynamic>;
        final requests = (value['requests'] as List).cast<String>();
        final decision = PermissionOfferDecision.values.byName(
          value['decision'] as String,
        );
        if (requests.isEmpty ||
            requests.length > 3 ||
            requests.any((id) => !_isDigest(id)) ||
            requests.toSet().length != requests.length ||
            (requests.length == 3) !=
                (decision != PermissionOfferDecision.notOffered)) {
          throw const FormatException();
        }
        result[row.key] = _Entry([...requests], decision);
      }
      return result;
    } catch (_) {
      _blocked = true;
      return null;
    }
  }

  Future<bool> _write(Map<String, _Entry> entries) async {
    try {
      final encoded = jsonEncode({
        'version': 1,
        'entries': entries.map(
          (key, entry) => MapEntry(key, {
            'requests': entry.requests,
            'decision': entry.decision.name,
          }),
        ),
      });
      final safe = KitRedact.text(encoded);
      // If a registered secret matches a digest, suppress instead of corrupting
      // identity or writing content the redactor considers unsafe.
      if (safe != encoded || !await _preferences.setString(storageKey, safe)) {
        _blocked = true;
        return false;
      }
      return true;
    } catch (_) {
      _blocked = true;
      return false;
    }
  }
}

class _Entry {
  _Entry(this.requests, this.decision);
  final List<String> requests;
  PermissionOfferDecision decision;

  bool get _notAccepted =>
      decision == PermissionOfferDecision.declined ||
      decision == PermissionOfferDecision.offered;

  RepeatedPermissionStatus status({bool offer = false}) =>
      RepeatedPermissionStatus(
        offerAlwaysAllow: offer,
        distinctAsks: requests.length,
        decision: decision,
      );
}

String _digest(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();
bool _isDigest(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
