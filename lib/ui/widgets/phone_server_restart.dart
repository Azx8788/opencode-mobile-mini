import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../builtin/builtin_server.dart';
import '../../l10n/app_localizations.dart';
import '../../platform/platform_capabilities.dart';
import '../../state/connection.dart';
import '../../state/local_server_controls.dart';
import '../../termux/bridge.dart';
import '../app_iconography.dart';
import '../kit/kit_dialog.dart';
import 'product_states.dart' show productErrorText;

/// Whether the connected server is this phone's own, and how to restart it.
///
/// The one place that tells the phone's servers apart for the Work tab: the
/// in-app OpenCode restarts through [BuiltinServerStarter], the Termux one
/// through [LocalServerControls]; both are the existing paths, and both
/// reconnect afterwards. Any other server is remote: no restart.
({bool onThisPhone, Future<void> Function()? restart}) phoneServerRestartFor({
  required ConnectionController connection,
  required BuiltinServerStarter builtin,
  required BuildContext context,
}) {
  final profile = connection.profile;
  if (profile == null || connection.usesConnectionToken) {
    return (onThisPhone: false, restart: null);
  }
  // A failed restart blocks nothing else, but it must be read: one alert
  // that names what failed (KIT-15, KIT-34: a snack bar is only for Undo).
  void fail(String message) {
    if (!context.mounted) return;
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    unawaited(
      showKitAlert(
        context,
        title: l10n.phoneServerRestartFailedTitle,
        body: message.isEmpty ? l10n.phoneServerRestartFailed : message,
        icon: AppIconography.restart,
        alertKey: const ValueKey('phone-server-restart-failed'),
      ),
    );
  }

  if (looksLikeInAppServer(profile)) {
    return (
      onThisPhone: true,
      restart: () async {
        final failure = await builtin.start(profile);
        if (failure != null) {
          fail('');
          return;
        }
        await connection.retryConnection();
      },
    );
  }
  if (platformCapabilities.supportsTermux &&
      TermuxBridge.managesServerUrl(profile.baseUrl)) {
    return (
      onThisPhone: true,
      restart: () async {
        try {
          await LocalServerControls(
            store: connection.store,
            connection: connection,
          ).restart();
        } on LocalServerControlFailure catch (failure) {
          // The manager's sentence, or its output said in words.
          fail(failure.message.trim().isEmpty ? '' : productErrorText(failure));
          return;
        }
        await connection.retryConnection();
      },
    );
  }
  return (onThisPhone: false, restart: null);
}
