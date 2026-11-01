import 'package:shared_preferences/shared_preferences.dart';

import '../domain/free_model.dart';
import 'connection.dart';

/// [usesOpenCodeFreeModel] for the connected server: the model a new reply
/// in [sessionID] uses (its own choice, else the server's current one),
/// against the providers signed in there.
///
/// The chat and its model chip, This phone and the move from Termux all ask
/// the same question through this one function.
bool connectionUsesFreeModel(
  ConnectionController connection, {
  String? sessionID,
}) {
  if (!connection.hasConnectedServer) return false;
  final model =
      (sessionID == null ? null : connection.sessionModels[sessionID]?.model) ??
      connection.selectedModel;
  return usesOpenCodeFreeModel(
    signedInProviderIDs: [
      for (final provider in connection.providers?.providers ?? const [])
        provider.id,
    ],
    providerID: model?.providerID,
    modelID: model?.modelID,
    models: connection.catalog?.models ?? const [],
  );
}

/// The conversations where the person dismissed the chat's free-model note,
/// per saved server: the note says its piece once per conversation and
/// never comes back after a dismissal (the coordinator's free-model ask on
/// slice-fix-inbox-status). Kept under `oc.freeModelNoteDismissed.<id>`,
/// so deleting the server sweeps it (ProfileStore's scoped-key sweep).
abstract final class FreeModelNoteDismissals {
  /// The newest dismissals kept; an older conversation may show it again.
  static const maxSessions = 200;

  static String keyFor(String profileId) =>
      'oc.freeModelNoteDismissed.$profileId';

  static bool dismissed(
    SharedPreferences prefs,
    String profileId,
    String sessionID,
  ) {
    try {
      return (prefs.getStringList(keyFor(profileId)) ?? const []).contains(
        sessionID,
      );
    } catch (_) {
      // A value of another type: nothing was dismissed that can be read.
      return false;
    }
  }

  /// Saves the dismissal. False when storage refused it; the note is then
  /// hidden only until the chat is opened again.
  static Future<bool> dismiss(
    SharedPreferences prefs,
    String profileId,
    String sessionID,
  ) async {
    List<String> kept;
    try {
      kept = [...?prefs.getStringList(keyFor(profileId))];
    } catch (_) {
      kept = [];
    }
    kept
      ..remove(sessionID)
      ..add(sessionID);
    if (kept.length > maxSessions) {
      kept = kept.sublist(kept.length - maxSessions);
    }
    try {
      return await prefs.setStringList(keyFor(profileId), kept);
    } catch (_) {
      return false;
    }
  }
}

/// Whether the chat of [sessionID] shows the free-model note: it replies
/// with OpenCode's free model because no provider is signed in on this
/// server, and the person has not dismissed the note in this conversation.
/// Never in an isolated task or without a saved server.
bool freeModelNoteDue(ConnectionController connection, String sessionID) {
  final profileId = connection.profile?.id;
  if (connection.isIsolated || profileId == null) return false;
  if (!connectionUsesFreeModel(connection, sessionID: sessionID)) return false;
  return !FreeModelNoteDismissals.dismissed(
    connection.store.prefs,
    profileId,
    sessionID,
  );
}
