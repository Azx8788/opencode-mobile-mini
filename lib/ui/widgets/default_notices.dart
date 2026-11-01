import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/server_gateway.dart' show CatalogModel;
import '../../state/connection.dart';
import '../../state/interaction_defaults.dart';

/// Defaults instead of questions (programme P6.6, AUTO-8): where the app
/// picked something by itself, it says so once, in the place the choice is
/// used, and the thing's own page keeps the way to change it.
///
/// This claims that one announcement. With a saved server ([profileId]) the
/// claim is kept per server across restarts ([InteractionDefaultsStore],
/// swept with the profile); without one it is kept for this run of the app.
/// Returns the safe label to name in the notice, or null when there is
/// nothing to say: an explicit choice, an unresolved default, already said,
/// or the claim could not be saved.
Future<String?> claimDefaultNotice<T>({
  required DefaultKind kind,
  required DefaultChoice<T> choice,
  String? profileId,
  SharedPreferences? prefs,
}) async {
  if (!choice.isAutomatic) return null;
  if (profileId == null || profileId.isEmpty) {
    return _saidThisRun.add(kind) ? choice.label : null;
  }
  try {
    // The factory shares the same admission/drain owner with profile deletion.
    final store = InteractionDefaultsStore(
      prefs ?? await SharedPreferences.getInstance(),
      profileID: profileId,
    );
    return await store.takeAnnouncement(kind, choice);
  } catch (_) {
    // A notice that cannot be remembered is left unsaid rather than
    // repeated on every visit; the choice itself still stands.
    return null;
  }
}

final _saidThisRun = <DefaultKind>{};

@visibleForTesting
void resetDefaultNoticesForTest() => _saidThisRun.clear();

/// The model the connection chose, as a default: the person's own pick
/// ([DefaultReason.explicitChoice]), the server's default model by name
/// ([DefaultReason.serverDefault]), the only model, or unresolved while the
/// catalog is not loaded. The connection resolves the server's configured
/// chat model ahead of the provider default and keeps an explicit pick; a
/// selection it did not mark explicit is that resolved server default.
DefaultChoice<CatalogModel> modelDefaultOf(ConnectionController controller) {
  final models = controller.catalog?.models ?? const <CatalogModel>[];
  final selected = controller.selectedModel;
  final profileId = controller.profile?.id;
  final explicit =
      profileId != null &&
      controller.store.modelWasExplicitlySelected(profileId);
  CatalogModel? match() {
    for (final model in models) {
      if (model.providerID == selected?.providerID &&
          model.id == selected?.modelID) {
        return model;
      }
    }
    return null;
  }

  return InteractionDefaults.model(
    models,
    signedIn: models.isNotEmpty,
    serverProviderID: explicit ? null : selected?.providerID,
    serverModelID: explicit ? null : selected?.modelID,
    explicitChoice: explicit ? match() : null,
  );
}
