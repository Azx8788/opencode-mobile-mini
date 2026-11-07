/// Where a person points Claude Code at an Anthropic-compatible gateway.
///
/// The sheet owns no credential: the key goes from the field into the agent's
/// own settings file in one call and is never read back. Saving the same
/// address again without typing a key keeps the one already there.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/agent_endpoint.dart';
import '../../../domain/phone_agents_source.dart';
import '../../../domain/server_gateway/value_types_catalog.dart';
import '../../../l10n/app_localizations.dart';
import '../../kit/kit.dart';
import '../chats/chats_host.dart';

/// Opens the endpoint form for [agentId]. Returns true when the agent's
/// settings file changed.
Future<bool?> showAgentEndpointSheet(
  BuildContext context, {
  required String agentId,
}) => showKitFramedSheet<bool>(
  context,
  sheetKey: const ValueKey('agent-endpoint-sheet'),
  builder: (_) => AgentEndpointSheet(agentId: agentId),
);

class AgentEndpointSheet extends ConsumerStatefulWidget {
  const AgentEndpointSheet({super.key, required this.agentId});

  final String agentId;

  @override
  ConsumerState<AgentEndpointSheet> createState() => _AgentEndpointSheetState();
}

class _AgentEndpointSheetState extends ConsumerState<AgentEndpointSheet> {
  final _base = TextEditingController();
  final _key = TextEditingController();
  final _model = TextEditingController();

  AgentEndpointStatus _status = AgentEndpointStatus.absent;
  bool _loading = true;
  bool _saving = false;
  bool _removing = false;
  String? _error;

  PhoneAgentsSource get _agents => ref.read(chatsHostProvider).agents!;

  PhoneAgentEndpointSource? get _endpoints {
    final agents = _agents;
    return agents is PhoneAgentEndpointSource
        ? agents as PhoneAgentEndpointSource
        : null;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  @override
  void dispose() {
    _base.dispose();
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    final source = _endpoints;
    if (source == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final status = await source.readAgentEndpoint(widget.agentId);
      if (!mounted) return;
      setState(() {
        _status = status;
        _base.text = status.baseUrl ?? '';
        _model.text = status.model ?? '';
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _insecure => _base.text.trim().startsWith('http://');

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final source = _endpoints;
    if (source == null || _saving) return;
    final base = _base.text.trim();
    final key = _key.text.trim();
    if (base.isEmpty || (key.isEmpty && !_status.hasKey)) {
      setState(() => _error = l10n.agentsEndpointIncomplete);
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
          baseUrl: base,
          apiKey: key.isEmpty ? null : key,
          model: _model.text,
        ),
      );
      if (mounted) KitSheet.close(context, true);
    } on ProductException {
      if (mounted) setState(() => _error = l10n.agentsEndpointFailed);
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
      sheetKey: const ValueKey('agent-endpoint-remove-sheet'),
      confirmKey: const ValueKey('agent-endpoint-remove-confirm'),
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final name =
        _agents.agentRows
            .where((row) => row.id == widget.agentId)
            .firstOrNull
            ?.name ??
        widget.agentId;
    return KitSheet(
      handle: true,
      title: l10n.agentsEndpointTitle,
      onClose: () => KitSheet.close(context, false),
      loading: _loading,
      primary: KitAction(
        key: const ValueKey('agent-endpoint-save'),
        label: _saving ? l10n.agentsEndpointSaving : l10n.agentsEndpointSave,
        onPressed: _saving || _removing ? null : () => unawaited(_save()),
      ),
      secondary: _status.configured
          ? KitAction(
              key: const ValueKey('agent-endpoint-remove'),
              label: l10n.agentsEndpointRemove,
              onPressed: _saving || _removing
                  ? null
                  : () => unawaited(_remove()),
            )
          : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.space3,
        children: [
          KitText(
            l10n.agentsEndpointIntro(name),
            key: const ValueKey('agent-endpoint-intro'),
            tone: KitTextTone.secondary,
          ),
          KitField(
            label: l10n.agentsEndpointBaseUrl,
            controller: _base,
            kind: KitFieldKind.url,
            hint: l10n.agentsEndpointBaseUrlHint,
            helper: _insecure ? l10n.agentsEndpointInsecure : null,
            enabled: !_saving && !_removing,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.next,
            fieldKey: const ValueKey('agent-endpoint-base-url'),
          ),
          KitField.secret(
            label: l10n.agentsEndpointKey,
            controller: _key,
            saved: _status.hasKey,
            helper: _status.hasKey ? l10n.agentsEndpointKeySaved : null,
            enabled: !_saving && !_removing,
            textInputAction: TextInputAction.next,
            fieldKey: const ValueKey('agent-endpoint-key'),
          ),
          KitField(
            label: l10n.agentsEndpointModel,
            controller: _model,
            hint: l10n.agentsEndpointModelHint,
            optional: true,
            enabled: !_saving && !_removing,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => unawaited(_save()),
            fieldKey: const ValueKey('agent-endpoint-model'),
          ),
          if (_error != null)
            KitText(
              _error!,
              key: const ValueKey('agent-endpoint-error'),
              tone: KitTextTone.attention,
            ),
        ],
      ),
    );
  }
}
