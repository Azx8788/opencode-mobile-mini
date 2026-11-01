/// The model the AI Team's agents use, chosen per profile. Empty means the
/// phone's own OpenCode default. Pure state and one preference; the phone
/// side is `BuiltinTeam.applyModel`.
library;

import 'package:shared_preferences/shared_preferences.dart';

/// `provider/model` as OpenCode names a model: letters, digits and
/// `. _ : @ + -` in each part, at least one slash. Anything else is never
/// written to the phone (it goes into a shell-read file and a JSON string).
final _spec = RegExp(r'^[A-Za-z0-9._:@+-]+(/[A-Za-z0-9._:@+-]+)+$');

bool isValidTeamModel(String spec) => _spec.hasMatch(spec);

/// The spec for a catalog model, or null when its ids are not safe to send.
String? teamModelSpec(String providerID, String modelID) {
  final bare = modelID.startsWith('$providerID/')
      ? modelID.substring(providerID.length + 1)
      : modelID;
  final spec = '$providerID/$bare';
  return isValidTeamModel(spec) ? spec : null;
}

/// `oc.teamModel.<profileId>`: swept with the profile by the scoped-key
/// deletion.
class TeamModelStore {
  const TeamModelStore(this._prefs);

  final SharedPreferences _prefs;

  static String key(String profileId) => 'oc.teamModel.$profileId';

  String? read(String profileId) {
    try {
      final value = _prefs.getString(key(profileId));
      return value != null && isValidTeamModel(value) ? value : null;
    } catch (_) {
      return null;
    }
  }

  /// Null clears the choice (the phone's OpenCode default).
  Future<bool> write(String profileId, String? spec) async {
    try {
      if (spec == null) return await _prefs.remove(key(profileId));
      if (!isValidTeamModel(spec)) return false;
      return await _prefs.setString(key(profileId), spec);
    } catch (_) {
      return false;
    }
  }
}
