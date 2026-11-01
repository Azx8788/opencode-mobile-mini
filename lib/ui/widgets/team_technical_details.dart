/// The AI Team plugin's identity and Technical details pieces (02-ux §8):
/// label-over-value identity rows, raw provider values with a copy button
/// and the side-by-side term rows, shared by the Settings sheet (TEAM-106)
/// and the info button on the AI Team home (TEAM-108), which opens
/// [TeamHostDetailsSheet]: everything the home's one-phrase host line
/// leaves out (address, version, city, access, the host kind's line).
///
/// Kit only (shared-team-2): every piece is built from kit parts. The
/// host sheet is a [showKitSheet]; its technical values sit in one
/// [KitDetailsFold], each value once (map: team-host-details-sheet
/// "dedupe values", embedded-team-technical-value "48 dp copy on the
/// rail").
library;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../state/orchestration.dart';
import '../../state/profiles.dart';
import '../app_iconography.dart';
import '../kit/kit_divider.dart';
import '../kit/kit_icon_button.dart';
import '../kit/kit_redact.dart';
import '../kit/kit_row.dart';
import '../kit/kit_sheet.dart';
import '../kit/kit_surface.dart';
import '../kit/kit_technical_value.dart';
import '../kit/kit_text.dart';
import '../kit/kit_tokens.dart';
import 'team_discovery_card.dart' show teamHostDisclaimer, teamHostKindFor;

AppLocalizations _copy(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

/// Whether the phone can only watch: no front on the host and no control
/// capability from the adapter.
bool teamReadOnly(OrchestrationConfig config, OrchestrationController? c) =>
    !(config.front || (c?.capabilities.controlRespond ?? false));

/// Opens the host's Technical details in the kit's one sheet frame.
Future<void> showTeamHostDetailsSheet(
  BuildContext context,
  OrchestrationController controller,
) {
  final l10n = _copy(context);
  return showKitSheet<void>(
    context,
    title: l10n.teamUiTechnicalDetails,
    subtitle: l10n.teamUiRowTitle,
    icon: AppIconography.info,
    sheetKey: const ValueKey('team-home-host-sheet'),
    body: (_) => TeamHostDetailsSheet(controller: controller),
  );
}

/// The host sheet's body: where the host runs and what that means, what
/// the phone may do there, the product-to-provider terms, then the raw
/// values (provider, version, city, address, the host's last answer) in
/// one fold, each once and copyable. Read-only; the switches live in
/// Settings › Plugins.
///
/// The fold starts open: the person opened this sheet to read exactly
/// these values, so a second "Details" tap would only hide them.
class TeamHostDetailsSheet extends StatelessWidget {
  const TeamHostDetailsSheet({super.key, required this.controller});

  final OrchestrationController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = _copy(context);
    final tokens = KitTokens.of(context);
    final config = controller.config;
    final host = controller.host;
    final hostMode = host?.hostMode ?? config.hostMode;
    final city = config.city.isNotEmpty ? config.city : (host?.city ?? '');
    final readOnly = teamReadOnly(config, controller);
    final provider = host?.provider ?? config.provider.name;
    final address = host?.url ?? config.url;
    final version = host?.version;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A panel set into the sheet (VL §5): the host's two plain facts.
        KitSurface.inset(
          padding: KitSurfacePadding.none,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // How this kind of host behaves (03-onboarding §4, TEAM-206):
              // one line, here with the host's other facts rather than on
              // the Work tab's section.
              KitRow(
                title: l10n.teamUiLabelHost,
                supporting: TextSpan(
                  text: switch (hostMode) {
                    OrchestrationHostMode.computer =>
                      l10n.teamUiHostModeComputer,
                    OrchestrationHostMode.phone => l10n.teamUiHostModePhone,
                  },
                ),
                below: KitText(
                  teamHostDisclaimer(l10n, teamHostKindFor(config, hostMode)),
                  key: const ValueKey('team-host-disclaimer'),
                  role: KitTextRole.secondary,
                ),
              ),
              const KitDivider(inset: KitDividerInset.gutter),
              KitRow(
                title: l10n.teamUiLabelAccess,
                supporting: TextSpan(
                  text: readOnly
                      ? l10n.teamUiAccessReadOnly
                      : l10n.teamUiAccessControls,
                ),
                below: readOnly
                    ? KitText(
                        l10n.teamUiReadOnlyBody,
                        key: const ValueKey('team-home-host-read-only'),
                        role: KitTextRole.secondary,
                      )
                    : null,
              ),
            ],
          ),
        ),
        SizedBox(height: tokens.sectionGap),
        // The glossary: the product word, then the provider's (engine
        // words live here, never on the lists).
        Padding(
          padding: EdgeInsetsDirectional.only(
            start: tokens.space1,
            bottom: tokens.labelGap,
          ),
          child: Semantics(
            header: true,
            child: KitText(l10n.teamUiTermsHeading, role: KitTextRole.label),
          ),
        ),
        KitSurface.inset(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final term in [
                l10n.teamUiTermTeam,
                l10n.teamUiTermProject,
                l10n.teamUiTermRun,
                l10n.teamUiTermWork,
                l10n.teamUiTermAgent,
              ])
                TeamTermRow(term),
            ],
          ),
        ),
        SizedBox(height: tokens.sectionGap),
        KitDetailsFold(
          label: l10n.teamUiHomeHostRawHeading,
          initiallyExpanded: true,
          values: [
            KitTechnicalValue(l10n.teamUiLabelProvider, provider),
            KitTechnicalValue(
              l10n.teamUiLabelVersion,
              version ?? l10n.teamUiVersionUnknown,
              copyable: version != null,
            ),
            if (city.isNotEmpty) KitTechnicalValue(l10n.teamUiLabelCity, city),
            if (address.isNotEmpty)
              KitTechnicalValue(l10n.teamUiLabelAddress, address),
          ],
          // The host's own words, masked rather than refused: an error
          // body may quote a header.
          notes: [
            if (controller.lastError != null) l10n.teamUiTechnicalLastAnswer,
          ],
          text: controller.lastError?.message,
        ),
      ],
    );
  }
}

/// Label above value so the pair still fits at 320dp × 2.5x; ids and URLs
/// stay LTR in RTL layouts ([KitText.mono]).
class TeamIdentityRow extends StatelessWidget {
  const TeamIdentityRow({
    super.key,
    required this.label,
    required this.value,
    this.mono = false,
  });

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.space1),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: tokens.space3,
        children: [
          KitText(label, role: KitTextRole.secondary),
          if (mono)
            KitText.mono(value)
          else
            KitText(
              value,
              role: KitTextRole.secondary,
              tone: KitTextTone.primary,
            ),
        ],
      ),
    );
  }
}

/// A raw provider value with its copy button (02-ux §8): the label over
/// the value in mono, laid out left to right, selectable, and a 48 dp
/// copy target on the rail at the end. The value is masked by
/// [KitRedact] where it is shown and copied; copying goes through the
/// kit's one copy service (a check in place, "Copied" announced once,
/// never a snackbar).
///
/// It draws one value where a screen lists values of its own; a page or
/// sheet that holds several passes them to [KitDetailsFold] as
/// [KitTechnicalValue]s instead ([asKit]), so each shows once.
class TeamTechnicalValue extends StatelessWidget {
  const TeamTechnicalValue({
    super.key,
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  /// This value as the kit's [KitTechnicalValue], for a [KitDetailsFold].
  KitTechnicalValue get asKit =>
      KitTechnicalValue(label, value, copyable: value.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final l10n = _copy(context);
    final shown = value.isEmpty ? '—' : KitRedact.text(value);
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: tokens.minTarget),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: tokens.space1),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                container: true,
                label: l10n.kitDetailsValueSpoken(label, KitBidi.ltr(shown)),
                excludeSemantics: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    KitText(label, role: KitTextRole.secondary),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: KitText.mono(shown, selectable: true),
                    ),
                  ],
                ),
              ),
            ),
            if (value.isNotEmpty) ...[
              SizedBox(width: tokens.space2),
              KitIconButton.copy(
                text: () => shown,
                tooltip: l10n.kitCopyValue(_lowerFirst(label)),
                size: tokens.smallIconSize,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// "Product · provider" term pair; the product word leads in `text1`, the
/// Gas City term follows in `text2`.
class TeamTermRow extends StatelessWidget {
  const TeamTermRow(this.term, {super.key});

  final String term;

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final parts = term.split(' · ');
    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.space1),
      child: KitText.rich(
        TextSpan(
          children: [
            TextSpan(text: parts.first),
            if (parts.length > 1)
              TextSpan(
                text: ' · ${parts.sublist(1).join(' · ')}',
                style: KitText.styleOf(context, KitTextRole.secondary),
              ),
          ],
        ),
        role: KitTextRole.secondary,
        tone: KitTextTone.primary,
      ),
    );
  }
}

/// "Address" → "address" for "Copy address"; an acronym ("URL", "PID")
/// keeps its case.
String _lowerFirst(String s) {
  if (s.length < 2) return s.toLowerCase();
  final second = s.substring(1, 2);
  // A capital second letter marks an acronym.
  if (second.toLowerCase() != second) return s;
  return s.substring(0, 1).toLowerCase() + s.substring(1);
}
