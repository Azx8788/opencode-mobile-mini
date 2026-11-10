/// Where a person points Claude Code at a provider already saved in Settings.
///
/// Claude Code speaks the Anthropic Messages protocol and reads
/// `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_MODEL` from
/// its own settings file. Instead of typing those again here, this sheet
/// lists the providers the person already configured, derives the address
/// Claude Code wants from each one, and writes the chosen provider's key and
/// model into the agent's settings in one call.
///
/// A provider saved as OpenAI on a new-api / one-api gateway serves
/// `/v1/messages` on the same host as `/v1/chat/completions`, so every
/// provider is offered: the version segment is stripped from the address and
/// Claude Code appends `/v1/messages` itself. A provider whose key the app
/// cannot read (a server-managed one, or a missing key file) is shown but
/// disabled, and a hand-typed gateway stays one tap away as the fallback.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../builtin/builtin_linux.dart';
import '../../../builtin/builtin_provider_store.dart';
import '../../../domain/agent_endpoint.dart';
import '../../../domain/custom_provider.dart'
    show CustomProviderModel, ProviderKeyMode, ProviderProtocol;
import '../../../domain/custom_provider_record.dart';
import '../../../domain/phone_agents_source.dart';
import '../../../l10n/app_localizations.dart';
import '../../kit/kit.dart';
import '../chats/chats_host.dart';
import 'agent_endpoint_sheet.dart' show showAgentEndpointSheet;

/// Opens the provider picker for [agentId]. Returns true when the agent's
/// settings file changed.
Future<bool?> showAgentProviderSheet(
  BuildContext context, {
  required String agentId,
}) => showKitFramedSheet<bool>(
  context,
  sheetKey: const ValueKey('agent-provider-sheet'),
  builder: (_) => AgentProviderSheet(agentId: agentId),
);

/// Why a provider in the list cannot be picked.
enum _Unusable { noKey, externalKey, badAddress }

/// Why reading the provider list itself failed.
enum _LoadError { unreadable, failed }

/// One provider as the picker prepared it for Claude Code.
final class _ProviderChoice {
  const _ProviderChoice({
    required this.record,
    required this.derivedUrl,
    required this.key,
    required this.enabledModels,
    required this.unusable,
  });

  final CustomProviderRecord record;

  /// The address Claude Code gets: the provider's base URL with its trailing
  /// `/v1` or `/v1beta` stripped, so Claude Code's own `/v1/messages` does
  /// not double up.
  final String derivedUrl;

  /// The key read from the provider's secret file or config, or null when the
  /// app cannot reach it. Held only long enough to save; never displayed.
  final String? key;

  final List<CustomProviderModel> enabledModels;

  final _Unusable? unusable;

  bool get usable => unusable == null;
}

class AgentProviderSheet extends ConsumerStatefulWidget {
  const AgentProviderSheet({super.key, required this.agentId});

  final String agentId;

  @override
  ConsumerState<AgentProviderSheet> createState() =>
      _AgentProviderSheetState();
}

class _AgentProviderSheetState extends ConsumerState<AgentProviderSheet> {
  late final BuiltinLinux _linux = BuiltinLinux();
  late final BuiltinProviderStore _store = BuiltinProviderStore(linux: _linux);

  AgentEndpointStatus _status = AgentEndpointStatus.absent;
  List<_ProviderChoice> _choices = const [];
  _LoadError? _loadError;
  bool _loading = true;
  bool _saving = false;
  bool _removing = false;
  String? _error;

  String? _selectedId;
  String? _selectedModel;

  PhoneAgentsSource get _agents => ref.read(chatsHostProvider).agents!;

  PhoneAgentEndpointSource? get _endpoints {
    final agents = _agents;
    return agents is PhoneAgentEndpointSource
        ? agents as PhoneAgentEndpointSource
        : null;
  }

  _ProviderChoice? get _selectedChoice {
    final id = _selectedId;
    if (id == null) return null;
    for (final choice in _choices) {
      if (choice.record.id == id) return choice;
    }
    return null;
  }

  /// The provider already driving Claude Code, if the saved address matches
  /// one in the list. Shown as the current row, distinct from a selection.
  String? get _currentId {
    final base = _status.baseUrl;
    if (base == null) return null;
    for (final choice in _choices) {
      if (choice.derivedUrl == base) return choice.record.id;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  Future<void> _read() async {
    final source = _endpoints;
    AgentEndpointStatus status = AgentEndpointStatus.absent;
    if (source != null) {
      try {
        status = await source.readAgentEndpoint(widget.agentId);
      } catch (_) {
        // A settings file the app cannot read leaves the list as it is.
      }
    }

    List<_ProviderChoice> choices = const [];
    _LoadError? loadError;
    try {
      final resolved = await _store.resolve();
      final catalogue = await _store.readRecords(resolved: resolved);
      final built = <_ProviderChoice>[];
      for (final record in catalogue.records) {
        String? key;
        _Unusable? unusable;
        String derivedUrl;
        try {
          derivedUrl = AgentEndpoint.claudeCodeBaseUrl(record.baseUrl);
        } catch (_) {
          derivedUrl = record.baseUrl;
          unusable = _Unusable.badAddress;
        }
        if (record.keyMode == ProviderKeyMode.secretFile) {
          if (record.secretPath != null) {
            try {
              key = await _store.readSecret(record.secretPath!);
            } catch (_) {
              // A key file that cannot be read disables the row, not the
              // list.
            }
          }
          if (key == null || key.isEmpty) unusable ??= _Unusable.noKey;
        } else if (record.keyMode == ProviderKeyMode.plaintext) {
          key = record.apiKey;
          if (key == null || key.isEmpty) unusable ??= _Unusable.noKey;
        } else {
          unusable ??= _Unusable.externalKey;
        }
        final enabled = record.models
            .where((m) => !record.disabledModels.contains(m.id))
            .toList(growable: false);
        built.add(
          _ProviderChoice(
            record: record,
            derivedUrl: derivedUrl,
            key: key,
            enabledModels: enabled,
            unusable: unusable,
          ),
        );
      }
      choices = built;
    } on ProviderWriteRefused catch (_) {
      loadError = _LoadError.unreadable;
    } catch (_) {
      loadError = _LoadError.failed;
    }

    if (!mounted) return;
    setState(() {
      _status = status;
      _choices = choices;
      _loadError = loadError;
      _loading = false;
      final current = _currentIdFrom(status, choices);
      if (current != null) {
        _selectedId = current;
        if (status.model != null) {
          final match = choices.where((c) => c.record.id == current).firstOrNull;
          if (match != null &&
              match.enabledModels.any((m) => m.id == status.model)) {
            _selectedModel = status.model;
          }
        }
      }
    });
  }

  static String? _currentIdFrom(
    AgentEndpointStatus status,
    List<_ProviderChoice> choices,
  ) {
    final base = status.baseUrl;
    if (base == null) return null;
    for (final choice in choices) {
      if (choice.derivedUrl == base) return choice.record.id;
    }
    return null;
  }

  bool get _canSave {
    final choice = _selectedChoice;
    if (choice == null || !choice.usable || _saving || _removing) return false;
    if (choice.enabledModels.isNotEmpty && _selectedModel == null) return false;
    return true;
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final source = _endpoints;
    final choice = _selectedChoice;
    if (source == null || choice == null || _saving) return;
    if (!choice.usable || choice.key == null) {
      setState(() => _error = l10n.agentsEndpointProviderNoKey);
      return;
    }
    if (choice.enabledModels.isNotEmpty && _selectedModel == null) {
      setState(() => _error = l10n.agentsEndpointProviderPickModel);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await source.saveAgentEndpoint(
        widget.agentId,
        AgentEndpoint(
          baseUrl: choice.derivedUrl,
          apiKey: choice.key,
          model: _selectedModel,
        ),
      );
      if (mounted) KitSheet.close(context, true);
    } catch (_) {
      if (mounted) setState(() => _error = l10n.agentsEndpointFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _remove() async {
    final source = _endpoints;
    if (source == null || _removing) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showKitConfirm(
      context,
      title: l10n.agentsEndpointRemove,
      body: l10n.agentsEndpointRemoveBody(
        KitBidi.auto(
          _agents.agentRows
                  .where((row) => row.id == widget.agentId)
                  .firstOrNull
                  ?.name ??
              widget.agentId,
        ),
      ),
      confirmLabel: l10n.agentsEndpointRemoveConfirm,
      kind: KitConfirmKind.destructive,
      sheetKey: const ValueKey('agent-provider-remove-sheet'),
      confirmKey: const ValueKey('agent-provider-remove-confirm'),
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _removing = true;
      _error = null;
    });
    try {
      await source.clearAgentEndpoint(widget.agentId);
      if (mounted) KitSheet.close(context, true);
    } catch (_) {
      if (mounted) setState(() => _error = l10n.agentsEndpointFailed);
    } finally {
      if (mounted) setState(() => _removing = false);
    }
  }

  /// The hand-typed gateway form, for a provider not in Settings.
  Future<void> _openCustom() async {
    final changed = await showAgentEndpointSheet(
      context,
      agentId: widget.agentId,
    );
    if (!mounted || changed != true) return;
    KitSheet.close(context, true);
  }

  String _protocolLabel(AppLocalizations l10n, ProviderProtocol protocol) =>
      switch (protocol) {
        ProviderProtocol.chatCompletions => l10n.providerAddProtocolChat,
        ProviderProtocol.responses => l10n.providerAddProtocolResponses,
        ProviderProtocol.anthropic => l10n.providerAddProtocolAnthropic,
        ProviderProtocol.google => 'Google',
      };

  String _unusableReason(AppLocalizations l10n, _Unusable? unusable) =>
      switch (unusable) {
        _Unusable.noKey => l10n.agentsEndpointProviderNoKey,
        _Unusable.externalKey => l10n.agentsEndpointProviderExternalKey,
        _Unusable.badAddress => l10n.agentsEndpointProviderBadAddress,
        null => '',
      };

  String _loadErrorMessage(AppLocalizations l10n, _LoadError error) =>
      switch (error) {
        _LoadError.unreadable => l10n.agentsEndpointProvidersUnreadable,
        _LoadError.failed => l10n.agentsEndpointFailed,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final name = _agents.agentRows
            .where((row) => row.id == widget.agentId)
            .firstOrNull
            ?.name ??
        widget.agentId;
    final choice = _selectedChoice;
    return KitSheet(
      handle: true,
      title: l10n.agentsEndpointProvidersTitle,
      onClose: () => KitSheet.close(context, false),
      loading: _loading || _saving || _removing,
      primary: KitAction(
        key: const ValueKey('agent-provider-use'),
        label: _saving ? l10n.agentsEndpointSaving : l10n.agentsEndpointProviderUse,
        onPressed: _canSave ? () => unawaited(_save()) : null,
      ),
      secondary: _status.configured
          ? KitAction(
              key: const ValueKey('agent-provider-remove'),
              label: l10n.agentsEndpointRemove,
              onPressed: _saving || _removing
                  ? null
                  : () => unawaited(_remove()),
            )
          : null,
      tertiary: [
        KitAction(
          key: const ValueKey('agent-provider-custom'),
          label: l10n.agentsEndpointProviderCustomGateway,
          onPressed: _saving || _removing
              ? null
              : () => unawaited(_openCustom()),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.space3,
        children: [
          KitText(
            l10n.agentsEndpointProviderIntro(name),
            key: const ValueKey('agent-provider-intro'),
            tone: KitTextTone.secondary,
          ),
          if (_loading)
            KitText(
              l10n.agentsEndpointProvidersReading,
              key: const ValueKey('agent-provider-reading'),
              tone: KitTextTone.secondary,
            ),
          if (!_loading && _loadError != null)
            KitText(
              _loadErrorMessage(l10n, _loadError!),
              key: const ValueKey('agent-provider-load-error'),
              tone: KitTextTone.attention,
            ),
          if (!_loading && _loadError == null && _choices.isEmpty)
            KitText(
              l10n.agentsEndpointProvidersEmpty,
              key: const ValueKey('agent-provider-empty'),
              tone: KitTextTone.secondary,
            ),
          if (!_loading && _choices.isNotEmpty) ...[
            KitChoiceList<String>.single(
              actsOnTap: false,
              selected: _selectedId,
              current: _currentId,
              onSelected: (id) =>
                  setState(() {
                    _selectedId = id;
                    _selectedModel = null;
                  }),
              choices: [
                for (final c in _choices)
                  KitChoice<String>(
                    key: ValueKey('agent-provider-${c.record.id}'),
                    value: c.record.id,
                    title: c.record.name,
                    supporting:
                        '${_protocolLabel(l10n, c.record.protocol)} · ${c.derivedUrl}',
                    enabled: c.usable,
                    disabledReason:
                        c.usable ? null : _unusableReason(l10n, c.unusable),
                  ),
              ],
            ),
            if (choice != null &&
                choice.usable &&
                choice.enabledModels.isNotEmpty)
              KitChoiceList<String>.single(
                actsOnTap: false,
                selected: _selectedModel,
                onSelected: (id) =>
                    setState(() => _selectedModel = id),
                choices: [
                  for (final m in choice.enabledModels)
                    KitChoice<String>(
                      key: ValueKey('agent-provider-model-${m.id}'),
                      value: m.id,
                      title: m.name ?? m.id,
                    ),
                ],
              )
            else if (choice != null &&
                choice.usable &&
                choice.enabledModels.isEmpty)
              KitText(
                l10n.agentsEndpointProviderNoModels,
                key: const ValueKey('agent-provider-no-models'),
                tone: KitTextTone.secondary,
              ),
          ],
          if (_error != null)
            KitText(
              _error!,
              key: const ValueKey('agent-provider-error'),
              tone: KitTextTone.attention,
            ),
        ],
      ),
    );
  }
}
