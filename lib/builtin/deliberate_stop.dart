import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// Remembers that the person stopped the phone's OpenCode themselves, so a
/// later Android exit does not say it is "starting again" and the app does
/// not bring back a server that was turned off on purpose. Set by Stop on
/// This phone, cleared by any start that ended with the server answering.
/// Key: `oc.phoneServerStopped.<profileId>` (swept with the profile).
class DeliberateServerStop {
  DeliberateServerStop._();

  static String keyFor(String profileId) => 'oc.phoneServerStopped.$profileId';

  static Future<void> mark(SharedPreferences prefs, String profileId) async {
    try {
      await prefs.setBool(keyFor(profileId), true);
    } catch (_) {}
  }

  static bool isMarked(SharedPreferences prefs, String profileId) {
    try {
      return prefs.getBool(keyFor(profileId)) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Clears the mark without needing the store at hand (the starter has
  /// none); a missing store is not an error.
  static void clearLater(String profileId) {
    unawaited(
      SharedPreferences.getInstance()
          .then((prefs) async {
            if (prefs.containsKey(keyFor(profileId))) {
              await prefs.remove(keyFor(profileId));
            }
          })
          .catchError((Object _) {}),
    );
  }
}
