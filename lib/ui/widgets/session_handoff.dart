import 'package:flutter/widgets.dart';

import '../../domain/session_handoff.dart';
import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import '../../state/server_presentation.dart';
import 'product_states.dart';
import 'session_handoff_sheets.dart';

/// A short-lived guard, never a persisted profile or a transport credential.
class SessionNavigationScope {
  SessionNavigationScope(ConnectionController controller)
    : profileID = controller.profile?.id,
      connectionRevision = controller.connectionRevision,
      revision = controller.locationRevision;

  final String? profileID;
  final int connectionRevision;
  final int revision;

  bool matches(ConnectionController controller) =>
      profileID != null &&
      controller.profile?.id == profileID &&
      controller.connectionRevision == connectionRevision &&
      controller.locationRevision == revision;

  void check(ConnectionController controller) {
    if (!matches(controller)) {
      throw StateError('The session location changed. Return and try again.');
    }
  }
}

/// "Continue on computer" for a conversation listed outside the chat
/// (Related conversations, All conversations). The old handoff dialog
/// (map `session-handoff-dialog`) merged into the one continue-on-computer
/// sheet (slice-P3.11a): the same command, the same sheet and the same copy
/// as the conversation menu, built from the folder the server reports for
/// [sessionID] now. The sheet only copies; nothing is sent.
///
/// [projectID], when given, must still match the conversation's project;
/// a conversation that moved meanwhile says so instead of offering a
/// command for the old place.
Future<void> showSessionHandoff(
  BuildContext context, {
  required ConnectionController controller,
  required String sessionID,
  required String? projectID,
}) async {
  final l10n = lookupAppLocalizations(Localizations.localeOf(context));
  if (!controller.capabilities.cliSessionResume) {
    showProductError(context, l10n.handoffUiComputerUnsupported);
    return;
  }
  final scope = SessionNavigationScope(controller);
  try {
    scope.check(controller);
    final repository = await controller.prepareActionRepository();
    scope.check(controller);
    if (repository == null) throw StateError('Session unavailable');
    final session = await repository.getSessionDetails(sessionID);
    scope.check(controller);
    if (session.id != sessionID ||
        (projectID != null && session.projectID != projectID)) {
      throw StateError('Session location changed');
    }
    if (!context.mounted) return;
    await showContinueOnComputerSheet(
      context,
      command: SessionResumeCommand.build(
        // The CLI's name follows the server's product generation: copy
        // only, the availability is the capability above.
        cli: controller.sessionResumeCli,
        sessionID: session.id,
        directory: session.directory,
        workspaceID: session.workspaceID,
      ),
    );
  } catch (_) {
    if (context.mounted) {
      showProductError(context, l10n.handoffUiComputerChanged);
    }
  }
}
