import 'package:flutter/widgets.dart';

import '../../builtin/builtin_server.dart' show looksLikeInAppServer;
import '../../l10n/app_localizations.dart';
import '../../platform/platform_capabilities.dart';
import '../../state/connection.dart';
import '../../termux/bridge.dart' show TermuxBridge;
import '../app_theme.dart';
import '../kit/kit_sheet.dart';

// Confirmations for actions that interrupt running work or drop local state
// but are not irreversible. Each one lives here, rather than next to its
// button, because the same action is reachable from several surfaces and a
// copy that confirms in one place but not another teaches people to distrust
// both. Every sheet says concretely what stops or is lost.
//
// Kit only (shared-shell-1): each opens through showKitConfirm with the kind
// that says what the act does (LOOK-5): stop ends running work (its cancel
// word is "Keep running"), destructive deletes, neutral is a restart or a
// disconnect that connecting again undoes.

AppLocalizations _copy(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

/// Whether the active server is this phone's own (the in-app Linux server or
/// the Termux server this app manages). Shape only, from the saved profile:
/// the same test `phoneServerRestartFor` makes. A token server never is.
bool isServerOnThisPhone(ConnectionController controller) {
  final profile = controller.profile;
  if (profile == null || controller.usesConnectionToken) return false;
  return looksLikeInAppServer(profile) ||
      (platformCapabilities.supportsTermux &&
          TermuxBridge.managesServerUrl(profile.baseUrl));
}

/// Disconnecting from the active server. It says whether the server keeps
/// running (and, when it is this phone's own, that it keeps using battery),
/// and, only when something is waiting to send, how much of it stays on the
/// phone (settings-disconnect-sheet: one sentence, never "No queued
/// prompts"). Neutral: connecting again undoes it (LOOK-5). [onThisPhone]
/// overrides the profile-shape test when the caller already knows.
Future<bool> confirmDisconnectServer(
  BuildContext context,
  ConnectionController controller, {
  bool? onThisPhone,
}) {
  final l10n = _copy(context);
  final id = controller.profile?.id;
  final queued = id == null ? 0 : controller.queuedPromptCountForProfile(id);
  final drafts = id == null ? 0 : controller.draftCountForProfile(id);
  final waiting = queued + drafts;
  final server = controller.profile?.name ?? l10n.e7SettingsUi16;
  return showKitConfirm(
    context,
    title: l10n.e7SettingsDisconnectTitle(server),
    body: (onThisPhone ?? isServerOnThisPhone(controller))
        ? l10n.safetyDisconnectBodyPhone
        : l10n.safetyDisconnectBody,
    consequences: [if (waiting > 0) l10n.safetyDisconnectWaiting(waiting)],
    // Names what it acts on (R2), like the title above it.
    confirmLabel: l10n.serverDisconnectFrom(server),
    icon: AppIconography.unlink,
    sheetKey: const ValueKey('disconnect-confirm-sheet'),
    confirmKey: const ValueKey('confirm-disconnect'),
  );
}

/// Revoking a session's public link, which cuts off everyone holding it.
Future<bool> confirmStopSharing(BuildContext context) {
  final l10n = _copy(context);
  return showKitConfirm(
    context,
    title: l10n.safetyStopSharingTitle,
    body: l10n.safetyStopSharingBody,
    confirmLabel: l10n.e7WorkspaceStopSharing,
    cancelLabel: l10n.safetyStopSharingKeep,
    icon: AppIconography.unlink,
    kind: KitConfirmKind.destructive,
    sheetKey: const ValueKey('stop-sharing-confirm-sheet'),
    confirmKey: const ValueKey('confirm-stop-sharing'),
  );
}

/// Stopping the server this app manages on the phone, which takes every
/// running agent turn down with it.
Future<bool> confirmStopLocalServer(BuildContext context) {
  final l10n = _copy(context);
  return showKitConfirm(
    context,
    title: l10n.safetyStopLocalServerTitle,
    body: l10n.safetyStopLocalServerBody,
    confirmLabel: l10n.e7SetupStopLocal,
    cancelLabel: l10n.safetyStopLocalServerKeep,
    icon: AppIcons.stop,
    kind: KitConfirmKind.stop,
    sheetKey: const ValueKey('stop-local-server-confirm-sheet'),
    confirmKey: const ValueKey('confirm-stop-local-server'),
  );
}

/// Restarting the phone's server interrupts whatever is running on it.
/// Neutral: a restart is not a loss (LOOK-5).
Future<bool> confirmRestartLocalServer(
  BuildContext context, {
  required int busyConversations,
}) {
  final l10n = _copy(context);
  return showKitConfirm(
    context,
    title: l10n.termuxRestartTitle,
    body: l10n.termuxRestartMessage,
    consequences: [
      if (busyConversations > 0)
        l10n.termuxRestartBusyMessage(busyConversations),
    ],
    confirmLabel: l10n.termuxRestartConfirm,
    icon: AppIconography.restart,
    sheetKey: const ValueKey('restart-local-server-sheet'),
    confirmKey: const ValueKey('confirm-restart-local-server'),
  );
}

/// Stopping the Claude Code daemon on the phone. It has its own sheet rather
/// than the OpenCode server's because that copy names OpenCode, and a person
/// running both must be able to tell which one they are about to stop.
Future<bool> confirmStopLocalAgents(BuildContext context) {
  final l10n = _copy(context);
  return showKitConfirm(
    context,
    title: l10n.localAgentStopTitle,
    body: l10n.localAgentStopBody,
    confirmLabel: l10n.localAgentStopNamed,
    cancelLabel: l10n.safetyStopLocalServerKeep,
    icon: AppIcons.stop,
    kind: KitConfirmKind.stop,
    sheetKey: const ValueKey('stop-local-agents-confirm-sheet'),
    confirmKey: const ValueKey('confirm-stop-local-agents'),
  );
}

/// Restarting the Claude Code daemon interrupts whatever it is running.
/// Neutral: a restart is not a loss (LOOK-5).
Future<bool> confirmRestartLocalAgents(
  BuildContext context, {
  required int busyConversations,
}) {
  final l10n = _copy(context);
  return showKitConfirm(
    context,
    title: l10n.localAgentRestartTitle,
    body: l10n.localAgentRestartBody,
    consequences: [
      if (busyConversations > 0)
        l10n.termuxRestartBusyMessage(busyConversations),
    ],
    confirmLabel: l10n.termuxRestartConfirm,
    icon: AppIconography.restart,
    sheetKey: const ValueKey('restart-local-agents-sheet'),
    confirmKey: const ValueKey('confirm-restart-local-agents'),
  );
}

/// Removing Claude Code from the phone. Says what goes and, because people
/// fear losing it, what stays: projects and the Claude sign-in.
Future<bool> confirmRemoveLocalAgents(BuildContext context) {
  final l10n = _copy(context);
  return showKitConfirm(
    context,
    title: l10n.localAgentRemoveTitle,
    body: l10n.localAgentRemoveBody,
    confirmLabel: l10n.localAgentRemove,
    cancelLabel: l10n.localAgentRemoveKeep,
    icon: AppIconography.delete,
    kind: KitConfirmKind.destructive,
    sheetKey: const ValueKey('remove-local-agents-confirm-sheet'),
    confirmKey: const ValueKey('confirm-remove-local-agents'),
  );
}

/// Disconnecting an MCP server removes its tools from agents mid-session.
/// Neutral: connecting it again undoes it (LOOK-5).
Future<bool> confirmDisconnectMcp(
  BuildContext context, {
  required String serverName,
}) {
  final l10n = _copy(context);
  return showKitConfirm(
    context,
    title: l10n.safetyMcpDisconnectTitle(serverName),
    body: l10n.safetyMcpDisconnectBody,
    confirmLabel: l10n.e7SettingsUi8,
    cancelLabel: l10n.safetyMcpDisconnectKeep,
    icon: AppIconography.unlink,
    sheetKey: const ValueKey('mcp-disconnect-confirm-sheet'),
    confirmKey: const ValueKey('confirm-mcp-disconnect'),
  );
}
