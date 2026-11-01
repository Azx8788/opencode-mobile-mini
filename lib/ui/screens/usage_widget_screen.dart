import 'dart:async';

import 'package:flutter/material.dart';

import '../../background/usage_widget_snapshot.dart';
import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import '../../state/usage_subscriptions_controller.dart';
import '../app_iconography.dart';
import '../kit/kit.dart';
import 'usage/usage_text.dart';

/// Settings › Usage › Home screen widget: which plans the widget shows,
/// whether it shows the 5-hour limit, the weekly limit or both, whether it
/// lists rows that need setup. Every connection is read automatically.
class UsageWidgetScreen extends StatefulWidget {
  const UsageWidgetScreen({super.key, required this.controller, this.usage});

  final ConnectionController controller;

  /// Test seam; the app uses the controller's own.
  final UsageSubscriptionsController? usage;

  @override
  State<UsageWidgetScreen> createState() => _UsageWidgetScreenState();
}

class _UsageWidgetScreenState extends State<UsageWidgetScreen> {
  bool _saveFailed = false;

  UsageSubscriptionsController get _usage =>
      widget.usage ?? widget.controller.usageSubscriptions;

  Future<void> _write(UsageWidgetSettings next) async {
    setState(() => _saveFailed = false);
    try {
      await _usage.setWidgetSettings(next);
    } on Object {
      if (mounted) setState(() => _saveFailed = true);
    }
  }

  String _windowsLabel(AppLocalizations l10n, UsageWidgetWindows value) =>
      switch (value) {
        UsageWidgetWindows.fiveHour => l10n.usageWidgetWindowFiveHour,
        UsageWidgetWindows.weekly => l10n.usageWidgetWindowWeekly,
        UsageWidgetWindows.both => l10n.usageWidgetWindowBoth,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = usageStrings(context);
    final tokens = KitTokens.of(context);
    return ListenableBuilder(
      listenable: _usage,
      builder: (context, _) {
        final usage = _usage;
        final snapshot = usage.snapshot;
        final settings = usage.widgetSettings;
        return KitScreen(
          topBar: KitTopBar(title: l10n.usageWidgetTitle),
          width: KitScreenWidth.reading,
          body: ListView(
            key: const ValueKey('usage-widget-settings'),
            padding: EdgeInsetsDirectional.only(
              top: tokens.space2,
              bottom: KitScreen.endPadding(context),
            ),
            children: [
              Padding(
                padding: EdgeInsetsDirectional.symmetric(
                  horizontal: tokens.gutter,
                ),
                child: KitText(l10n.usageWidgetIntro, role: KitTextRole.body),
              ),
              SizedBox(height: tokens.sectionGap),
              if (snapshot.subscriptions.isEmpty)
                Padding(
                  padding: EdgeInsetsDirectional.symmetric(
                    horizontal: tokens.gutter,
                  ),
                  child: KitText(
                    l10n.usageEmptyTitle,
                    key: const ValueKey('usage-widget-none'),
                    role: KitTextRole.secondary,
                    tone: KitTextTone.secondary,
                  ),
                )
              else
                KitRowGroup(
                  key: const ValueKey('usage-widget-plans'),
                  label: l10n.usageWidgetSettingsShow,
                  children: [
                    for (final s in snapshot.subscriptions)
                      KitSwitchRow(
                        key: ValueKey('usage-widget-plan-${s.key}'),
                        leading: UsageText.logo(s.providerId),
                        title: UsageText.subscriptionName(l10n, s),
                        supporting: [
                          ?UsageText.plan(s.planLabel),
                          if (snapshot.hasSeveralConnections &&
                              (s.readFrom ?? s.fixConnection) != null)
                            l10n.usageOnConnection(
                              UsageText.connection(
                                l10n,
                                (s.readFrom ?? s.fixConnection)!,
                              ),
                            ),
                        ].join(' · '),
                        supportingMaxLines: 4,
                        value: !settings.hiddenKeys.contains(s.key),
                        onChanged: (value) => unawaited(
                          _write(
                            settings.copyWith(
                              hiddenKeys: {
                                for (final k in settings.hiddenKeys)
                                  if (k != s.key) k,
                                if (!value) s.key,
                              },
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              SizedBox(height: tokens.sectionGap),
              // The segmented control names itself to screen readers, so the
              // visible header is not read a second time.
              ExcludeSemantics(
                child: KitSectionLabel(l10n.usageWidgetSettingsWindows),
              ),
              Padding(
                padding: EdgeInsetsDirectional.symmetric(
                  horizontal: tokens.gutter,
                ),
                child: KitSegmented<UsageWidgetWindows>(
                  key: const ValueKey('usage-widget-windows'),
                  semanticsLabel: l10n.usageWidgetSettingsWindows,
                  selected: settings.windows,
                  onChanged: (value) =>
                      unawaited(_write(settings.copyWith(windows: value))),
                  segments: [
                    for (final value in [
                      UsageWidgetWindows.both,
                      UsageWidgetWindows.fiveHour,
                      UsageWidgetWindows.weekly,
                    ])
                      KitSegment(
                        value: value,
                        label: _windowsLabel(l10n, value),
                        key: ValueKey('usage-widget-windows-${value.name}'),
                      ),
                  ],
                ),
              ),
              SizedBox(height: tokens.sectionGap),
              KitRowGroup(
                children: [
                  KitSwitchRow(
                    key: const ValueKey('usage-widget-setup'),
                    leading: KitRow.icon(context, AppIconography.login),
                    title: l10n.usageWidgetSettingsSetup,
                    supporting: l10n.usageWidgetSettingsSetupHelp,
                    supportingMaxLines: 4,
                    value: settings.showSetupRows,
                    onChanged: (value) => unawaited(
                      _write(settings.copyWith(showSetupRows: value)),
                    ),
                  ),
                ],
              ),
              if (_saveFailed)
                Padding(
                  padding: EdgeInsetsDirectional.only(
                    start: tokens.gutter,
                    end: tokens.gutter,
                    top: tokens.space3,
                  ),
                  child: KitNotice.error(
                    key: const ValueKey('usage-widget-save-failed'),
                    message: l10n.usageSaveFailed,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
