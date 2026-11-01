import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../platform/network.dart';
import '../ui/kit/kit_redact.dart';
import 'download_size.dart';

enum MobileDownloadChoice { unseen, offered, accepted, denied }

enum MobileDownloadDecisionKind { allowed, needsConsent, blocked, unavailable }

enum MobileDownloadReason {
  nonMobile,
  belowThreshold,
  accepted,
  firstOffer,
  offline,
  declined,
  unfinished,
  networkUnknown,
  sizeUnknown,
  storageUnavailable,
  closed,
}

class MobileDownloadDecision {
  const MobileDownloadDecision(this.kind, this.reason);
  final MobileDownloadDecisionKind kind;
  final MobileDownloadReason reason;
  bool get allowed => kind == MobileDownloadDecisionKind.allowed;
}

class MobileDownloadResult<T> {
  const MobileDownloadResult(this.decision, [this.value]);
  final MobileDownloadDecision decision;
  final T? value;
}

/// One owner per saved profile, obtained through ConsentOwners.mobileDownloads.
/// A persisted claim precedes the first prompt. Unknown network/size never
/// becomes a mobile signal or below-threshold proof. This is a start gate;
/// callers must separately cancel/pause an in-flight transfer on policy changes.
class MobileDownloadConsent {
  MobileDownloadConsent._(
    this._prefs,
    this._profileId,
    this._key,
    this._choice,
  );
  static const thresholdBytes = 50000000;
  final SharedPreferences _prefs;
  final String _profileId;
  final String _key;
  MobileDownloadChoice _choice;
  Future<void> _tail = Future.value();
  bool _closed = false;
  bool _storageAvailable = true;
  MobileDownloadChoice get choice => _choice;
  bool get storageAvailable => _storageAvailable && !_closed && _present;

  bool get _present => _hasProfile(_prefs, _profileId);

  static bool _hasProfile(SharedPreferences prefs, String id) {
    try {
      final raw = prefs.getString('oc.profiles');
      final profiles = raw == null ? null : jsonDecode(raw);
      return profiles is List &&
          profiles.any((profile) => profile is Map && profile['id'] == id);
    } catch (_) {
      return false;
    }
  }

  static Future<MobileDownloadConsent> load(
    SharedPreferences prefs, {
    required String profileId,
  }) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(profileId) ||
        KitRedact.text(profileId) != profileId) {
      throw ArgumentError('Expected an opaque saved profile ID');
    }
    final key = 'oc.mobileDownloadConsent.$profileId';
    try {
      await prefs.reload();
      if (!_hasProfile(prefs, profileId)) throw const FormatException();
      final raw = prefs.getString(key);
      if (raw == null) {
        return MobileDownloadConsent._(
          prefs,
          profileId,
          key,
          MobileDownloadChoice.unseen,
        );
      }
      if (raw.length > 512) throw const FormatException();
      final value = jsonDecode(raw);
      if (value is! Map ||
          value['version'] != 1 ||
          value['choice'] is! String) {
        throw const FormatException();
      }
      return MobileDownloadConsent._(
        prefs,
        profileId,
        key,
        MobileDownloadChoice.values.byName(value['choice'] as String),
      );
    } catch (_) {
      throw StateError('Consent storage unavailable');
    }
  }

  /// Claims an automatic offer once, before the UI presents it. Settings may
  /// revise an offered/denied answer. Supply NetworkBridge.current, not a cached
  /// UI snapshot, so every retry checks the current route.
  Future<MobileDownloadDecision> request({
    required DownloadSize size,
    required Future<NetworkReading> Function() readNetwork,
  }) => _serial(() => _request(size: size, readNetwork: readNetwork));

  Future<MobileDownloadDecision> _request({
    required DownloadSize size,
    required Future<NetworkReading> Function() readNetwork,
  }) async {
    if (_closed || !_present) return _unavailable(MobileDownloadReason.closed);
    if (!_storageAvailable) {
      return _unavailable(MobileDownloadReason.storageUnavailable);
    }
    NetworkReading network;
    try {
      network = await readNetwork();
    } catch (_) {
      return _unavailable(MobileDownloadReason.networkUnknown);
    }
    if (_closed || !_present) return _unavailable(MobileDownloadReason.closed);
    if (network.hasNoNetwork || network.status == NetworkStatus.offline) {
      return const MobileDownloadDecision(
        MobileDownloadDecisionKind.blocked,
        MobileDownloadReason.offline,
      );
    }
    if (network.status != NetworkStatus.online ||
        network.transport == NetworkTransport.unknown) {
      return _unavailable(MobileDownloadReason.networkUnknown);
    }
    if (network.transport != NetworkTransport.mobile) {
      return const MobileDownloadDecision(
        MobileDownloadDecisionKind.allowed,
        MobileDownloadReason.nonMobile,
      );
    }
    final bytes = size.bytes;
    if (bytes == null ||
        bytes < 0 ||
        size.kind == DownloadSizeKind.unknown ||
        size.kind == DownloadSizeKind.estimate ||
        (size.kind == DownloadSizeKind.lowerBound && bytes <= thresholdBytes)) {
      return _unavailable(MobileDownloadReason.sizeUnknown);
    }
    if (bytes <= thresholdBytes) {
      return const MobileDownloadDecision(
        MobileDownloadDecisionKind.allowed,
        MobileDownloadReason.belowThreshold,
      );
    }
    switch (_choice) {
      case MobileDownloadChoice.accepted:
        return const MobileDownloadDecision(
          MobileDownloadDecisionKind.allowed,
          MobileDownloadReason.accepted,
        );
      case MobileDownloadChoice.denied:
        return const MobileDownloadDecision(
          MobileDownloadDecisionKind.blocked,
          MobileDownloadReason.declined,
        );
      case MobileDownloadChoice.offered:
        return const MobileDownloadDecision(
          MobileDownloadDecisionKind.blocked,
          MobileDownloadReason.unfinished,
        );
      case MobileDownloadChoice.unseen:
        try {
          await _save(MobileDownloadChoice.offered);
        } catch (_) {
          return _unavailable(MobileDownloadReason.storageUnavailable);
        }
        if (_closed) return _unavailable(MobileDownloadReason.closed);
        return const MobileDownloadDecision(
          MobileDownloadDecisionKind.needsConsent,
          MobileDownloadReason.firstOffer,
        );
    }
  }

  /// Only invokes [operation] after fresh authorization. After displaying a
  /// prompt, await [answer] then call run again: accepting never starts work.
  /// Callback failures remain the operation owner's typed error responsibility.
  Future<MobileDownloadResult<T>> run<T>({
    required DownloadSize size,
    required Future<NetworkReading> Function() readNetwork,
    required Future<T> Function() operation,
  }) async {
    final started = await _serial(() async {
      final decision = await _request(size: size, readNetwork: readNetwork);
      if (!decision.allowed) return (decision: decision, future: null);
      if (_closed || !_present) {
        return (
          decision: _unavailable(MobileDownloadReason.closed),
          future: null,
        );
      }
      // Start while holding the owner queue, but do not hold it for the transfer.
      // Wrap failures so even an immediately failed operation is always observed.
      final future = Future<T>.sync(operation)
          .then<({T? value, Object? error, StackTrace? stack})>(
            (value) => (value: value, error: null, stack: null),
            onError: (Object error, StackTrace stack) =>
                (value: null, error: error, stack: stack),
          );
      return (decision: decision, future: future);
    });
    final outcome = await started.future;
    final operationError = outcome?.error;
    if (operationError != null) {
      Error.throwWithStackTrace(operationError, outcome!.stack!);
    }
    return MobileDownloadResult(started.decision, outcome?.value);
  }

  Future<void> answer({required bool allow}) => _serial(() async {
    _requireWritable();
    if (_choice != MobileDownloadChoice.offered) {
      throw StateError('Consent is not awaiting an answer');
    }
    await _save(
      allow ? MobileDownloadChoice.accepted : MobileDownloadChoice.denied,
    );
  });

  Future<void> changeFromSettings({required bool allow}) => _serial(() async {
    _requireWritable();
    await _save(
      allow ? MobileDownloadChoice.accepted : MobileDownloadChoice.denied,
    );
  });

  /// Call before the profile preference sweep. Drains writes, rejects stale
  /// owners, and never recreates the deleted record. Does not cancel transfers.
  Future<void> close() {
    _closed = true;
    return _tail;
  }

  static MobileDownloadDecision _unavailable(MobileDownloadReason reason) =>
      MobileDownloadDecision(MobileDownloadDecisionKind.unavailable, reason);
  void _requireWritable() {
    if (!storageAvailable) throw StateError('Consent storage unavailable');
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _save(MobileDownloadChoice choice) async {
    _requireWritable();
    try {
      final encoded = jsonEncode({'version': 1, 'choice': choice.name});
      if (!await _prefs.setString(_key, encoded)) {
        throw StateError('Consent write failed');
      }
      _choice = choice;
    } catch (_) {
      _storageAvailable = false;
      throw StateError('Consent storage unavailable');
    }
  }
}
