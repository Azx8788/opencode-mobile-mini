/// The host's supervision policy on the phone (TEAM-207; 02-ux §7 and
/// §4.1): a read-only "Supervision · Balanced" line with the host's
/// boundaries as chips, appended under the run's state header, and the
/// same boundaries as the Start-a-run sheet's **Boundaries** row. Both
/// render from [OrchestrationController.policy] and are absent (not
/// hidden: no widget in the tree) while the controller has none — a bare
/// supervisor, the fixture, or a front without the route.
///
/// Nothing here is editable: the level and the boundaries are the host
/// owner's config (`<state-dir>/rigs/<rig>.json`), and the helper line
/// says so.
///
/// Kit only (KIT-1): [KitIcon], [KitText], [KitChip] on a [KitChipWrap];
/// spacing from [KitTokens].
library;

import 'package:flutter/widgets.dart';

import '../../../domain/orchestration_gateway.dart';
import '../../../l10n/app_localizations.dart';
import '../../app_iconography.dart';
import '../../kit/kit_chip.dart';
import '../../kit/kit_icon.dart';
import '../../kit/kit_text.dart';
import '../../kit/kit_tokens.dart';

AppLocalizations _copy(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

/// The localised name of a host-reported supervision level; the same words
/// as the Start-a-run choices.
String teamPolicySupervisionName(
  AppLocalizations l10n,
  OrchestrationSupervision level,
) => switch (level) {
  OrchestrationSupervision.high => l10n.teamUiStartRunSupervisionHigh,
  OrchestrationSupervision.balanced => l10n.teamUiStartRunSupervisionBalanced,
  OrchestrationSupervision.autonomous =>
    l10n.teamUiStartRunSupervisionAutonomous,
};

/// The run overview's policy block: supervision line, boundary chips, and
/// the "set on the host" helper.
class TeamPolicyBlock extends StatelessWidget {
  const TeamPolicyBlock({super.key, required this.policy});

  final OrchestrationPolicy policy;

  @override
  Widget build(BuildContext context) {
    final l10n = _copy(context);
    final tokens = KitTokens.of(context);
    final level = teamPolicySupervisionName(l10n, policy.supervision);
    final rig = policy.rig;
    return Semantics(
      container: true,
      label: l10n.teamUiPolicySemantics(
        level,
        policy.boundaries.isEmpty
            ? l10n.teamUiPolicyBoundariesNone
            : policy.boundaries.map((b) => b.text).join(', '),
      ),
      child: Column(
        key: const ValueKey('team-run-policy'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const KitIcon(
                AppIconography.policy,
                size: KitIconSize.small,
                tone: KitTextTone.secondary,
              ),
              SizedBox(width: tokens.space2),
              Expanded(
                child: Wrap(
                  spacing: tokens.space2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    KitText(
                      l10n.teamUiPolicySupervision(level),
                      key: const ValueKey('team-run-policy-supervision'),
                      role: KitTextRole.rowTitle,
                    ),
                    if (rig != null && rig.isNotEmpty)
                      KitText(
                        l10n.teamUiPolicyRig(rig),
                        key: const ValueKey('team-run-policy-rig'),
                        role: KitTextRole.secondary,
                      ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: tokens.space2),
          TeamBoundaryChips(
            key: const ValueKey('team-run-policy-boundaries'),
            boundaries: policy.boundaries,
            keyPrefix: 'team-run-policy-boundary',
          ),
          SizedBox(height: tokens.space1),
          KitText(
            l10n.teamUiPolicyFromHost,
            key: const ValueKey('team-run-policy-from-host'),
            role: KitTextRole.secondary,
          ),
        ],
      ),
    );
  }
}

/// The boundaries as read-only chips, or the "none set" line.
class TeamBoundaryChips extends StatelessWidget {
  const TeamBoundaryChips({
    super.key,
    required this.boundaries,
    required this.keyPrefix,
  });

  final List<PolicyBoundary> boundaries;

  /// Each chip is keyed `<keyPrefix>-<boundary key>`.
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final l10n = _copy(context);
    if (boundaries.isEmpty) {
      return KitText(
        l10n.teamUiPolicyBoundariesNone,
        key: ValueKey('$keyPrefix-none'),
        role: KitTextRole.secondary,
      );
    }
    return KitChipWrap(
      children: [
        for (final boundary in boundaries)
          KitChip(
            key: ValueKey('$keyPrefix-${boundary.key}'),
            icon: AppIconography.shield,
            label: boundary.text,
          ),
      ],
    );
  }
}

/// The Start-a-run sheet's **Boundaries** row (02-ux §7): the label, the
/// chips and the read-only helper.
class TeamBoundariesRow extends StatelessWidget {
  const TeamBoundariesRow({super.key, required this.policy});

  final OrchestrationPolicy policy;

  @override
  Widget build(BuildContext context) {
    final l10n = _copy(context);
    final tokens = KitTokens.of(context);
    return Column(
      key: const ValueKey('team-start-run-boundaries'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        KitText(l10n.teamUiPolicyBoundariesLabel, role: KitTextRole.label),
        SizedBox(height: tokens.space2),
        TeamBoundaryChips(
          boundaries: policy.boundaries,
          keyPrefix: 'team-start-run-boundary',
        ),
        SizedBox(height: tokens.space1),
        KitText(
          l10n.teamUiPolicyFromHost,
          key: const ValueKey('team-start-run-boundaries-from-host'),
          role: KitTextRole.secondary,
        ),
      ],
    );
  }
}
