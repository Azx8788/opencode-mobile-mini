import '../../l10n/app_localizations.dart';
import '../../domain/server_gateway.dart';

/// True for OAuth methods that finish through a browser redirect back to the
/// machine running the server. From a phone or another computer the redirect
/// lands on the wrong device, so those methods go last and get a warning.
bool connectMethodNeedsServerBrowser(IntegrationMethodInfo method) =>
    method.type == 'oauth' && method.label.toLowerCase().contains('browser');

/// Headless and device-code flows first, browser-redirect flows last, keys
/// after OAuth. Stable otherwise.
List<IntegrationMethodInfo> orderConnectMethods(
  List<IntegrationMethodInfo> methods,
) {
  int rank(IntegrationMethodInfo m) => switch (m.type) {
    'oauth' => connectMethodNeedsServerBrowser(m) ? 2 : 0,
    'key' => 1,
    _ => 3,
  };
  final sorted = List<IntegrationMethodInfo>.of(methods);
  sorted.sort((a, b) => rank(a).compareTo(rank(b)));
  return sorted;
}

/// The one line under a connect option that says how it finishes.
String connectMethodHint(IntegrationMethodInfo method, AppLocalizations l10n) {
  if (method.type == 'key') return l10n.e7SetupApiKeyHint;
  if (connectMethodNeedsServerBrowser(method)) {
    return l10n.e7SetupBrowserHint;
  }
  if (method.label.toLowerCase().contains('headless')) {
    return l10n.e7SetupDeviceCodeHint;
  }
  return l10n.e7SetupAccountHint;
}

/// Providers whose subscription or browser sign-in cannot load on an
/// OpenCode server and whose terms allow only an API key in other apps.
/// [url] is the provider's official page for creating one; it is opened
/// only through `openExternalLink`.
String? providerKeyPageUrl(String integrationId) =>
    switch (integrationId.toLowerCase()) {
      'anthropic' => 'https://console.anthropic.com/settings/keys',
      'google' => 'https://aistudio.google.com/apikey',
      _ => null,
    };

/// For a key-only provider, drops the browser sign-in options when the
/// server also advertises a key method; otherwise the list is unchanged
/// (nothing is invented the server does not offer).
List<IntegrationMethodInfo> keyLedConnectMethods(
  String integrationId,
  List<IntegrationMethodInfo> methods,
) {
  if (providerKeyPageUrl(integrationId) == null) return methods;
  final keys = methods.where((m) => m.type == 'key').toList();
  return keys.isEmpty ? methods : keys;
}
