import 'dart:async';

import 'package:flutter/material.dart';

import '../../api2/provider_session_probe.dart';
import '../../builtin/builtin_server.dart' show looksLikeInAppServer;
import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import '../app_iconography.dart';
import '../app_theme.dart' show AppStatusTone;
import '../kit/kit.dart';

AppLocalizations _l10nOf(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

/// One model, tested the way the app will actually use it.
///
/// This used to be five hand-made requests from the phone: reply, stream, tool
/// call, system prompt, finish reason. They proved the address answered *this
/// app*, which is not the question — a gateway that only serves known coding
/// clients answers those five requests with a refusal and a 200. So the test
/// is now one real turn inside the server: it opens a session pinned to the
/// provider and model, sends a short message, and reads the reply. Nothing is
/// sent from the phone, and a failure to reach the server is reported as
/// itself rather than retried from here.
class ProviderTestScreen extends StatefulWidget {
  const ProviderTestScreen({
    super.key,
    required this.controller,
    required this.providerID,
    required this.providerName,
    required this.models,
    this.initialModel,
    this.autoRun = false,
  });

  final ConnectionController controller;
  final String providerID;
  final String providerName;

  /// Every model worth testing; one is enough, several get a picker.
  final List<String> models;

  final String? initialModel;

  /// Starts as the screen opens, for the "test this provider" path where
  /// pressing Run is a second, pointless confirmation.
  final bool autoRun;

  @override
  State<ProviderTestScreen> createState() => _ProviderTestScreenState();
}

class _ProviderTestScreenState extends State<ProviderTestScreen> {
  late String _model =
      widget.initialModel ??
      (widget.models.isEmpty ? '' : widget.models.first);
  ProviderSessionResult? _result;
  bool _running = false;

  /// The test only means something on the server this app runs: the provider
  /// entry is in *that* server's config, and its key is on that server.
  bool get _inApp => looksLikeInAppServer(widget.controller.profile);

  @override
  void initState() {
    super.initState();
    if (widget.autoRun && _inApp && _model.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_run());
      });
    }
  }

  Future<void> _run() async {
    if (_running || _model.isEmpty) return;
    final profile = widget.controller.profile;
    if (profile == null || !_inApp) return;
    setState(() {
      _running = true;
      _result = null;
    });
    final result = await ProviderSessionProbe(
      baseUrl: profile.baseUrl,
      password: profile.password,
      username: profile.username,
      cleartextConfirmedOrigin: profile.cleartextConfirmedOrigin,
      certificatePinSha256: profile.certificatePinSha256,
    ).run(providerID: widget.providerID, model: _model);
    if (!mounted) return;
    setState(() {
      _result = result;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10nOf(context);
    final tokens = KitTokens.of(context);
    final result = _result;
    return KitScreen(
      width: KitScreenWidth.list,
      topBar: KitTopBar(
        title: l10n.providerProbeTitle(_model),
        subtitle: widget.providerName,
      ),
      status: _running
          ? KitStatus(
              kind: KitStatusKind.work,
              icon: AppIconography.waiting,
              message: l10n.providerProbeRunning,
              tone: AppStatusTone.progress,
            )
          : null,
      body: ListView(
        padding: KitScreen.padding(context),
        children: [
          KitNotice(
            key: const ValueKey('provider-test-note'),
            icon: AppIconography.info,
            message: l10n.providerProbeNote,
          ),
          if (!_inApp) ...[
            SizedBox(height: tokens.space3),
            KitNotice(
              key: const ValueKey('provider-test-server-only'),
              tone: AppStatusTone.attention,
              icon: AppIconography.warning,
              message: l10n.providerProbeServerOnly,
            ),
          ],
          if (widget.models.length > 1) ...[
            SizedBox(height: tokens.space3),
            KitSectionLabel(l10n.providerTestPickModel),
            KitRowGroup(
              children: [
                for (final model in widget.models)
                  KitRow(
                    key: ValueKey('provider-test-model-$model'),
                    title: model,
                    selected: model == _model,
                    onTap: _running ? null : () => setState(() => _model = model),
                    trailing: model == _model
                        ? Icon(
                            AppIconography.check,
                            size: 20,
                            color: tokens.accent,
                          )
                        : null,
                  ),
              ],
            ),
          ],
          SizedBox(height: tokens.space3),
          KitButton.primary(
            key: const ValueKey('provider-test-run'),
            label: l10n.providerProbeRun,
            icon: AppIconography.play,
            working: _running,
            onPressed: _running || !_inApp || _model.isEmpty ? null : _run,
          ),
          if (result != null) ...[
            SizedBox(height: tokens.space4),
            _resultView(context, l10n, result),
          ],
        ],
      ),
    );
  }

  Widget _resultView(
    BuildContext context,
    AppLocalizations l10n,
    ProviderSessionResult result,
  ) {
    final tokens = KitTokens.of(context);
    final detail = _detail(l10n, result);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KitNotice(
          key: const ValueKey('provider-test-verdict'),
          tone: result.passed ? AppStatusTone.ok : AppStatusTone.failure,
          icon: result.passed ? AppIconography.check : AppIconography.warning,
          message: result.passed
              ? l10n.providerProbePassed(result.reply ?? '')
              : detail,
        ),
        if (result.passed && result.model != null && result.model != _model) ...[
          SizedBox(height: tokens.space2),
          Text(
            l10n.providerProbeServedAs(result.model!),
            style: KitText.styleOf(context, KitTextRole.caption),
          ),
        ],
        if (result.elapsed > Duration.zero) ...[
          SizedBox(height: tokens.space2),
          Text(
            l10n.providerProbeElapsed(
              (result.elapsed.inMilliseconds / 1000).toStringAsFixed(1),
            ),
            style: KitText.styleOf(context, KitTextRole.caption),
          ),
        ],
      ],
    );
  }

  /// The failure in the screen's language, with the server's own words kept
  /// where they explain something a person can act on.
  String _detail(AppLocalizations l10n, ProviderSessionResult result) {
    final detail = (result.detail ?? '').trim();
    return switch (result.outcome) {
      ProviderSessionOutcome.passed => '',
      ProviderSessionOutcome.unavailable => detail.isEmpty
          ? l10n.providerProbeServerDown
          : '${l10n.providerProbeServerDown} $detail',
      ProviderSessionOutcome.notLoaded => l10n.providerProbeServerNotLoaded,
      ProviderSessionOutcome.rejected => l10n.providerProbeServerRejected(
        detail,
      ),
      ProviderSessionOutcome.timeout => l10n.providerProbeServerTimeout,
      ProviderSessionOutcome.emptyReply => detail.isEmpty
          ? l10n.providerProbeServerEmpty
          : '${l10n.providerProbeServerEmpty} $detail',
      ProviderSessionOutcome.failed => detail.isEmpty
          ? l10n.providerProbeServerEmpty
          : detail,
    };
  }
}
