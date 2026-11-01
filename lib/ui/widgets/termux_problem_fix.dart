import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../termux/bridge.dart';
import '../../termux/termux_reach.dart';
import '../app_iconography.dart';
import '../kit/kit.dart';
import 'external_link.dart';

/// Where Termux comes from: the current F-Droid build (app-authored).
const termuxGetUrl = 'https://f-droid.org/en/packages/com.termux/';

/// What a Termux problem is called and the one act that fixes it. The
/// same words on the first screen, the Servers row and This phone.
class TermuxProblemWords {
  const TermuxProblemWords({required this.line, required this.action});

  /// The cause in plain words, with what the fix will do.
  final String line;

  /// The act that fixes it, naming its target.
  final String action;
}

/// The words for [problem]. [runtime] names OpenCode's generation when it
/// is known ("OpenCode 1"); [heard] says OpenCode answered on this phone
/// although Termux could not be asked.
TermuxProblemWords termuxProblemWords(
  AppLocalizations l10n,
  TermuxProblem problem, {
  bool heard = false,
  String? runtime,
}) {
  final name = runtime ?? l10n.firstRunAgentOpenCode;
  return switch (problem) {
    TermuxProblem.accessNeeded => TermuxProblemWords(
      line: heard
          ? l10n.termuxProblemAccessHeard
          : l10n.termuxProblemAccessNeeded,
      action: l10n.termuxFixAllowAccess,
    ),
    TermuxProblem.accessBlocked => TermuxProblemWords(
      line: l10n.termuxProblemAccessBlocked,
      action: l10n.termuxFixOpenPermissions,
    ),
    TermuxProblem.otherAppsOff => TermuxProblemWords(
      line: l10n.termuxProblemOtherAppsOff,
      action: l10n.termuxFixAllowOtherApps,
    ),
    TermuxProblem.asleep => TermuxProblemWords(
      line: l10n.termuxProblemAsleep,
      action: l10n.termuxFixOpenTermux,
    ),
    TermuxProblem.notAnswering => TermuxProblemWords(
      line: l10n.termuxProblemNotAnswering(name),
      action: l10n.termuxFixRestart(name),
    ),
    TermuxProblem.notInstalled => TermuxProblemWords(
      line: l10n.termuxProblemNotInstalled,
      action: l10n.termuxFixGetTermux,
    ),
    TermuxProblem.outdated => TermuxProblemWords(
      line: l10n.termuxProblemOutdated,
      action: l10n.termuxFixGetCurrentTermux,
    ),
    TermuxProblem.unknown => TermuxProblemWords(
      line: l10n.termuxProblemUnknown(name),
      action: l10n.commonRetry,
    ),
  };
}

/// Runs the one act that fixes [problem]. Returns true when the app may
/// look again at once (access was granted, or [retry]/[restart] ran);
/// false when the fix happens outside the app and the next look comes when
/// the person returns (the hosts re-read on resume).
///
/// Access is asked with Android's own question; when Android no longer
/// shows it, the app's settings page opens instead.
Future<bool> fixTermuxProblem(
  BuildContext context,
  TermuxProblem problem, {
  Future<void> Function()? restart,
  Future<void> Function()? retry,
}) async {
  switch (problem) {
    case TermuxProblem.accessNeeded || TermuxProblem.accessBlocked:
      final answer = await TermuxAccess.request();
      if (answer == TermuxAccessAnswer.permanentlyDenied) {
        await TermuxBridge.openAppSettings();
        return false;
      }
      return answer == TermuxAccessAnswer.granted;
    case TermuxProblem.otherAppsOff:
      await showTermuxOtherAppsSheet(context);
      return false;
    case TermuxProblem.asleep:
      await TermuxBridge.openTermux();
      return false;
    case TermuxProblem.notInstalled || TermuxProblem.outdated:
      await openExternalLink(context, termuxGetUrl);
      return false;
    case TermuxProblem.notAnswering:
      if (restart != null) {
        await restart();
        return true;
      }
      await retry?.call();
      return retry != null;
    case TermuxProblem.unknown:
      await retry?.call();
      return retry != null;
  }
}

/// Termux refuses commands from other apps: the one line that allows them,
/// ready to copy, and Termux one tap away. The app looks again when the
/// person comes back.
Future<void> showTermuxOtherAppsSheet(BuildContext context) async {
  final l10n = lookupAppLocalizations(Localizations.localeOf(context));
  NavigatorState? sheet;
  await showKitSheet<void>(
    context,
    sheetKey: const ValueKey('termux-other-apps-sheet'),
    title: l10n.termuxOtherAppsTitle,
    icon: AppIconography.terminal,
    body: (sheetContext) {
      sheet = Navigator.of(sheetContext);
      final tokens = KitTokens.of(sheetContext);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          KitText(l10n.termuxOtherAppsBody, tone: KitTextTone.secondary),
          SizedBox(height: tokens.space3),
          KitCodeBlock(
            key: const ValueKey('termux-other-apps-line'),
            text: TermuxBridge.unlockCommand,
            kind: KitCodeKind.command,
            wrap: true,
            showWrapToggle: false,
            copyKey: const ValueKey('termux-other-apps-copy'),
          ),
        ],
      );
    },
    primary: KitAction(
      key: const ValueKey('termux-other-apps-open'),
      label: l10n.termuxFixOpenTermux,
      onPressed: () async {
        // The line goes with the person: it is on the clipboard when
        // Termux opens.
        // The copy reaches the clipboard before Termux opens (the platform
        // messages keep their order); its announcement need not be waited.
        // The line is app-authored and holds no secret, so redaction leaves
        // it whole.
        unawaited(KitCopy.copy(context, TermuxBridge.unlockCommand));
        await TermuxBridge.openTermux();
        await sheet?.maybePop();
      },
    ),
  );
}
