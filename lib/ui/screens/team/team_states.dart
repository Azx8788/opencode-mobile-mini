/// The whole-screen states the AI Team screens share (design standard §3,
/// §4): connecting, not answering after 8 s, and the honest errors. The
/// home, the run and the agent screen each showed the same three states
/// with their own spinner and error block; they now come from here, as
/// [KitStateView] pages under the screen's one [KitLoadingBar].
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../builtin/team/builtin_team.dart'
    show
        BuiltinTeam,
        BuiltinTeamException,
        BuiltinTeamStage,
        BuiltinTeamStartProgress,
        BuiltinTeamStartStep;
import '../../../builtin/team/builtin_team_job.dart';
import '../../../domain/orchestration_gateway.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/orchestration.dart';
import '../../../state/profiles.dart' show OrchestrationProvider;
import '../../app_theme.dart';
import '../../kit/kit.dart';
import '../../kit/scenes/team_scenes.dart';
import '../../widgets/builtin_team_section.dart'
    show builtinTeamElapsedText, builtinTeamFailureText, sharedBuiltinTeam;
import '../../widgets/grace_timer.dart';
import '../../widgets/product_states.dart'
    show productErrorDetails, productErrorText;
import '../../widgets/team_vocabulary.dart';

/// Whether [controller] has nothing to show because it failed: the probe
/// failed, or it is ready with no data and an error.
bool teamScreenFailed(OrchestrationController controller) =>
    controller.phase == OrchestrationPhase.failed ||
    (controller.phase == OrchestrationPhase.ready &&
        !controller.snapshot.hasData &&
        controller.lastError != null);

/// Whether [controller] is still getting its first data.
bool teamScreenLoading(OrchestrationController controller) =>
    !teamScreenFailed(controller) &&
    !(controller.phase == OrchestrationPhase.ready &&
        controller.snapshot.hasData);

/// The state page for [controller] while it cannot show data, or null once
/// it can. Keys: `<prefix>-error`, `<prefix>-loading` and, after 8 s of
/// connecting, `<prefix>-not-answering`.
Widget? teamScreenState(
  BuildContext context, {
  required OrchestrationController controller,
  required String keyPrefix,
  required VoidCallback? onRetry,
}) {
  final l10n = lookupAppLocalizations(Localizations.localeOf(context));
  final retry = KitAction(
    key: ValueKey('$keyPrefix-retry'),
    label: l10n.teamUiCardRetry,
    onPressed: onRetry,
    icon: AppIcons.retry,
  );
  if (teamScreenFailed(controller)) {
    final error = controller.lastError;
    // The team inside this app does not answer: it stopped (an app update
    // or Android ending the app takes it down). Offer the start that fixes
    // it, not a Tailscale hint for a computer that is not involved.
    if (BuiltinTeam.isBuiltinConfig(controller.config) &&
        (error == null || error.kind == OrchestrationErrorKind.unreachable)) {
      return _phoneTeamStopped(
        l10n,
        controller: controller,
        keyPrefix: keyPrefix,
        retry: retry,
        details: error?.message.trim(),
      );
    }
    final (icon, tone, title) = teamErrorState(l10n, error?.kind);
    final details = error?.message.trim();
    // The host is starting: the team wakes up while the person waits.
    final starting = error?.kind == OrchestrationErrorKind.cityNotRunning;
    return KitStateView(
      key: ValueKey('$keyPrefix-error'),
      icon: icon,
      tone: tone,
      illustration: starting ? const TeamWakingScene() : null,
      illustrationAmbient: starting,
      title: title,
      body: teamErrorCopy(l10n, error?.kind),
      primary: retry,
      details: details == null || details.isEmpty ? null : details,
    );
  }
  if (teamScreenLoading(controller)) {
    final waiting = GraceTimer(
      waiting: true,
      builder: (context, overdue) => overdue
          ? KitStateView(
              key: ValueKey('$keyPrefix-not-answering'),
              icon: AppIconography.cloudOff,
              tone: AppStatusTone.neutral,
              title: l10n.teamUiStateNotAnsweringTitle,
              // What to check, where the team runs (P3.4): the phone's
              // team is still starting; a computer must be on and online.
              body: teamNotAnsweringBody(l10n, controller),
              secondary: retry,
            )
          : KitStateView(
              key: ValueKey('$keyPrefix-loading'),
              icon: AppIconography.agent,
              tone: AppStatusTone.progress,
              title: l10n.teamUiCardLoading,
            ),
    );
    if (!BuiltinTeam.isBuiltinConfig(controller.config)) return waiting;
    // The team on this phone is coming up after an app restart: its steps,
    // not a bare "connecting".
    return _StartWatch(
      controller: controller,
      child: ListenableBuilder(
        listenable: BuiltinTeamStartProgress.shared,
        builder: (context, _) => BuiltinTeamStartProgress.shared.running
            ? _startingPage(l10n, keyPrefix)
            : waiting,
      ),
    );
  }
  return null;
}

/// The steps of the in-app team coming up, one row each: done with how long
/// it took, the current one with its time so far (or that it is taking
/// longer than usual), the rest waiting, and a failed one marked. Every mark
/// comes from [progress]'s polled signals, never from a timer.
List<KitStep> teamStartSteps(
  AppLocalizations l10n,
  BuiltinTeamStartProgress progress, {
  bool active = true,
}) {
  String title(BuiltinTeamStartStep step) => switch (step) {
    BuiltinTeamStartStep.service => l10n.teamStartStepService,
    BuiltinTeamStartStep.answering => l10n.teamStartStepAnswering,
    BuiltinTeamStartStep.store => l10n.teamStartStepStore,
    BuiltinTeamStartStep.agents => l10n.teamStartStepAgents,
  };
  return [
    for (final step in BuiltinTeamStartStep.values)
      () {
        final took = active ? progress.took(step) : null;
        final elapsed = active ? progress.elapsed(step) : null;
        final failed = progress.failedStep == step && progress.error != null;
        final KitMarkState state;
        String? supporting;
        if (failed) {
          state = KitMarkState.failed;
        } else if (took != null) {
          state = KitMarkState.done;
          supporting = l10n.aiteamComponentStageTook(
            builtinTeamElapsedText(took),
          );
        } else if (elapsed != null) {
          state = KitMarkState.working;
          supporting = progress.isSlow(step)
              ? '${l10n.teamStartSlow} · ${builtinTeamElapsedText(elapsed)}'
              : l10n.aiteamComponentStageSoFar(builtinTeamElapsedText(elapsed));
        } else {
          state = KitMarkState.waiting;
        }
        return KitStep(
          key: ValueKey('team-start-step-${step.name}'),
          title: title(step),
          state: state,
          supporting: supporting,
        );
      }(),
  ];
}

KitChecklist _startChecklist(
  AppLocalizations l10n,
  BuiltinTeamStartProgress progress, {
  bool active = true,
}) => KitChecklist(
  checklistKey: const ValueKey('team-start-steps'),
  steps: teamStartSteps(l10n, progress, active: active),
);

/// The page while the in-app team comes up: the illustration, the steps and
/// one bar that is the count of finished steps.
Widget _startingPage(
  AppLocalizations l10n,
  String keyPrefix, {
  bool active = true,
}) {
  final progress = BuiltinTeamStartProgress.shared;
  return KitStateView(
    key: ValueKey('$keyPrefix-team-starting'),
    icon: AppIconography.waiting,
    tone: AppStatusTone.progress,
    illustration: const TeamWakingScene(),
    illustrationAmbient: true,
    title: l10n.aiteamComponentStageStarting,
    progress: KitProgress.known(active ? progress.fraction : 0),
    content: _startChecklist(l10n, progress, active: active),
  );
}

/// Reads the team again once an automatic start finishes: the explicit
/// start reads it itself. Draws nothing of its own.
class _StartWatch extends StatefulWidget {
  const _StartWatch({required this.controller, required this.child});

  final OrchestrationController controller;
  final Widget child;

  @override
  State<_StartWatch> createState() => _StartWatchState();
}

class _StartWatchState extends State<_StartWatch> {
  bool _wasRunning = BuiltinTeamStartProgress.shared.running;

  @override
  void initState() {
    super.initState();
    BuiltinTeamStartProgress.shared.addListener(_changed);
  }

  @override
  void dispose() {
    BuiltinTeamStartProgress.shared.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final progress = BuiltinTeamStartProgress.shared;
    final finished = _wasRunning && !progress.running && progress.error == null;
    _wasRunning = progress.running;
    if (finished && !BuiltinTeamJob.shared.running) {
      unawaited(widget.controller.retry());
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The in-app team does not answer: "Start AI Team on this phone", and its
/// stages while it starts (the app's one team job, so This phone shows the
/// same start). Once it answers, the screen reads the team again.
Widget _phoneTeamStopped(
  AppLocalizations l10n, {
  required OrchestrationController controller,
  required String keyPrefix,
  required KitAction retry,
  required String? details,
}) {
  final job = BuiltinTeamJob.shared;
  Future<void> start() async {
    if (job.running) return;
    final team = sharedBuiltinTeam;
    final notice = l10n.aiteamComponentNotice;
    await job.run(
      stages: const [BuiltinTeamStage.starting, BuiltinTeamStage.waiting],
      work: (onStage) => team.start(notice: notice, onStage: onStage),
    );
    if (job.error == null) await controller.retry();
  }

  final progress = BuiltinTeamStartProgress.shared;
  return _StartWatch(
    controller: controller,
    child: ListenableBuilder(
      listenable: Listenable.merge([job, progress]),
      builder: (context, _) {
        if (job.running || progress.running) {
          return _startingPage(l10n, keyPrefix, active: progress.running);
        }
        final failure = job.error ?? progress.error;
        final failureDetail = switch (failure) {
          null => null,
          final BuiltinTeamException error => error.detail.trim(),
          final Object error => productErrorDetails(error),
        };
        final shownDetails = failureDetail ?? details;
        return KitStateView(
          key: ValueKey('$keyPrefix-error'),
          icon: AppIconography.cloudOff,
          tone: AppStatusTone.neutral,
          title: l10n.teamUiStatePhoneStoppedTitle,
          body: switch (failure) {
            null => l10n.teamUiStatePhoneStoppedBody,
            final BuiltinTeamException error => builtinTeamFailureText(
              l10n,
              error,
            ),
            final Object error => l10n.aiteamComponentFailed(
              productErrorText(error, l10n: l10n),
            ),
          },
          content: progress.failedStep == null
              ? null
              : _startChecklist(l10n, progress),
          primary: KitAction(
            key: ValueKey('$keyPrefix-start-team'),
            label: failure == null
                ? l10n.teamUiStartOnPhone
                : l10n.teamStartAgain,
            icon: AppIconography.play,
            onPressed: () => unawaited(start()),
          ),
          secondary: retry,
          details: shownDetails == null || shownDetails.isEmpty
              ? null
              : shownDetails,
        );
      },
    ),
  );
}

/// The not-answering page's one sentence: what the app does and what to
/// check where this team runs.
String teamNotAnsweringBody(
  AppLocalizations l10n,
  OrchestrationController controller,
) => switch (controller.config.provider == OrchestrationProvider.phoneEngine
    ? OrchestrationHostMode.phone
    : (controller.host?.hostMode ?? controller.config.hostMode)) {
  OrchestrationHostMode.phone => l10n.teamUiStateNotAnsweringPhone,
  OrchestrationHostMode.computer => switch (teamComputerName(controller)) {
    final name? => l10n.teamUiStateNotAnsweringComputerNamed(name),
    null => l10n.teamUiStateNotAnsweringComputer,
  },
};

/// The icon, tone and one-line title of an error kind; the body is
/// [teamErrorCopy]. A host that does not answer or refuses plain http is a
/// degraded state, so it is neutral: amber means "needs you" only
/// (docs/design/visual-language-2026-09-26.md, LOOK-4).
(IconData, AppStatusTone, String) teamErrorState(
  AppLocalizations l10n,
  OrchestrationErrorKind? kind,
) => switch (kind) {
  OrchestrationErrorKind.notGasCity => (
    AppIconography.agent,
    AppStatusTone.neutral,
    l10n.teamUiStateNotGasCityTitle,
  ),
  OrchestrationErrorKind.cityNotRunning => (
    AppIconography.waiting,
    AppStatusTone.progress,
    l10n.teamUiStateStartingTitle,
  ),
  OrchestrationErrorKind.plainHttpRefused => (
    AppIconography.secureNetwork,
    AppStatusTone.neutral,
    l10n.teamUiStatePlainHttpTitle,
  ),
  OrchestrationErrorKind.unreachable ||
  OrchestrationErrorKind.readFailed ||
  null => (
    AppIconography.cloudOff,
    AppStatusTone.neutral,
    l10n.teamUiStateUnreachableTitle,
  ),
};

/// The one status line of a working AI Team screen (§5): data from before
/// the host stopped answering, or a refresh that failed. Null when the data
/// is current. It goes into the screen's status slot (`KitScreen.status`),
/// never into its header, so a connection or app line and this one never
/// show at once: the slot draws the most urgent (P4.4). Keys:
/// `<prefix>-stale`, `<prefix>-refresh-failed`.
KitStatus? teamStatusLine(
  BuildContext context, {
  required OrchestrationController controller,
  required String keyPrefix,
  required VoidCallback? onRetry,
}) {
  final l10n = lookupAppLocalizations(Localizations.localeOf(context));
  final at = controller.lastRefreshedAt;
  final action = KitAction(
    key: ValueKey('$keyPrefix-status-retry'),
    label: l10n.teamUiCardRetry,
    onPressed: onRetry,
  );
  if (controller.isStale) {
    return KitStatus(
      kind: KitStatusKind.work,
      id: '$keyPrefix:stale',
      key: ValueKey('$keyPrefix-stale'),
      icon: AppIconography.cloudOff,
      tone: AppStatusTone.neutral,
      message: l10n.teamUiCardStale(
        at == null ? '' : teamClockLabel(context, at),
      ),
      action: action,
    );
  }
  if (controller.lastError?.kind == OrchestrationErrorKind.readFailed &&
      at != null) {
    return KitStatus(
      kind: KitStatusKind.work,
      id: '$keyPrefix:refresh-failed',
      key: ValueKey('$keyPrefix-refresh-failed'),
      icon: AppIconography.warning,
      tone: AppStatusTone.neutral,
      message: l10n.teamUiCardRefreshFailed(teamClockLabel(context, at)),
      action: action,
    );
  }
  return null;
}
