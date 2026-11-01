import 'dart:async';

import 'package:flutter/material.dart';

import '../../../builtin/quota_collector_host.dart';
import '../../../domain/usage_subscriptions.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/computer_usage_source.dart';
import '../../../state/connection.dart';
import '../../../state/profiles.dart';
import '../../../state/usage_subscriptions_controller.dart';
import '../../app_iconography.dart';
import '../../kit/kit.dart';
import 'usage_text.dart';

/// "Read usage from {connection}": a sign-in exists there that the app
/// cannot read the limits of yet. In-app Ubuntu is set up here, for real. A
/// computer is read by a one-shot, read-only check the app runs through
/// OpenCode each time it refreshes; this screen turns that on, runs it once
/// at once, and shows what it found or why it could not.
class UsageReadFromScreen extends StatefulWidget {
  const UsageReadFromScreen({
    super.key,
    required this.controller,
    required this.usage,
    required this.connectionId,
    this.providerId,
    this.collector,
    this.computer,
  });

  final ConnectionController controller;
  final UsageSubscriptionsController usage;
  final String connectionId;

  /// The provider whose card sent the person here, if any.
  final String? providerId;

  /// Test seam for In-app Ubuntu's reader.
  final InAppQuotaCollector? collector;

  /// Test seam for the computer check. Defaults to the app's own.
  final ComputerUsageSource? computer;

  @override
  State<UsageReadFromScreen> createState() => _UsageReadFromScreenState();
}

class _UsageReadFromScreenState extends State<UsageReadFromScreen> {
  InAppQuotaCollector? _ownHost;
  bool _working = false;
  QuotaSetupStep? _step;
  QuotaSetupFailure? _failure;
  ComputerUsageResult? _computerResult;

  ComputerUsageSource get _computer =>
      widget.computer ?? widget.controller.computerUsage;

  ServerProfile? get _profile => widget.controller.store.profiles
      .where((p) => p.id == widget.connectionId)
      .firstOrNull;

  InAppQuotaCollector get _host =>
      widget.collector ??
      (_ownHost ??= InAppQuotaCollector(prefs: widget.controller.store.prefs));

  UsageConnection? get _connection {
    for (final c in widget.usage.snapshot.connections) {
      if (c.id == widget.connectionId) return c;
    }
    return null;
  }

  Future<void> _setUp() async {
    final profile = widget.controller.store.profiles
        .where((p) => p.id == widget.connectionId)
        .firstOrNull;
    if (profile == null || _working) return;
    setState(() {
      _working = true;
      _failure = null;
      _step = QuotaSetupStep.checking;
    });
    QuotaSetupFailure? failure;
    try {
      await _host.setUp(
        profile,
        onStep: (step) {
          if (mounted) setState(() => _step = step);
        },
      );
    } on QuotaSetupException catch (error) {
      failure = error.failure;
    } on Object {
      failure = QuotaSetupFailure.prepare;
    }
    if (failure == null) await widget.usage.refresh(force: true);
    if (!mounted) return;
    setState(() {
      _working = false;
      _failure = failure;
    });
    if (failure == null) Navigator.of(context).maybePop();
  }

  Future<void> _computerRun({required bool turnOn}) async {
    final profile = _profile;
    if (profile == null || _working) return;
    setState(() {
      _working = true;
      _computerResult = null;
    });
    ComputerUsageResult result;
    try {
      result = turnOn
          ? await _computer.turnOn(profile)
          : await _computer.readNow(profile);
    } on Object {
      result = const ComputerUsageResult(
        problem: ComputerUsageProblem.unreachable,
      );
    }
    // The controller takes the answer the check just gave; it runs nothing.
    await widget.usage.refresh();
    if (!mounted) return;
    setState(() {
      _working = false;
      _computerResult = result;
    });
  }

  Future<void> _computerOff() async {
    await _computer.turnOff(widget.connectionId);
    await widget.usage.refresh();
    if (!mounted) return;
    setState(() => _computerResult = null);
  }

  String _failureWords(AppLocalizations l10n, String server) =>
      switch (_failure!) {
        QuotaSetupFailure.linuxNotReady => l10n.quotaInAppFailLinux(server),
        QuotaSetupFailure.noNode => l10n.quotaInAppFailNoNode(server),
        QuotaSetupFailure.nodeTooOld => l10n.quotaInAppFailNodeOld(server),
        QuotaSetupFailure.copy ||
        QuotaSetupFailure.prepare => l10n.quotaInAppFailPrepare(server),
        QuotaSetupFailure.start => l10n.quotaInAppFailStart(server),
        QuotaSetupFailure.remove => l10n.quotaInAppFailRemove(server),
      };

  String _stepWords(AppLocalizations l10n, String server) => switch (_step!) {
    QuotaSetupStep.checking => l10n.quotaInAppStepChecking(server),
    QuotaSetupStep.copying => l10n.quotaInAppStepCopying,
    QuotaSetupStep.signIns => l10n.quotaInAppStepSignIns,
    QuotaSetupStep.starting => l10n.quotaInAppStepStarting,
    QuotaSetupStep.reading => l10n.quotaInAppStepReading,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = usageStrings(context);
    final tokens = KitTokens.of(context);
    return ListenableBuilder(
      listenable: widget.usage,
      builder: (context, _) {
        final connection = _connection;
        if (connection == null) {
          return KitScreen(
            topBar: KitTopBar(title: l10n.usageReadFromTitleHere),
            body: KitStateView(
              key: const ValueKey('usage-read-from-gone'),
              icon: AppIconography.info,
              title: l10n.usageReadFromGoneTitle,
              body: l10n.usageReadFromGoneBody,
            ),
          );
        }
        final name = UsageText.connection(l10n, connection);
        final inApp = connection.kind == UsageConnectionKind.inAppUbuntu;
        // Only plans the app can read, each once and by its proper name.
        final ids = <String>{
          for (final s in widget.usage.snapshot.subscriptions)
            if (s.fix == UsageFix.setUp && s.fixConnection == connection)
              s.providerId,
          if (widget.providerId case final id?)
            if (usageReadableFromOpenCode.contains(id)) id,
        };
        final providers = [
          for (final id in ids) UsageText.provider(l10n, id, id),
        ];
        return KitScreen(
          topBar: KitTopBar(title: l10n.usageReadFrom(name)),
          width: KitScreenWidth.reading,
          body: ListView(
            key: const ValueKey('usage-read-from'),
            padding: EdgeInsetsDirectional.only(
              start: tokens.gutter,
              end: tokens.gutter,
              top: tokens.space2,
              bottom: KitScreen.endPadding(context),
            ),
            children: [
              if (providers.isNotEmpty) ...[
                KitText(
                  l10n.usageReadFromSignedIn(providers.join(', '), name),
                  key: const ValueKey('usage-read-from-title'),
                  role: KitTextRole.headline,
                ),
                SizedBox(height: tokens.space2),
              ],
              KitText(
                inApp
                    ? l10n.usageReadFromBodyInApp
                    : l10n.usageComputerExplain(name),
                key: const ValueKey('usage-read-from-body'),
                role: KitTextRole.body,
              ),
              if (!inApp) ...[
                SizedBox(height: tokens.space3),
                KitDetailsFold(
                  key: const ValueKey('usage-read-from-what-runs'),
                  label: l10n.usageComputerWhatRuns,
                  values: [
                    KitTechnicalValue(
                      l10n.usageComputerCommandLabel,
                      'node --input-type=module -e <check>',
                      copyable: false,
                    ),
                    KitTechnicalValue(
                      l10n.usageComputerReadsLabel,
                      l10n.usageComputerReadsValue(name),
                      copyable: false,
                    ),
                  ],
                ),
                ..._computerStatus(l10n, tokens, name),
              ],
              if (inApp && _failure != null) ...[
                SizedBox(height: tokens.space3),
                KitNotice.error(
                  key: const ValueKey('usage-read-from-failure'),
                  message: _failureWords(l10n, name),
                ),
              ],
              if (inApp && _working && _step != null) ...[
                SizedBox(height: tokens.space3),
                KitText(
                  _stepWords(l10n, name),
                  key: const ValueKey('usage-read-from-step'),
                  role: KitTextRole.secondary,
                ),
              ],
              SizedBox(height: tokens.space4),
              inApp ? _inAppActions(l10n) : _computerActions(l10n),
            ],
          ),
        );
      },
    );
  }

  Widget _inAppActions(AppLocalizations l10n) => KitActionBlock(
    primary: KitAction(
      key: const ValueKey('usage-read-from-set-up'),
      label: l10n.usageReadFromSetUpInApp,
      icon: AppIconography.usageRing,
      working: _working,
      onPressed: () => unawaited(_setUp()),
    ),
    tertiary: [
      KitAction(
        key: const ValueKey('usage-read-from-not-now'),
        label: l10n.usageNotNow,
        onPressed: () => Navigator.of(context).maybePop(),
      ),
    ],
  );

  bool get _computerOn => _computer.isEnabled(widget.connectionId);

  /// What the last check found, or why it could not, in plain words.
  List<Widget> _computerStatus(
    AppLocalizations l10n,
    KitTokens tokens,
    String name,
  ) {
    final result = _computerResult;
    final problem =
        result?.problem ??
        (_computerOn && result == null && !_working
            ? _computer.problemFor(widget.connectionId)
            : null);
    final widgets = <Widget>[SizedBox(height: tokens.space3)];
    if (_working) {
      widgets.add(
        KitText(
          l10n.usageComputerChecking(name),
          key: const ValueKey('usage-read-from-checking'),
          role: KitTextRole.secondary,
        ),
      );
    } else if (problem != null) {
      widgets.add(
        KitNotice.error(
          key: const ValueKey('usage-read-from-failure'),
          message: UsageText.computerProblem(l10n, problem, name),
        ),
      );
    } else if (result != null) {
      final found = [
        for (final p in result.found) UsageText.provider(l10n, p.name, p.name),
      ];
      widgets.add(
        KitText(
          found.isEmpty
              ? l10n.usageComputerFoundNone(name)
              : l10n.usageComputerFound(found.join(', '), name),
          key: const ValueKey('usage-read-from-result'),
          role: KitTextRole.body,
        ),
      );
    } else if (_computerOn) {
      widgets.add(
        KitText(
          l10n.usageComputerOnNote(name),
          key: const ValueKey('usage-read-from-on'),
          role: KitTextRole.secondary,
        ),
      );
    } else {
      return const [];
    }
    return widgets;
  }

  Widget _computerActions(AppLocalizations l10n) {
    final on = _computerOn;
    final good = _computerResult?.ok == true;
    return KitActionBlock(
      primary: on && good
          ? KitAction(
              key: const ValueKey('usage-read-from-done'),
              label: l10n.usageComputerDone,
              onPressed: () => Navigator.of(context).maybePop(),
            )
          : KitAction(
              key: const ValueKey('usage-read-from-set-up'),
              label: on ? l10n.usageComputerReadNow : l10n.usageComputerTurnOn,
              icon: AppIconography.usageRing,
              working: _working,
              onPressed: () => unawaited(_computerRun(turnOn: !on)),
            ),
      tertiary: [
        if (on)
          KitAction(
            key: const ValueKey('usage-read-from-turn-off'),
            label: l10n.usageComputerTurnOff,
            onPressed: _working ? null : () => unawaited(_computerOff()),
          )
        else
          KitAction(
            key: const ValueKey('usage-read-from-not-now'),
            label: l10n.usageNotNow,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        if (on && good)
          KitAction(
            key: const ValueKey('usage-read-from-set-up'),
            label: l10n.usageComputerReadNow,
            onPressed: _working
                ? null
                : () => unawaited(_computerRun(turnOn: false)),
          ),
      ],
    );
  }
}
