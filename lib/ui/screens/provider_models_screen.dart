import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/models.dart' show ModelRef;
import '../../domain/server_gateway/value_types_core.dart'
    show CatalogModel, CatalogProvider;
import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import 'provider_test_screen.dart';

AppLocalizations _l10nOf(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

/// Every provider the server knows and every model it serves.
///
/// The model picker answers "which model do I use"; this page answers "what
/// does this provider actually offer, and does it work from this phone".
/// Models come from the server's catalogue — the same list the picker uses —
/// so nothing here is a second, drifting inventory.
class ProviderModelsScreen extends StatelessWidget {
  const ProviderModelsScreen({super.key, required this.controller});

  final ConnectionController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10nOf(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.providerModelsTitle)),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final catalog = controller.catalog;
          if (catalog == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final providers = [
            for (final provider in catalog.providers)
              if (provider.enabled) provider,
          ]..sort((a, b) => a.name.compareTo(b.name));
          if (providers.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  l10n.providerModelsEmpty,
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  l10n.providerModelsHint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              for (final provider in providers)
                _ProviderSection(
                  key: ValueKey('provider-models-${provider.id}'),
                  controller: controller,
                  provider: provider,
                  models: [
                    for (final model in catalog.models)
                      if (model.providerID == provider.id && model.enabled)
                        model,
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ProviderSection extends StatelessWidget {
  const _ProviderSection({
    super.key,
    required this.controller,
    required this.provider,
    required this.models,
  });

  final ConnectionController controller;
  final CatalogProvider provider;
  final List<CatalogModel> models;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10nOf(context);
    if (models.isEmpty) return const SizedBox.shrink();
    final shown = models
        .where(
          (model) => controller.isModelEnabled(
            ModelRef(providerID: model.providerID, modelID: model.id),
          ),
        )
        .length;
    return ExpansionTile(
      key: PageStorageKey('provider-section-${provider.id}'),
      title: Text(provider.name.isEmpty ? provider.id : provider.name),
      subtitle: Text(l10n.providerModelsCount(shown, models.length)),
      children: [for (final model in models) _modelRow(context, l10n, model)],
    );
  }

  Widget _modelRow(
    BuildContext context,
    AppLocalizations l10n,
    CatalogModel model,
  ) {
    final ref = ModelRef(providerID: model.providerID, modelID: model.id);
    final enabled = controller.isModelEnabled(ref);
    return ListTile(
      key: ValueKey('provider-model-${provider.id}-${model.id}'),
      dense: true,
      title: Text(model.name.isEmpty ? model.id : model.name),
      subtitle: Text(model.id),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: () => openProviderTest(
              context,
              controller: controller,
              providerName: provider.name.isEmpty ? provider.id : provider.name,
              providerID: provider.id,
              model: model.id,
            ),
            child: Text(l10n.providerModelsTest),
          ),
          Switch(
            key: ValueKey('provider-model-switch-${provider.id}-${model.id}'),
            value: enabled,
            onChanged: (value) =>
                unawaited(controller.setModelEnabled(ref, value)),
          ),
        ],
      ),
    );
  }
}

/// Opens the real test for one model: the server opens a session with it,
/// sends one short message, and deletes the session again.
///
/// Nothing is prefilled from the provider id any more. The test does not ask
/// this app for an address or a key — the server uses the entry in its own
/// config, which is the only configuration a real request will use either.
Future<void> openProviderTest(
  BuildContext context, {
  required ConnectionController controller,
  required String providerID,
  required String providerName,
  required String model,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => ProviderTestScreen(
        controller: controller,
        providerID: providerID,
        providerName: providerName,
        models: [model],
      ),
    ),
  );
}
