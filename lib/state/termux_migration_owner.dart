import 'dart:async';

import 'package:flutter/widgets.dart';

import '../domain/termux_migration_service.dart';
import 'connection.dart';

/// What the owner last asked the migration to do, so "Try again" repeats it.
enum TermuxMigrationRequest { check, start, resume }

/// The one owner of the Termux migration, above every route (the backend's
/// hook-up contract, docs/qa/codex-termux-migration-2026-09-28/README.md):
/// it creates the controller once, runs one operation at a time, and stops
/// the copy when the app leaves the foreground, because Android gives the
/// copy no background lifetime. The page, This phone's row and the Servers
/// offer only read it and ask it to act.
///
/// It keeps no durable facts of its own: whether a move finished, which
/// providers to sign in to again, and discarding a saved copy are all asked
/// of the backend (the controller's journal), so nothing here needs a
/// profile-scoped key or a deletion sweep entry.
class TermuxMigrationOwner extends ChangeNotifier with WidgetsBindingObserver {
  TermuxMigrationOwner({this.create});

  /// The app's owner. Tests put their own here, as they do with
  /// `PhoneSetup.engine`.
  static TermuxMigrationOwner instance = TermuxMigrationOwner();

  /// Makes the controller; null uses [TermuxMigrationService.create].
  final Future<TermuxMigrationController> Function(
    ConnectionController connection,
    String builtinProfileName,
  )?
  create;

  TermuxMigrationController? _controller;
  Future<TermuxMigrationController?>? _creating;
  Future<void>? _inFlight;
  bool _observing = false;
  bool _disposed = false;

  /// The source profile the last operation ran for.
  String? source;

  /// The last operation asked for.
  TermuxMigrationRequest? request;

  /// The items of the running or last copy, in the order the controller
  /// copies them (by name, the order its saved selection comes back in).
  List<TermuxMigrationItem> items = const [];

  /// The copy stopped because the app left the foreground.
  bool stoppedByLeaving = false;

  TermuxMigrationController? get controller => _controller;
  TermuxMigrationSnapshot? get snapshot => _controller?.snapshot;

  /// An operation is running (true until it has settled, even after Stop).
  bool get busy => _inFlight != null;

  /// A copy (not only a check) is running.
  bool get copying => busy && request != TermuxMigrationRequest.check;

  /// The controller, made once; null when this phone cannot make one (its
  /// private storage could not be read). A later call tries again.
  Future<TermuxMigrationController?> obtain(
    ConnectionController connection,
    String builtinProfileName,
  ) {
    final made = _controller;
    if (made != null) return Future.value(made);
    return _creating ??= () async {
      try {
        final made = await (create != null
            ? create!(connection, builtinProfileName)
            : TermuxMigrationService.create(
                connection: connection,
                builtinProfileName: builtinProfileName,
              ));
        if (_disposed) {
          made.dispose();
          return null;
        }
        _controller = made..addListener(_changed);
        if (!_observing) {
          WidgetsBinding.instance.addObserver(this);
          _observing = true;
        }
        return made;
      } catch (_) {
        return null;
      } finally {
        _creating = null;
      }
    }();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Items in the controller's own order.
  static List<TermuxMigrationItem> ordered(Iterable<TermuxMigrationItem> it) =>
      it.toList()..sort((a, b) => a.name.compareTo(b.name));

  Future<void> _run(
    String sourceId,
    TermuxMigrationRequest what,
    Future<void> Function(TermuxMigrationController c) op,
  ) {
    final c = _controller;
    if (c == null) return Future.value();
    final running = _inFlight;
    if (running != null) return running;
    source = sourceId;
    request = what;
    if (what != TermuxMigrationRequest.check) stoppedByLeaving = false;
    final done = () async {
      try {
        await op(c);
      } catch (_) {
        // The controller publishes every failure as a fixed state.
      }
      // Busy ends only when the backend says it settled, which can come
      // after the cancelled state (its stop command is bounded, not instant).
      await c.whenSettled;
    }();
    final settled = done.whenComplete(() {
      _inFlight = null;
      _changed();
    });
    _inFlight = settled;
    _changed();
    return settled;
  }

  /// A fresh look at Termux and the phone: sizes, free space for [selected]
  /// (nothing chosen yet needs none), the in-app server.
  Future<void> check(
    String sourceId, {
    Set<TermuxMigrationItem> selected = const {},
  }) => _run(
    sourceId,
    TermuxMigrationRequest.check,
    (c) => c.check(selected: selected),
  );

  /// Starts copying [selected] from [sourceId].
  Future<void> start(
    ConnectionController connection,
    String sourceId,
    Set<TermuxMigrationItem> selected,
  ) {
    items = ordered(selected);
    return _run(
      sourceId,
      TermuxMigrationRequest.start,
      (c) => c.start(sourceProfileId: sourceId, selected: items.toSet()),
    );
  }

  /// Resumes the saved copy of [sourceId] with its saved selection. With
  /// nothing saved (the copy stopped before it began), starts [fallback]
  /// again instead.
  Future<void> resume(
    ConnectionController connection,
    String sourceId, {
    Set<TermuxMigrationItem> fallback = const {},
  }) async {
    final c = _controller;
    if (c == null || busy) return;
    Set<TermuxMigrationItem>? saved;
    try {
      saved = await c.savedSelection(sourceId);
    } catch (_) {
      saved = null;
    }
    if (saved == null && fallback.isNotEmpty) {
      return start(connection, sourceId, fallback);
    }
    if (saved != null) items = ordered(saved);
    return _run(
      sourceId,
      TermuxMigrationRequest.resume,
      (c) => c.resume(sourceId),
    );
  }

  /// The saved selection of an unfinished (or finished) copy; null when
  /// none was saved or it cannot be read.
  Future<Set<TermuxMigrationItem>?> savedSelection(String sourceId) async {
    final c = _controller;
    if (c == null) return null;
    try {
      return await c.savedSelection(sourceId);
    } catch (_) {
      return null;
    }
  }

  /// Stops the running operation at once; [leaving] says the app left the
  /// foreground. Await [settled] before offering Resume or leaving.
  Future<void> cancel({bool leaving = false}) async {
    final c = _controller;
    if (c == null || !busy) return;
    if (leaving) stoppedByLeaving = true;
    try {
      await c.cancel();
    } catch (_) {
      // The controller publishes a fixed cancelled state either way.
    }
    _changed();
  }

  /// Completes when no operation runs.
  Future<void> settled() => _inFlight ?? Future.value();

  /// The finished move from [profileId] (the backend's durable record; it
  /// stays true after the person edits the files), or null when it has not
  /// finished. Throws [TermuxMigrationException] when the record cannot be
  /// read: unknown is not "unfinished".
  Future<TermuxMigrationCompletedJob?> completedJob(String profileId) async {
    final c = _controller;
    if (c == null) return null;
    return c.completedJob(profileId);
  }

  final Map<String, List<String>> _providerNames = {};

  /// The AI providers found in the imported settings copy of [profileId],
  /// by name, also offline. Empty means unknown. Kept in memory only.
  Future<List<String>> providerNames(String profileId) async {
    final c = _controller;
    if (c == null) return _providerNames[profileId] ?? const [];
    try {
      return _providerNames[profileId] = await c.providerNames(profileId);
    } catch (_) {
      return _providerNames[profileId] ?? const [];
    }
  }

  /// The reviewed space for [selected] from the last look, or null when
  /// there was none or the selection is refused.
  TermuxMigrationSpace? reviewSpace(Set<TermuxMigrationItem> selected) {
    try {
      return _controller?.reviewSpace(selected);
    } catch (_) {
      return null;
    }
  }

  /// Throws away the saved copy of [sourceId] (the backend removes only its
  /// temporary transfer files; what was imported and Termux stay). Stops
  /// and waits for a running copy first, holds the owner's guard through
  /// the removal, and on success forgets what this owner remembered of the
  /// copy. Null when it could not be removed (it stays and can be retried).
  Future<TermuxMigrationDiscardResult?> discard(String sourceId) async {
    final c = _controller;
    if (c == null) return null;
    if (busy) {
      await cancel();
      await settled();
    }
    final running = _inFlight;
    if (running != null) await running;
    source = sourceId;
    final done = () async {
      try {
        final result = await c.discardSavedCopy(sourceId);
        await c.whenSettled;
        return result;
      } catch (_) {
        return null;
      }
    }();
    final guard = done.then((_) {}).whenComplete(() {
      _inFlight = null;
      _changed();
    });
    _inFlight = guard;
    _changed();
    final result = await done;
    await guard;
    if (result == TermuxMigrationDiscardResult.discarded ||
        result == TermuxMigrationDiscardResult.nothingSaved) {
      source = null;
      request = null;
      items = const [];
      stoppedByLeaving = false;
      _providerNames.remove(sourceId);
      _changed();
    }
    return result;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android gives the copy no background lifetime (the backend's 15-minute
    // foreground budget): leaving the app stops it, and Resume picks up.
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (copying) unawaited(cancel(leaving: true));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    final c = _controller;
    _controller = null;
    if (c != null) {
      c.removeListener(_changed);
      // Dispose only after the running operation settles (the contract).
      final running = _inFlight;
      if (running == null) {
        c.dispose();
      } else {
        unawaited(c.cancel().catchError((Object _) {}));
        unawaited(running.whenComplete(c.dispose));
      }
    }
    super.dispose();
  }
}
