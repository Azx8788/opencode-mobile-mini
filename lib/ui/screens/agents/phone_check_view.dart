import 'package:flutter/material.dart';

import '../../../domain/phone_agent_host.dart';
import '../../../l10n/app_localizations.dart';
import '../../kit/kit.dart';
import 'agents_text.dart';

/// The phone check as four steps, each passed, failed or waiting, with a
/// plain sentence under them. [result] null means it is running now;
/// [progress] names the active step and any measured download bytes.
class AgentPhoneCheckView extends StatelessWidget {
  const AgentPhoneCheckView({
    super.key,
    required this.agent,
    required this.result,
    this.progress,
  });

  /// The agent's name.
  final String agent;
  final AgentPhoneCheckResult? result;
  final AgentSetupProgress? progress;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final result = this.result;
    final progress = this.progress;
    final activeStep = progress?.checkStep ?? AgentPhoneCheckStep.install;
    final passed = result == null
        ? AgentPhoneCheckStep.values.take(activeStep.index).toSet()
        : result.completed.toSet();
    // A signed-out agent is installed and healthy: it is waiting for the
    // person, not broken, so it gets no failure mark and no failure headline.
    final needsSignIn =
        result != null &&
        !result.passed &&
        result.failure == AgentHostFailure.needsSignIn;
    final failedAt = result == null || result.passed || needsSignIn
        ? null
        : AgentPhoneCheckStep.values
              .where((step) => !passed.contains(step))
              .firstOrNull;
    final workingAt = result == null ? activeStep : null;
    final downloading =
        result == null &&
        progress?.phase == AgentSetupPhase.installing &&
        activeStep == AgentPhoneCheckStep.install;
    final component = switch (progress?.componentId) {
      'agent-paseo' => 'Paseo',
      'agent-node' => l10n.agentsCheckPhoneTools,
      _ => agent,
    };
    final downloaded = progress?.downloadedBytes;
    final total = progress?.totalBytes;
    final downloadCaption = downloaded == null
        ? (progress?.componentId == 'agent-paseo' ||
                  progress?.componentId == 'agent-node'
              ? l10n.agentsCheckPreparing(KitBidi.auto(component))
              : l10n.agentsCheckDownloading(KitBidi.auto(component)))
        : total == null
        ? l10n.agentsCheckDownloadUnknown(
            KitBidi.auto(component),
            agentFreedSize(downloaded),
          )
        : l10n.agentsCheckDownload(
            KitBidi.auto(component),
            agentFreedSize(downloaded),
            agentFreedSize(total),
          );
    final fraction = agentInstallBarFraction(done: downloaded, total: total);
    final words = result == null
        ? l10n.agentsCheckRunning(KitBidi.auto(agent))
        : result.passed
        ? l10n.agentsCheckPassed(KitBidi.auto(agent))
        : needsSignIn
        // The sign-in text already says the agent is installed and what to do.
        ? agentHostFailureText(l10n, result.failure)
        : '${l10n.agentsCheckFailed(KitBidi.auto(agent))} '
              '${agentHostFailureText(l10n, result.failure)}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KitRowGroup(
          margin: EdgeInsets.zero,
          leadingIcons: false,
          children: [
            for (final step in AgentPhoneCheckStep.values)
              KitRow(
                key: ValueKey('agents-check-${step.name}'),
                title: agentCheckStepName(l10n, step),
                below: step == AgentPhoneCheckStep.install && downloading
                    ? KitProgressView(
                        progress: fraction == null
                            ? KitProgress.waiting(
                                key: const ValueKey('agents-check-download'),
                                caption: downloadCaption,
                              )
                            : KitProgress.known(
                                fraction.clamp(0.0, 1.0),
                                key: const ValueKey('agents-check-download'),
                                caption: downloadCaption,
                              ),
                      )
                    : null,
                leading: KitTaskMark(
                  state: passed.contains(step)
                      ? KitTaskState.done
                      : step == failedAt
                      ? KitTaskState.failed
                      : step == workingAt
                      ? KitTaskState.working
                      : KitTaskState.waiting,
                ),
              ),
          ],
        ),
        SizedBox(height: tokens.space3),
        KitText(
          words,
          key: const ValueKey('agents-check-words'),
          role: KitTextRole.secondary,
          tone: KitTextTone.secondary,
        ),
        if (result != null && !result.passed && !needsSignIn)
          KitDetailsFold(
            foldKey: const ValueKey('agents-check-details'),
            textKey: const ValueKey('agents-check-details-text'),
            text:
                result.details ??
                'Check: ${result.failure?.name ?? "unavailable"}\n'
                    'Completed: ${result.completed.map((step) => step.name).join(", ")}',
          ),
      ],
    );
  }
}
