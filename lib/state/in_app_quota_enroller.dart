import '../builtin/quota_collector_host.dart';
import '../domain/provider_quota.dart';
import '../quota/provider_quota_client.dart';
import 'connection.dart';
import 'profiles.dart';

/// After usage is set up on In-app Ubuntu, reads each provider once and puts
/// every one that answers with numbers under the quota monitor, so the Usage
/// widget fills without more taps. Providers the person has not signed in to
/// are skipped; the page says so per provider. Alerts follow the shared
/// notification rules, at the same 80% the Remaining page offers.
class InAppQuotaEnroller {
  InAppQuotaEnroller(
    this.controller, {
    ProviderQuotaGateway Function(ServerProfile, QuotaProvider)? gateway,
  }) : _gateway =
           gateway ??
           ((profile, provider) => HttpProviderQuotaGateway(
             profile,
             provider: provider,
             inAppToken: InAppQuotaCollector.tokenReaderFor(profile),
           ));

  final ConnectionController controller;
  final ProviderQuotaGateway Function(ServerProfile, QuotaProvider) _gateway;

  static const threshold = 80.0;

  /// The providers now monitored for [profile] by this call (already
  /// monitored ones count as monitored too).
  Future<Set<QuotaProvider>> enroll(ServerProfile profile) async {
    final monitored = <QuotaProvider>{};
    for (final provider in QuotaProvider.values) {
      if (!quotaCollectionAvailable(provider)) continue;
      if (controller.quotaMonitor.rulesFor(profile.id, provider) != null) {
        monitored.add(provider);
        continue;
      }
      final gateway = _gateway(profile, provider);
      try {
        final snapshot = await gateway.readSnapshot();
        if (!snapshot.canShowWindows) {
          // Tell the Usage widget which sign-in is missing here, so its row
          // can open the screen that fixes it.
          final widget = controller.quotaMonitor.widget;
          if (snapshot.status == ProviderQuotaStatus.unconfigured) {
            await widget?.markNotSignedIn(
              profileId: profile.id,
              profileName: profile.name,
              providerId: provider.name,
            );
          } else if (snapshot.status == ProviderQuotaStatus.authRequired) {
            await widget?.markAuthNeeded(
              profileId: profile.id,
              profileName: profile.name,
              provider: provider,
            );
          }
          continue;
        }
        final shared = controller.sharedNotifyRules;
        final saved = await controller.quotaMonitor.enroll(
          profile.id,
          snapshot,
          notifications: shared.quotaAlerts,
          threshold: threshold,
          wifiOnly: shared.wifiOnly,
          quietStart: shared.quietEnabled ? shared.quietStart : null,
          quietEnd: shared.quietEnabled ? shared.quietEnd : null,
        );
        if (saved) monitored.add(provider);
      } on Object {
        // One provider failing never stops the others.
      } finally {
        try {
          gateway.close();
        } on Object {
          // Teardown errors are not shown.
        }
      }
    }
    return monitored;
  }
}
