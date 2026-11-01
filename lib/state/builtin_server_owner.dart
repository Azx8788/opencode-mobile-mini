import 'package:shared_preferences/shared_preferences.dart';

/// Serial owner of the one phone runtime pointer shared by local profiles.
/// Deletion stops admission before waiting for a platform write already in
/// flight, so its final tombstone always follows that write on disk.
class BuiltinServerOwner {
  BuiltinServerOwner._(this._prefs);

  static const key = 'oc.builtinServerOwner';
  static final _owners = Expando<BuiltinServerOwner>();

  static BuiltinServerOwner forPreferences(SharedPreferences prefs) =>
      _owners[prefs] ??= BuiltinServerOwner._(prefs);

  final SharedPreferences _prefs;
  final _closed = <String>{};
  Future<void> _pending = Future<void>.value();
  bool _cacheKnown = true;

  Future<void> _reconcile() async {
    if (_cacheKnown) return;
    try {
      await _prefs.reload();
      _cacheKnown = true;
    } catch (_) {
      throw StateError('The phone server setting could not be read.');
    }
  }

  Future<void> _writePointer(String value, String failure) async {
    try {
      if (!await _prefs.setString(key, value)) throw StateError(failure);
    } catch (_) {
      // The plugin updates its cache before acknowledging the durable write.
      // A failed claim is just as uncertain as a failed deletion tombstone.
      _cacheKnown = false;
      try {
        await _reconcile();
      } catch (_) {
        // Keep the uncertainty: later operations must reconcile before they
        // can compare or replace the pointer, never trust optimistic cache.
      }
      throw StateError(failure);
    }
  }

  Future<void> _serialize(Future<void> Function() action) {
    final next = _pending.then((_) => action());
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> claim(String profileId, {required bool Function() isReadable}) {
    bool admitted() =>
        profileId.isNotEmpty && !_closed.contains(profileId) && isReadable();
    if (!admitted()) {
      return Future.error(StateError('The server profile is unavailable.'));
    }
    return _serialize(() async {
      await _reconcile();
      if (!admitted()) throw StateError('The server profile is unavailable.');
      await _writePointer(
        profileId,
        'The phone server setting could not be saved.',
      );
      if (!admitted()) {
        throw StateError('The phone server setting could not be saved.');
      }
    });
  }

  Future<void> clearProfile(String profileId) {
    _closed.add(profileId);
    return _serialize(() async {
      await _reconcile();
      if (_prefs.getString(key) != profileId) return;
      // An empty pointer suppresses legacy fallback to another local profile.
      await _writePointer('', 'The phone server setting could not be cleared.');
    });
  }

  /// Only the deletion transaction may reopen a profile after its abort has
  /// completed. Claims still require the live profile-readable predicate.
  void cancelDeletion(String profileId) => _closed.remove(profileId);
}
