import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/while_away.dart';
import '../ui/kit/kit_redact.dart';

/// No exception text leaves an inverse operation. An uncertain attempt is never
/// retried automatically, including after process death.
enum AutomaticUndoResult { unavailable, undone, failed, unconfirmed }

/// Local history of observed automatic acts; never initiates automation.
///
/// Own exactly one instance per profile, above the Inbox and inline notices.
/// Record only after an existing producer confirms its act. Event IDs identify
/// occurrences, not action kinds: repeated delivery deduplicates, a new act does
/// not. History retains the newest [maxEntries] acts, including acknowledgements.
/// Call [deleteProfileData] BEFORE the owner's profile deletion sweep. Dispose
/// on owner shutdown; disposal alone deliberately does not erase history.
class AutomaticActivityController extends ChangeNotifier {
  AutomaticActivityController({
    required this.preferences,
    required this.profileId,
    required this.isProfilePresent,
  }) {
    // Keys contain only an app-authored opaque profile ID, never server input.
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(profileId) ||
        KitRedact.containsSecret(profileId)) {
      throw ArgumentError('An opaque profile ID is required');
    }
    if (isProfilePresent()) _load();
  }

  static const maxEntries = 200;
  static const _maxBlobLength = 512000;

  static final _shared =
      Map<
        SharedPreferences,
        Map<String, AutomaticActivityController>
      >.identity();

  /// The one shared history of [profileId] on [preferences], so every
  /// connection (the app's and an isolated task's) and the Inbox read and
  /// write the same instance: never a second writer for one key. Null for
  /// an ID that is not an opaque app-authored profile ID.
  static AutomaticActivityController? forProfile(
    SharedPreferences preferences,
    String profileId, {
    required bool Function() isProfilePresent,
  }) {
    final byProfile = _shared[preferences] ??= {};
    final existing = byProfile[profileId];
    if (existing != null) return existing;
    try {
      return byProfile[profileId] = AutomaticActivityController(
        preferences: preferences,
        profileId: profileId,
        isProfilePresent: isProfilePresent,
      );
    } on ArgumentError {
      return null;
    }
  }

  /// Permanently closes and erases the shared history after profile removal
  /// commits. Use prepareForDeletion to drain without losing history first.
  /// False when the platform refused the removal.
  static Future<bool> closeProfile(
    SharedPreferences preferences,
    String profileId,
  ) async {
    final byProfile = _shared[preferences];
    final controller = byProfile?[profileId];
    if (controller == null) return true;
    try {
      return await controller.deleteProfileData();
    } finally {
      if (identical(byProfile?[profileId], controller)) {
        byProfile!.remove(profileId);
      }
      controller.dispose();
    }
  }

  /// Forgets every shared history; tests only.
  @visibleForTesting
  static void resetShared() {
    for (final byProfile in _shared.values) {
      for (final controller in byProfile.values) {
        controller.dispose();
      }
    }
    _shared.clear();
  }

  final SharedPreferences preferences;
  final String profileId;
  final bool Function() isProfilePresent;
  List<AutomaticAct> _acts = const [];
  final _inverses = <String, Future<bool> Function()>{};
  final _pendingUndo = <String>{};
  Future<void> _tail = Future<void>.value();
  Future<bool>? _deletion;
  bool _disposed = false;
  bool _closed = false;
  bool _preparingDeletion = false;
  bool _persistenceFailed = false;
  bool _corruptHistory = false;

  String get storageKey => 'oc.automaticActivity.$profileId';
  List<AutomaticAct> get acts => _acts;
  bool get persistenceFailed => _persistenceFailed;
  bool get corruptHistory => _corruptHistory;
  bool get _available => !_disposed && !_closed && isProfilePresent();
  bool get _accepting => _available && !_preparingDeletion;

  /// Avoids persisting directory names or URLs (which can carry credentials).
  String locationKey(String location) => _hash(location);

  List<AutomaticAct> forLocation(String location) => List.unmodifiable(
    _acts.where((act) => act.locationKey == locationKey(location)),
  );

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static String _summary(String value) {
    // Redact BEFORE flattening/truncation: headers and multiline secrets depend
    // on their original boundaries.
    final safe = KitRedact.text(
      value,
    ).replaceAll(RegExp(r'[\s\x00-\x1f\x7f]+'), ' ').trim();
    return String.fromCharCodes(safe.runes.take(400));
  }

  /// False means the observation could not be durably recorded. The caller can
  /// retry this SAME event ID; it must never repeat the original act to retry a
  /// history write. [undo] must return true only after confirming the inverse.
  /// It is memory-only, is offered once, and is never reconstructed on restart.
  Future<bool> record({
    required String eventId,
    required String location,
    required AutomaticActKind kind,
    required String summary,
    required DateTime occurredAt,
    String? sessionId,
    Future<bool> Function()? undo,
  }) {
    if (eventId.isEmpty || occurredAt.millisecondsSinceEpoch <= 0) {
      return Future.value(false);
    }
    final safeSummary = _summary(summary);
    if (safeSummary.isEmpty) return Future.value(false);
    final id = _hash(jsonEncode([location, eventId]));
    final safeSession =
        sessionId == null ||
            sessionId.isEmpty ||
            sessionId.length > 256 ||
            KitRedact.containsSecret(sessionId)
        ? null
        : KitRedact.text(sessionId);
    final act = AutomaticAct(
      id: id,
      locationKey: locationKey(location),
      kind: kind,
      summary: safeSummary,
      occurredAt: occurredAt.toUtc(),
      sessionId: safeSession,
    );
    return _enqueue(false, () async {
      if (_acts.any((entry) => entry.id == id)) return true;
      if (!await _save(_bounded([..._acts, act]))) return false;
      if (undo != null && _available && _acts.any((entry) => entry.id == id)) {
        _inverses[id] = undo;
        _notify();
      }
      return true;
    });
  }

  /// Acknowledges only these IDs, captured before entering the write queue.
  /// Acknowledgement hides history in the Inbox; it never marks work read.
  Future<bool> acknowledge(Iterable<String> ids) {
    final shown = ids.toSet();
    return _enqueue(false, () async {
      if (!_acts.any((act) => shown.contains(act.id) && !act.acknowledged)) {
        return true;
      }
      return _save([
        for (final act in _acts)
          shown.contains(act.id) ? act.copyWith(acknowledged: true) : act,
      ]);
    });
  }

  bool canUndo(String id) =>
      _accepting &&
      !_pendingUndo.contains(id) &&
      _inverses.containsKey(id) &&
      _acts.any((act) => act.id == id && !act.undoAttempted);

  Future<AutomaticUndoResult> undo(String id) {
    if (!canUndo(id)) return Future.value(AutomaticUndoResult.unavailable);
    _pendingUndo.add(id);
    _notify();
    final result = _enqueue(AutomaticUndoResult.unavailable, () async {
      final inverse = _inverses[id];
      if (inverse == null ||
          !_acts.any((act) => act.id == id && !act.undoAttempted)) {
        return AutomaticUndoResult.unavailable;
      }
      // Commit intent first. A crash after the remote effect cannot offer the
      // inverse again. A failed intent write performs no external operation.
      if (!await _save([
        for (final act in _acts)
          act.id == id ? act.copyWith(undoAttempted: true) : act,
      ])) {
        return AutomaticUndoResult.failed;
      }
      if (!_available) return AutomaticUndoResult.unavailable;
      _inverses.remove(id);
      try {
        if (!await inverse()) return AutomaticUndoResult.failed;
      } catch (_) {
        return AutomaticUndoResult.unconfirmed;
      }
      if (!_available) return AutomaticUndoResult.unconfirmed;
      final saved = await _save([
        for (final act in _acts)
          act.id == id ? act.copyWith(undone: true) : act,
      ]);
      return saved
          ? AutomaticUndoResult.undone
          : AutomaticUndoResult.unconfirmed;
    });
    return result.whenComplete(() {
      _pendingUndo.remove(id);
      _notify();
    });
  }

  Future<T> _enqueue<T>(T unavailable, Future<T> Function() action) {
    if (!_accepting) return Future.value(unavailable);
    final operation = _tail.then<T>((_) async {
      if (!_available) return unavailable;
      return action();
    });
    _tail = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  static List<AutomaticAct> _bounded(List<AutomaticAct> entries) {
    entries.sort((a, b) {
      final byTime = b.occurredAt.compareTo(a.occurredAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    return List.unmodifiable(entries.take(maxEntries));
  }

  Map<String, Object?> _encode(AutomaticAct act) => {
    'id': KitRedact.text(act.id),
    'location': KitRedact.text(act.locationKey),
    'kind': act.kind.name,
    'summary': _summary(act.summary),
    'at': act.occurredAt.millisecondsSinceEpoch,
    'session': act.sessionId == null ? null : KitRedact.text(act.sessionId!),
    'acknowledged': act.acknowledged,
    'undoAttempted': act.undoAttempted,
    'undone': act.undone,
  };

  Future<bool> _save(List<AutomaticAct> next) async {
    if (!_available) return false;
    try {
      if (!await preferences.setString(
        storageKey,
        jsonEncode({'version': 1, 'acts': next.map(_encode).toList()}),
      )) {
        throw StateError('Activity save failed');
      }
      // A profile removed by its owner while a platform write was pending
      // cannot be recreated by that late write.
      if (!isProfilePresent()) {
        if (!await preferences.remove(storageKey)) {
          throw StateError('Activity removal failed');
        }
        return false;
      }
      if (_closed || _disposed) return false;
      _acts = List.unmodifiable(next);
      _inverses.removeWhere((id, _) => !_acts.any((act) => act.id == id));
      _persistenceFailed = false;
      _notify();
      return true;
    } catch (_) {
      // SharedPreferences updates its cache before platform confirmation.
      try {
        await preferences.reload();
      } catch (_) {}
      _persistenceFailed = true;
      _notify();
      return false;
    }
  }

  void _load() {
    try {
      final raw = preferences.getString(storageKey);
      if (raw == null) return;
      if (raw.length > _maxBlobLength) throw const FormatException();
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['version'] != 1) throw const FormatException();
      final entries = data['acts'] as List;
      if (entries.length > maxEntries) throw const FormatException();
      final ids = <String>{};
      final loaded = <AutomaticAct>[];
      for (final rawEntry in entries) {
        final entry = rawEntry as Map<String, dynamic>;
        final id = entry['id'] as String;
        final location = entry['location'] as String;
        final summary = entry['summary'] as String;
        final at = entry['at'] as int;
        final session = entry['session'] as String?;
        final attempted = entry['undoAttempted'] as bool;
        final undone = entry['undone'] as bool;
        if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(location) ||
            !ids.add(id) ||
            _summary(summary).isEmpty ||
            summary.length > 1600 ||
            at <= 0 ||
            (session != null && session.length > 256) ||
            (undone && !attempted)) {
          throw const FormatException();
        }
        loaded.add(
          AutomaticAct(
            id: id,
            locationKey: location,
            kind: AutomaticActKind.values.byName(entry['kind'] as String),
            summary: _summary(summary),
            occurredAt: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
            sessionId: session == null || KitRedact.containsSecret(session)
                ? null
                : KitRedact.text(session),
            acknowledged: entry['acknowledged'] as bool,
            undoAttempted: attempted,
            undone: undone,
          ),
        );
      }
      _acts = _bounded(loaded);
    } catch (_) {
      _acts = const [];
      _corruptHistory = true;
    }
  }

  /// Pauses new records, acknowledgements and Undo immediately, then drains
  /// already admitted writes and inverses without erasing history or callbacks.
  /// The shared owner stays registered, so another caller cannot replace it.
  /// Await this before validating deletion; use [cancelDeletion] if it aborts.
  Future<void> prepareForDeletion() {
    if (!_preparingDeletion && !_closed && !_disposed) {
      _preparingDeletion = true;
      _notify();
    }
    return _tail;
  }

  /// Resumes the same owner after reversible deletion preparation. Permanent
  /// erasure or disposal cannot be cancelled.
  void cancelDeletion() {
    if (!_preparingDeletion || _closed || _disposed) return;
    _preparingDeletion = false;
    _notify();
  }

  /// Close first, then drain in-flight writes/inverses, then remove the key.
  /// Call only in committed deletion. False is retryable; this
  /// controller remains closed even when the platform refuses removal.
  Future<bool> deleteProfileData() {
    if (_deletion case final pending?) return pending;
    _closed = true;
    _inverses.clear();
    _acts = const [];
    _notify();
    final operation = _tail.then((_) async {
      try {
        if (!await preferences.remove(storageKey)) {
          throw StateError('Activity removal failed');
        }
        _persistenceFailed = false;
        return true;
      } catch (_) {
        _persistenceFailed = true;
        return false;
      } finally {
        _notify();
      }
    });
    _deletion = operation;
    return operation.whenComplete(() => _deletion = null);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _inverses.clear();
    super.dispose();
  }
}
