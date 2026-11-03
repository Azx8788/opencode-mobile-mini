import 'package:flutter/material.dart';

import '../../domain/custom_provider.dart';
import '../../domain/provider_probe.dart';
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
    this.baseUrl = '',
    this.protocol = ProviderProtocol.chatCompletions,
    this.apiKey = '',
    this.autoRun = false,
  });

  final String providerName;
  final String model;
  final String baseUrl;
  final ProviderProtocol protocol;

  /// A key already known (an edited entry's, or the one the list read from
  /// the server). Empty means the person types one.
  final String apiKey;

  /// Starts the checks as the screen opens, for the "test this provider"
  /// path where pressing Run is a second, pointless confirmation.
  final bool autoRun;

  @override
  State<ProviderProbeScreen> createState() => _ProviderProbeScreenState();
}

class _ProviderProbeScreenState extends State<ProviderProbeScreen> {
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  late ProviderProtocol _protocol = widget.protocol;
  final List<ProviderProbeResult> _results = [];
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _baseUrl.text = widget.baseUrl;
    _apiKey.text = widget.apiKey;
    if (widget.autoRun && widget.baseUrl.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _run();
      });
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
    final probe = ProviderProbe();
    await probe.runAll(
      protocol: _protocol,
      baseUrl: _baseUrl.text,
      model: widget.model,
      apiKey: _apiKey.text,
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
        title: Text(l10n.providerProbeTitle(widget.model)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              widget.providerName,
              style: theme.textTheme.bodySmall,
            ),
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
          Text(
            l10n.providerProbeNote,
            style: theme.textTheme.bodySmall,
          ),
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

  static String _protocolName(ProviderProtocol protocol) =>
      switch (protocol) {
        ProviderProtocol.chatCompletions => 'Chat Completions',
        ProviderProtocol.responses => 'Responses',
        ProviderProtocol.anthropic => 'Anthropic Messages',
      };
}
