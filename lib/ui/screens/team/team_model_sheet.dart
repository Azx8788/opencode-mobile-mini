/// The team's model choice: a sheet of the models this phone's OpenCode can
/// use (its catalog, through the connection), plus "Same as this phone's
/// OpenCode". Returns the choice; applying it is the caller's.
library;

import 'package:flutter/material.dart';

import '../../../domain/model_name_order.dart';
import '../../../domain/server_gateway.dart' show CatalogModel;
import '../../../l10n/app_localizations.dart';
import '../../../state/connection.dart';
import '../../../state/team_model.dart';
import '../../app_theme.dart';
import '../../kit/kit.dart';

/// What the person picked; [spec] null is the phone's own default.
class TeamModelChoice {
  const TeamModelChoice(this.spec);
  final String? spec;
}

Future<TeamModelChoice?> showTeamModelSheet(
  BuildContext context, {
  required ConnectionController connection,
  required String? current,
  String? title,
  String? defaultTitle,
  String? defaultHint,
}) {
  final l10n = lookupAppLocalizations(Localizations.localeOf(context));
  return showKitSheet<TeamModelChoice>(
    context,
    title: title ?? l10n.teamModelSheetTitle,
    subtitle: l10n.teamModelSheetNote,
    icon: AppIconography.model,
    height: KitSheetHeight.full,
    sheetKey: const ValueKey('team-model-sheet'),
    body: (sheetContext) => ListenableBuilder(
      listenable: connection,
      builder: (context, _) {
        final models = [
          for (final model
              in connection.catalog?.models ?? const <CatalogModel>[])
            if (model.enabled &&
                teamModelSpec(model.providerID, model.id) != null)
              model,
        ]..sort((a, b) => compareModelNames(a.name, b.name));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KitRow(
              key: const ValueKey('team-model-default'),
              title: defaultTitle ?? l10n.teamModelDefault,
              supporting: TextSpan(
                text: defaultHint ?? l10n.teamModelDefaultHint,
              ),
              selected: current == null,
              onTap: () =>
                  Navigator.of(sheetContext).pop(const TeamModelChoice(null)),
            ),
            if (models.isEmpty)
              KitRow(
                key: const ValueKey('team-model-none'),
                title: l10n.teamModelNoneLoaded,
                titleMaxLines: 3,
                enabled: false,
              ),
            for (final model in models)
              KitRow(
                key: ValueKey('team-model-${model.providerID}-${model.id}'),
                title: model.name,
                supporting: TextSpan(text: model.providerID),
                selected: teamModelSpec(model.providerID, model.id) == current,
                onTap: () => Navigator.of(sheetContext).pop(
                  TeamModelChoice(teamModelSpec(model.providerID, model.id)),
                ),
              ),
          ],
        );
      },
    ),
  );
}
