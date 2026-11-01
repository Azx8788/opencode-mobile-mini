import 'server_gateway.dart' show CatalogModel;

/// OpenCode's own provider. With nobody signed in to it (or to anything
/// else), an OpenCode server still answers, with its free models only.
const openCodeFreeProviderID = 'opencode';

/// Whether replies on a server come from OpenCode's free model because
/// nobody signed in to a provider there: the model in use is one of
/// OpenCode's own, it costs nothing, and no other provider is signed in.
///
/// Those free models are shared and rate-limited, so replies are slower
/// than with the person's own provider. A server moved from Termux, or set
/// up fresh on this phone, starts this way: sign-ins never move.
///
/// Someone who signed in to another provider and still picked a free
/// OpenCode model chose it; that is not this case. A model whose price the
/// server did not send is not assumed free.
bool usesOpenCodeFreeModel({
  required Iterable<String> signedInProviderIDs,
  required String? providerID,
  required String? modelID,
  required Iterable<CatalogModel> models,
}) {
  if (providerID != openCodeFreeProviderID || modelID == null) return false;
  if (signedInProviderIDs.any((id) => id != openCodeFreeProviderID)) {
    return false;
  }
  for (final model in models) {
    // Some catalog shapes key the model as "provider/model".
    if (model.providerID == providerID &&
        (model.id == modelID || model.id == '$providerID/$modelID')) {
      return model.cost?.isFree ?? false;
    }
  }
  return false;
}
