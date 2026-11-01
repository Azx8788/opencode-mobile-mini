import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../state/managed_move.dart';
import '../app_iconography.dart';
import '../kit/kit.dart';

/// The page the app shows while the automatic OpenCode 1 -> 2 move runs, and
/// when it could not finish. Calm progress first; a failure says why in plain
/// words with the technical text under Details (with Copy) and Try again.
///
/// It stands on the kit ground, which supplies the Material the text needs: a
/// bare [KitScreen] paints none, and on the owner's phone (2026-10-16) every
/// word fell back to Flutter's yellow-underlined default style.
class ManagedMoveView extends StatelessWidget {
  const ManagedMoveView({
    super.key,
    required this.failure,
    required this.onTryAgain,
    this.retry = 0,
    this.retries = 0,
  });

  /// Null while the move runs.
  final ManagedMoveAttempt? failure;
  final VoidCallback onTryAgain;

  /// Which quiet retry is waiting (0 before the first), out of [retries].
  final int retry;
  final int retries;

  static const stateKey = ValueKey('managed-opencode2-upgrade');

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final failure = this.failure;
    final Widget state = failure == null
        ? KitStateView(
            key: stateKey,
            icon: AppIconography.sync,
            title: l10n.openCode2UpgradeTitle,
            body: retry > 0
                ? l10n.openCode2MoveRetrying(retry, retries)
                : l10n.openCode2MoveProgress,
            progress: const KitProgress.waiting(),
          )
        : KitStateView.error(
            key: stateKey,
            icon: AppIconography.warning,
            title: l10n.phoneServerCardFailedTitle,
            body: switch (failure.reason!) {
              ManagedMoveReason.phoneNotReady =>
                l10n.openCode2MoveFailedNotReady,
              ManagedMoveReason.separateHistory =>
                l10n.openCode2MoveFailedSeparateHistory,
              ManagedMoveReason.moveStopped => l10n.openCode2MoveFailedStopped,
              ManagedMoveReason.notConfirmed =>
                l10n.openCode2MoveFailedNotConfirmed,
            },
            errorKind: KitErrorKind.other,
            details: failure.details,
            retry: failure.reason!.retryable
                ? KitAction(label: l10n.commonRetry, onPressed: onTryAgain)
                : null,
          );
    return KitSurface(
      level: KitSurfaceLevel.ground,
      shape: KitShape.square,
      padding: KitSurfacePadding.none,
      clip: false,
      child: SafeArea(child: KitScreen(body: state)),
    );
  }
}
