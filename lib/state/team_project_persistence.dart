import 'package:shared_preferences/shared_preferences.dart';
import '../domain/team_project_gateway.dart';

class SharedPreferencesTeamProjectPersistence
    implements TeamProjectPersistence {
  SharedPreferencesTeamProjectPersistence(this.preferences, String profileId)
    : key = 'oc.teamWorkspace.$profileId';
  final SharedPreferences preferences;
  final String key;
  @override
  Future<String?> read() async => preferences.getString(key);
  @override
  Future<void> write(String value) async {
    if (!await preferences.setString(key, value)) {
      throw StateError('saveFailed');
    }
  }

  @override
  Future<void> delete() async {
    if (!await preferences.remove(key)) throw StateError('deleteFailed');
  }
}
