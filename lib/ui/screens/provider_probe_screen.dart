import 'package:flutter/material.dart';

import '../../domain/custom_provider.dart';
import '../../domain/provider_probe.dart';
import '../../domain/provider_tls.dart';
import '../../l10n/app_localizations.dart';

AppLocalizations _l10nOf(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

/// Runs the three checks against one provider and one model.
///
/// The key is typed here or handed over by the provider list, used for these
/// requests and never stored: a probe answers "does this endpoint work from
/// this phone", not "is this provider configured". Nothing about it touches
/// the server's config.
class ProviderProbeScreen extends StatefulWidget {
  const ProviderProbeScreen({
    super.key,
    required this.providerName,
    required this.model,
    this.models = const [],
    this.baseUrl = '',
    this.protocol = ProviderProtocol.chatCompletions,
    this.apiKey = '',
    this.resolveKey,
    this.headers = const {},
    this.autoRun = false,
    this.trustFor,
  });

  final String providerName;
  final String model;

  /// Every model worth testing; one is enough, several get a picker.
  final List<String> models;

  final String baseUrl;
  final ProviderProtocol protocol;

  /// A key already known (an edited entry's, or the one the list read from
  /// the server). Empty means the person types one.
  final String apiKey;

  /// Reads the key the entry already has (a file on the server, a value in
  /// the config). Called once, when the field is empty.
  final Future<String> Function()? resolveKey;

  /// Extra headers the provider needs, merged into every check.
  final Map<String, String> headers;

  /// Starts the checks as the screen opens, for the "test this provider"
  /// path where pressing Run is a second, pointless confirmation.
  final bool autoRun;

  /// The certificate fingerprint already trusted for an origin. Read at the
  /// moment a check runs, because the address can be edited here.
  final String? Function(String origin)? trustFor;

  @override
  State<ProviderProbeScreen> createState() => _ProviderProbeScreenState();
}

class _ProviderProbeScreenState extends State<ProviderProbeScreen> {
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  late ProviderProtocol _protocol = widget.protocol;
  late String _model = widget.model;
  final List<ProviderProbeResult> _results = [];
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _baseUrl.text = widget.baseUrl;
    _apiKey.text = widget.apiKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prime();
    });
  }

  /// Reads a stored key when the caller did not hand one over, then runs the
  /// checks if asked. The key stays in memory for this screen only.
  Future<void> _prime() async {
    if (_apiKey.text.trim().isEmpty && widget.resolveKey != null) {
      final key = await widget.resolveKey!();
      if (!mounted) return;
      if (key.isNotEmpty) setState(() => _apiKey.text = key);
    }
    if (widget.autoRun && _baseUrl.text.trim().isNotEmpty) {
      await _run();
    }
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final l10n = _l10nOf(context);
    if (_baseUrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.providerProbeNeedBaseUrl)));
      return;
    }
    setState(() {
      _running = true;
      _results.clear();
    });
    final probe = ProviderProbe(
      trustedFingerprint: widget.trustFor?.call(
        providerOrigin(
          CustomProviderDraft.normalizeBaseUrl(_baseUrl.text, _protocol),
        ),
      ),
    );
    await probe.runAll(
      protocol: _protocol,
      baseUrl: _baseUrl.text,
      model: _model,
      apiKey: _apiKey.text,
      headers: widget.headers,
      onResult: (result) {
        if (!mounted) return;
        setState(() => _results.add(result));
      },
    );
    if (mounted) setState(() => _running = false);
  }

  String _label(AppLocalizations l10n, ProviderProbeKind kind) =>
      switch (kind) {
        ProviderProbeKind.nonStreaming => l10n.providerProbeNonStreaming,
        ProviderProbeKind.streaming => l10n.providerProbeStreaming,
        ProviderProbeKind.toolCall => l10n.providerProbeToolCall,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = _l10nOf(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.providerProbeTitle(_model)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(widget.providerName, style: theme.textTheme.bodySmall),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          TextField(
            key: const ValueKey('probe-base-url'),
            controller: _baseUrl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: l10n.providerProbeBaseUrl,
              hintText: 'https://api.example.com/v1',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('probe-api-key'),
            controller: _apiKey,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: l10n.providerProbeApiKey,
              helperText: l10n.providerProbeKeyNote,
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<ProviderProtocol>(
            key: const ValueKey('probe-protocol'),
            initialValue: _protocol,
            decoration: InputDecoration(labelText: l10n.providerProbeProtocol),
            items: [
              for (final protocol in ProviderProtocol.values)
                DropdownMenuItem(
                  value: protocol,
                  child: Text(_protocolName(protocol)),
                ),
            ],
            onChanged: _running
                ? null
                : (value) {
                    if (value == null) return;
                    setState(() => _protocol = value);
                  },
          ),
          if (widget.models.length > 1) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const ValueKey('probe-model'),
              initialValue: _model,
              decoration: InputDecoration(
                labelText: l10n.providerTestPickModel,
              ),
              items: [
                for (final model in widget.models)
                  DropdownMenuItem(
                    value: model,
                    child: Text(model, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: _running
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() => _model = value);
                    },
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey('probe-run'),
            onPressed: _running ? null : _run,
            icon: const Icon(Icons.play_arrow),
            label: Text(
              _running ? l10n.providerProbeRunning : l10n.providerProbeRun,
            ),
          ),
          const SizedBox(height: 8),
          Text(l10n.providerProbeNote, style: theme.textTheme.bodySmall),
          if (_running) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          const SizedBox(height: 16),
          for (final result in _results)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Icon(
                  result.passed ? Icons.check_circle : Icons.cancel,
                  color: result.passed
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                ),
                title: Text(_label(l10n, result.kind)),
                subtitle: Text(result.detail),
                trailing: result.elapsed == Duration.zero
                    ? null
                    : Text('${result.elapsed.inMilliseconds} ms'),
              ),
            ),
        ],
      ),
    );
  }

  static String _protocolName(ProviderProtocol protocol) => switch (protocol) {
    ProviderProtocol.chatCompletions => 'Chat Completions',
    ProviderProtocol.responses => 'Responses',
    ProviderProtocol.anthropic => 'Anthropic Messages',
    ProviderProtocol.google => 'Google Gemini',
  };
}
