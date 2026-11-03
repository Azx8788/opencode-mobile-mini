import 'package:flutter/material.dart';

import '../../domain/custom_provider.dart';
import '../../domain/server_gateway/value_types_core.dart'
    show CatalogModel, CatalogProvider;
import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import 'provider_probe_screen.dart';

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
                child: Text(l10n.providerModelsEmpty, textAlign: TextAlign.center),
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
                  provider: provider,
                  models: [
                    for (final model in catalog.models)
                      if (model.providerID == provider.id && model.enabled) model,
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
    required this.provider,
    required this.models,
  });

  final CatalogProvider provider;
  final List<CatalogModel> models;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10nOf(context);
    if (models.isEmpty) return const SizedBox.shrink();
    return ExpansionTile(
      key: PageStorageKey('provider-section-${provider.id}'),
      title: Text(provider.name.isEmpty ? provider.id : provider.name),
      subtitle: Text('${models.length}'),
      children: [
        for (final model in models)
          ListTile(
            key: ValueKey('provider-model-${provider.id}-${model.id}'),
            dense: true,
            title: Text(model.name.isEmpty ? model.id : model.name),
            subtitle: Text(model.id),
            trailing: TextButton(
              onPressed: () => openProviderProbe(
                context,
                providerName: provider.name.isEmpty
                    ? provider.id
                    : provider.name,
                model: model.id,
                providerID: provider.id,
              ),
              child: Text(l10n.providerModelsTest),
            ),
          ),
      ],
    );
  }
}

/// Opens the five checks, pre-filling what can be known from the provider id.
///
/// The base URL is a convenience, not a claim: providers the server owns do
/// not expose their endpoint through the catalogue, so the well-known ones
/// are filled in and everything else starts empty. The key is never read
/// from the server — the check asks for it and keeps it in memory only.
Future<void> openProviderProbe(
  BuildContext context, {
  required String providerName,
  required String model,
  required String providerID,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => ProviderProbeScreen(
        providerName: providerName,
        model: model,
        baseUrl: providerProbeBaseUrl(providerID),
        protocol: providerProbeProtocol(providerID),
      ),
    ),
  );
}

/// Well-known endpoints, matched on the provider id OpenCode uses.
String providerProbeBaseUrl(String providerID) {
  final id = providerID.toLowerCase();
  for (final entry in _knownBaseUrls.entries) {
    if (id == entry.key || id.startsWith('${entry.key}-')) return entry.value;
  }
  return '';
}

ProviderProtocol providerProbeProtocol(String providerID) {
  final id = providerID.toLowerCase();
  if (id.contains('anthropic') || id.contains('claude')) {
    return ProviderProtocol.anthropic;
  }
  if (id == 'openai' || id.startsWith('openai-')) {
    return ProviderProtocol.responses;
  }
  return ProviderProtocol.chatCompletions;
}

const _knownBaseUrls = <String, String>{
  'openai': 'https://api.openai.com/v1',
  'anthropic': 'https://api.anthropic.com/v1',
  'openrouter': 'https://openrouter.ai/api/v1',
  'deepseek': 'https://api.deepseek.com/v1',
  'groq': 'https://api.groq.com/openai/v1',
  'mistral': 'https://api.mistral.ai/v1',
  'xai': 'https://api.x.ai/v1',
  'moonshotai': 'https://api.moonshot.cn/v1',
  'zai': 'https://open.bigmodel.cn/api/paas/v4',
  'zhipuai': 'https://open.bigmodel.cn/api/paas/v4',
};
