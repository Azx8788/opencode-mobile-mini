import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Display choices belong to a server profile, never to source content.
@immutable
class ReaderPreferences {
  const ReaderPreferences({this.sourceFirst = false, this.wrapCode});

  final bool sourceFirst;
  final bool? wrapCode;
}

class ReaderPreferencesStore extends ValueNotifier<ReaderPreferences> {
  ReaderPreferencesStore({required this.prefs, required this.profileId})
    : super(_read(prefs, profileId));

  final SharedPreferences prefs;
  final String? profileId;
  bool _saving = false;
  bool _disposed = false;
  static final Map<String, Future<void>> _pending = {};

  /// Profile deletion waits for accepted writes before discovering keys.
  static Future<void> drain(String profileId) async {
    while (true) {
      final pending = _pending[profileId];
      if (pending == null) return;
      await pending;
      if (identical(_pending[profileId], pending)) return;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  static String keyFor(String id) => 'oc.readerPreferences.$id';

  static ReaderPreferences _read(SharedPreferences prefs, String? id) {
    if (id == null || id.isEmpty) return const ReaderPreferences();
    try {
      final encoded = prefs.getString(keyFor(id));
      if (encoded == null) return const ReaderPreferences();
      final data = jsonDecode(encoded) as Map<String, dynamic>;
      return ReaderPreferences(
        sourceFirst: data['sourceFirst'] == true,
        wrapCode: data['wrapCode'] is bool ? data['wrapCode'] as bool : null,
      );
    } catch (_) {
      return const ReaderPreferences();
    }
  }

  /// Publish only after storage accepts the choice. Failed writes leave the
  /// last saved choice intact, so a restart never silently changes the UI.
  Future<bool> update({bool? sourceFirst, bool? wrapCode}) {
    if (_saving || _disposed) return Future.value(false);
    _saving = true;
    final id = profileId;
    final previous = id == null
        ? Future<void>.value()
        : _pending[id] ?? Future<void>.value();
    final operation = previous.then(
      (_) => _write(sourceFirst: sourceFirst, wrapCode: wrapCode),
    );
    final settled = operation.then<void>((_) {});
    if (id != null && id.isNotEmpty) _pending[id] = settled;
    return operation.whenComplete(() {
      _saving = false;
      if (id != null && identical(_pending[id], settled)) _pending.remove(id);
    });
  }

  Future<bool> _write({bool? sourceFirst, bool? wrapCode}) async {
    final id = profileId;
    final previous = id == null || id.isEmpty ? value : _read(prefs, id);
    final next = ReaderPreferences(
      sourceFirst: sourceFirst ?? previous.sourceFirst,
      wrapCode: wrapCode ?? previous.wrapCode,
    );
    try {
      if (id != null && id.isNotEmpty) {
        if (!await prefs.setString(
          keyFor(id),
          jsonEncode({
            'sourceFirst': next.sourceFirst,
            'wrapCode': next.wrapCode,
          }),
        )) {
          // The plugin mutates its cache before its platform write resolves.
          // Reload disk truth so reopening a reader does not use a refused value.
          try {
            await prefs.reload();
          } catch (_) {}
          return false;
        }
      }
      if (!_disposed) value = next;
      return true;
    } catch (_) {
      try {
        await prefs.reload();
      } catch (_) {}
      return false;
    }
  }
}
