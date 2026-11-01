import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../domain/usage_subscriptions.dart';
import '../../../l10n/app_localizations.dart';
import '../../../platform/launch_shortcut.dart';
import '../../../state/connection.dart';
import '../../../state/profiles.dart';
import '../../../state/usage_signin_destination.dart';
import '../../../state/usage_subscriptions_controller.dart';
import '../../kit/kit.dart';
import '../agents/agent_sheet.dart' show AgentSheetStep, showAgentSheet;
import '../library_screen.dart' show IntegrationsMode, IntegrationsScreen;
import 'usage_add_screen.dart';
import 'usage_read_from_screen.dart';

/// What happened when a sign-in was asked for.
enum UsageSignInOutcome {
  /// The sign-in screen or sheet is open.
  opened,

  /// The saved server needs its credentials entered again first.
  needsCredentials,

  /// The server could not be reached to sign in.
  connectFailed,

  /// There is nowhere to sign in to from here.
  unavailable,
}

String usageOutcomeWords(AppLocalizations l10n, UsageSignInOutcome outcome) =>
    switch (outcome) {
      UsageSignInOutcome.needsCredentials => l10n.launchUiSessionReentry,
      UsageSignInOutcome.connectFailed =>
        l10n.launchUiUsageSignInConnectionFailed,
      UsageSignInOutcome.unavailable => l10n.usageSignInUnavailable,
      UsageSignInOutcome.opened => '',
    };

/// Opens the screen that signs a provider in. Tests pass a fake; the app
/// uses [ConnectionSignInLauncher].
abstract interface class UsageSignInLauncher {
  Future<UsageSignInOutcome> open(
    BuildContext context,
    UsageSignInDestination destination, {
    ServerProfile? profile,
  });
}

/// The routes the Usage widget already uses: a server's Providers page for
/// that provider, or this phone's agent sign-in sheet. A server that is not
/// the open one is connected first, the way a session link does.
class ConnectionSignInLauncher implements UsageSignInLauncher {
  const ConnectionSignInLauncher(this.controller);

  final ConnectionController controller;

  @override
  Future<UsageSignInOutcome> open(
    BuildContext context,
    UsageSignInDestination destination, {
    ServerProfile? profile,
  }) async {
    switch (destination.kind) {
      case UsageSignInKind.agentSignIn:
        unawaited(
          showAgentSheet(
            context,
            agentId: destination.agentId,
            step: AgentSheetStep.signIn,
          ),
        );
        return UsageSignInOutcome.opened;
      case UsageSignInKind.openCodeProvider:
        final server = profile;
        if (server == null) return UsageSignInOutcome.unavailable;
        if (server.requiresPasswordReentry ||
            server.requiresCodexTokenReentry) {
          return UsageSignInOutcome.needsCredentials;
        }
        final navigator = Navigator.of(context);
        if (server.id != controller.profile?.id) {
          Object? failure;
          try {
            await controller.connect(server);
          } catch (error) {
            failure = error;
          }
          if (failure != null || controller.api == null) {
            return UsageSignInOutcome.connectFailed;
          }
        }
        if (!navigator.mounted) return UsageSignInOutcome.opened;
        unawaited(
          navigator.push(
            KitPageRoute<void>(
              builder: (_) => IntegrationsScreen(
                controller: controller,
                mode: IntegrationsMode.providers,
                connectProviderID: destination.providerId,
              ),
            ),
          ),
        );
        return UsageSignInOutcome.opened;
      case UsageSignInKind.readUsageFrom:
      case UsageSignInKind.usagePage:
        return UsageSignInOutcome.unavailable;
    }
  }
}

ServerProfile? _profileOf(ConnectionController controller, String id) {
  for (final profile in controller.store.profiles) {
    if (profile.id == id) return profile;
  }
  return null;
}

/// Where signing [providerId] in on [connection] leads, or null when nothing
/// can be signed in there (a provider OpenCode cannot hold, a Paseo server).
UsageSignInDestination? usageDestinationFor(
  ConnectionController controller, {
  required String providerId,
  required UsageConnection connection,
  String action = 'sign_in',
}) {
  final destination = usageSignInDestination(
    UsageSignInTarget(
      profileId: connection.id,
      providerId: providerId,
      action: action,
    ),
    profile: _profileOf(controller, connection.id),
  );
  return destination.kind == UsageSignInKind.usagePage ? null : destination;
}

/// Signs [providerId] in on [connection]: the exact screen that fixes it.
Future<UsageSignInOutcome> startUsageSignIn(
  BuildContext context, {
  required ConnectionController controller,
  required UsageSignInLauncher launcher,
  required String providerId,
  required UsageConnection connection,
  String action = 'sign_in',
}) async {
  final destination = usageDestinationFor(
    controller,
    providerId: providerId,
    connection: connection,
    action: action,
  );
  if (destination == null) return UsageSignInOutcome.unavailable;
  return launcher.open(
    context,
    destination,
    profile: _profileOf(controller, connection.id),
  );
}

/// The connections [providerId] can be signed in on, best first: In-app
/// Ubuntu (usage works straight away), saved servers, then this phone's
/// agent.
List<UsageConnection> usageAddChoices(
  ConnectionController controller,
  UsageSnapshot snapshot,
  String providerId,
) {
  int rank(UsageConnection c) => switch (c.kind) {
    UsageConnectionKind.inAppUbuntu => 0,
    UsageConnectionKind.phoneAgents => 2,
    _ => 1,
  };
  final choices = [
    for (final c in snapshot.connections)
      if (usageDestinationFor(
            controller,
            providerId: providerId,
            connection: c,
          ) !=
          null)
        c,
  ];
  // List.sort is not stable; the index keeps snapshot order inside a rank.
  final indexed = [for (var i = 0; i < choices.length; i++) (i, choices[i])]
    ..sort((a, b) {
      final byRank = rank(a.$2).compareTo(rank(b.$2));
      return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
    });
  return [for (final entry in indexed) entry.$2];
}

/// "Add {provider}": pick where it is signed in, then that connection's own
/// sign-in. With one place to pick the choice is skipped. Returns the notice
/// to show when nothing opened, or null.
Future<UsageSignInOutcome?> startUsageAdd(
  BuildContext context, {
  required ConnectionController controller,
  required UsageSubscriptionsController usage,
  required UsageSignInLauncher launcher,
  required String providerId,
}) async {
  final choices = usageAddChoices(controller, usage.snapshot, providerId);
  if (choices.length == 1) {
    return startUsageSignIn(
      context,
      controller: controller,
      launcher: launcher,
      providerId: providerId,
      connection: choices.single,
    );
  }
  await pushKitPage<void>(
    context,
    (_) => UsageAddScreen(
      controller: controller,
      usage: usage,
      launcher: launcher,
      providerId: providerId,
    ),
  );
  return null;
}

/// The card's one fix button.
Future<UsageSignInOutcome?> runUsageFix(
  BuildContext context, {
  required ConnectionController controller,
  required UsageSubscriptionsController usage,
  required UsageSignInLauncher launcher,
  required UsageSubscription subscription,
}) async {
  final where = subscription.fixConnection;
  switch (subscription.fix) {
    case UsageFix.none:
      return null;
    case UsageFix.tryAgain:
      await usage.refresh(force: true);
      return null;
    case UsageFix.setUp:
      if (where == null) return null;
      await pushKitPage<void>(
        context,
        (_) => UsageReadFromScreen(
          controller: controller,
          usage: usage,
          connectionId: where.id,
          providerId: subscription.providerId,
        ),
      );
      return null;
    case UsageFix.signIn:
    case UsageFix.addKey:
      if (where == null) {
        return startUsageAdd(
          context,
          controller: controller,
          usage: usage,
          launcher: launcher,
          providerId: subscription.providerId,
        );
      }
      return startUsageSignIn(
        context,
        controller: controller,
        launcher: launcher,
        providerId: subscription.providerId,
        connection: where,
        action: subscription.fix == UsageFix.addKey ? 'add_key' : 'sign_in',
      );
  }
}

String usageFixLabel(
  AppLocalizations l10n,
  UsageSubscription subscription,
  String Function(UsageConnection) nameOf,
) => switch (subscription.fix) {
  UsageFix.none => '',
  UsageFix.tryAgain => l10n.usageTryAgain,
  UsageFix.addKey => l10n.usageAddKey,
  UsageFix.signIn =>
    subscription.state == SubscriptionState.signInExpired
        ? l10n.usageSignInAgain
        : l10n.usageSignIn,
  UsageFix.setUp => l10n.usageReadUsage,
};
