import 'dart:async';

import 'package:flutter/material.dart';

import '../../../platform/platform_capabilities.dart';
import '../../../state/connection.dart';
import '../../../state/notification_preferences.dart';
import '../../../state/usage_subscriptions_controller.dart';
import '../../kit/kit.dart';
import 'usage_subscription_screen.dart';
import 'usage_text.dart';

const _levels = [50, 60, 70, 80, 90, 100];

/// Usage › Alerts: the one page for usage alerts. One switch watches every
/// subscription the app can read; the level and the reset message are
/// defaults any plan can differ from; quiet hours and Wi-Fi only are the
/// app's shared notification values, changed here or in Notifications.
class UsageAlertsScreen extends StatefulWidget {
  const UsageAlertsScreen({
    super.key,
    required this.controller,
    required this.usage,
    this.clock,
  });

  final ConnectionController controller;
  final UsageSubscriptionsController usage;
  final DateTime Function()? clock;

  @override
  State<UsageAlertsScreen> createState() => _UsageAlertsScreenState();
}

class _UsageAlertsScreenState extends State<UsageAlertsScreen> {
  bool _saveFailed = false;

  Future<void> _save(Future<Object?> Function() write) async {
    Object? result;
    try {
      result = await write();
    } on Object {
      result = false;
    }
    if (mounted) setState(() => _saveFailed = result == false);
  }

  Future<void> _shared(
    SharedNotifyRules Function(SharedNotifyRules rules) change,
  ) => _save(() async {
    await widget.controller.updateSharedNotifyRules(change);
    return true;
  });

  String _clock(int minutes) =>
      TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60).format(context);

  Future<void> _quietTime(bool start, SharedNotifyRules rules) async {
    final l10n = usageStrings(context);
    final current = (start ? rules.quietStart : rules.quietEnd)!;
    final selected = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
      helpText: start ? l10n.notifyQuietStartPicker : l10n.notifyQuietEndPicker,
      confirmText: l10n.notifyQuietSet,
    );
    if (selected == null || !mounted) return;
    final minutes = selected.hour * 60 + selected.minute;
    await _shared(
      (rules) => start
          ? rules.copyWith(quietStart: minutes)
          : rules.copyWith(quietEnd: minutes),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = usageStrings(context);
    final tokens = KitTokens.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([widget.usage, widget.controller]),
      builder: (context, _) {
        final usage = widget.usage;
        final rules = widget.controller.sharedNotifyRules;
        final levels = {..._levels, usage.defaultThreshold.round()}.toList()
          ..sort();
        final overrides = usage.alertOverrides;
        final snapshot = usage.snapshot;
        final quiet = platformCapabilities.supportsNotifications;
        final wifi = platformCapabilities.supportsBackgroundService;
        final allDay = rules.quietEnabled && rules.quietStart == rules.quietEnd;
        return KitScreen(
          topBar: KitTopBar(title: l10n.usageAlertsTitle),
          width: KitScreenWidth.reading,
          body: ListView(
            key: const ValueKey('usage-alerts'),
            padding: EdgeInsetsDirectional.only(
              top: tokens.space2,
              bottom: KitScreen.endPadding(context),
            ),
            children: [
              KitRowGroup(
                leadingIcons: false,
                children: [
                  KitSwitchRow(
                    key: const ValueKey('usage-alerts-switch'),
                    title: l10n.usageAlertsSwitch,
                    supporting: l10n.usageAlertsForEvery,
                    supportingMaxLines: 2,
                    value: usage.alertsOn,
                    onChanged: (value) => _save(() async {
                      await usage.setAlertsOn(value);
                      return true;
                    }),
                  ),
                ],
              ),
              if (usage.alertsOn) ...[
                KitRowGroup(
                  key: const ValueKey('usage-alerts-tell-me'),
                  leadingIcons: false,
                  label: l10n.usageAlertsTellMe,
                  children: [
                    // Stored as "% used"; the person reads "% left".
                    KitPickerRow<int>(
                      rowKey: const ValueKey('usage-alerts-default'),
                      title: l10n.usageAlertPlanDownTo,
                      valueLabel: l10n.usageLeft(
                        100 - usage.defaultThreshold.round(),
                      ),
                      selected: usage.defaultThreshold.round(),
                      choices: [
                        for (final level in levels)
                          KitChoice(
                            value: level,
                            title: l10n.usageLeft(100 - level),
                          ),
                      ],
                      onSelected: (level) => _save(
                        () => usage.setDefaultThreshold(level.toDouble()),
                      ),
                    ),
                    KitSwitchRow(
                      key: const ValueKey('usage-alerts-reset'),
                      title: l10n.usageAlertUsedUpBack,
                      value: usage.notifyOnResetDefault,
                      onChanged: (value) =>
                          _save(() => usage.setNotifyOnResetDefault(value)),
                    ),
                  ],
                ),
              ],
              if (_saveFailed)
                Padding(
                  padding: EdgeInsetsDirectional.only(
                    start: tokens.gutter,
                    end: tokens.gutter,
                    top: tokens.space3,
                  ),
                  child: KitNotice.error(
                    key: const ValueKey('usage-alerts-save-failed'),
                    message: l10n.usageSaveFailed,
                  ),
                ),
              if (usage.alertsOn && overrides.isNotEmpty) ...[
                SizedBox(height: tokens.sectionGap),
                KitRowGroup(
                  key: const ValueKey('usage-alerts-different'),
                  leadingIcons: false,
                  label: l10n.usageAlertsDifferent,
                  children: [
                    for (final s in overrides)
                      KitRow(
                        key: ValueKey('usage-alerts-override-${s.key}'),
                        title: UsageText.subscriptionName(l10n, s),
                        titleMaxLines: 2,
                        supporting: TextSpan(
                          text: [
                            l10n.usageLeft(100 - s.alertThreshold.round()),
                            if (s.notifyOnReset != usage.notifyOnResetDefault)
                              s.notifyOnReset
                                  ? l10n.usageAlertOverrideResetOn
                                  : l10n.usageAlertOverrideResetOff,
                          ].join(' · '),
                        ),
                        supportingMaxLines: 2,
                        trailing: const KitChevron(),
                        onTap: () => pushKitPage<void>(
                          context,
                          (_) => UsageSubscriptionScreen(
                            controller: widget.controller,
                            usage: usage,
                            subscriptionKey: s.key,
                            clock: widget.clock,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              if (usage.alertsOn && (quiet || wifi)) ...[
                SizedBox(height: tokens.sectionGap),
                KitRowGroup(
                  key: const ValueKey('usage-alerts-when'),
                  leadingIcons: false,
                  label: l10n.usageAlertsQuietGroup,
                  children: [
                    if (quiet) ...[
                      KitSwitchRow(
                        key: const ValueKey('usage-alerts-quiet'),
                        title: l10n.monitorQuiet,
                        supporting: l10n.usageQuietSameAsOthers,
                        value: rules.quietEnabled,
                        onChanged: (value) => _shared(
                          (rules) => value
                              ? rules.copyWith(
                                  quietStart:
                                      SharedNotifyRules.defaultQuietStart,
                                  quietEnd: SharedNotifyRules.defaultQuietEnd,
                                )
                              : rules.copyWith(clearQuiet: true),
                        ),
                      ),
                      if (rules.quietEnabled) ...[
                        KitRow(
                          key: const ValueKey('usage-alerts-quiet-start'),
                          title: l10n.monitorQuietStart,
                          trailing: KitRowValue(_clock(rules.quietStart!)),
                          onTap: () => unawaited(_quietTime(true, rules)),
                        ),
                        KitRow(
                          key: const ValueKey('usage-alerts-quiet-end'),
                          title: l10n.monitorQuietEnd,
                          supporting: allDay
                              ? TextSpan(text: l10n.notifyQuietAllDay)
                              : null,
                          supportingMaxLines: 2,
                          trailing: KitRowValue(_clock(rules.quietEnd!)),
                          onTap: () => unawaited(_quietTime(false, rules)),
                        ),
                      ],
                    ],
                    if (wifi)
                      KitSwitchRow(
                        key: const ValueKey('usage-alerts-wifi'),
                        title: l10n.usageWifiOnlyShort,
                        value: rules.wifiOnly,
                        onChanged: (value) =>
                            _shared((rules) => rules.copyWith(wifiOnly: value)),
                      ),
                  ],
                ),
              ],
              if (usage.alertsOn &&
                  snapshot.subscriptions.isEmpty &&
                  snapshot.loaded)
                Padding(
                  padding: EdgeInsetsDirectional.only(
                    start: tokens.gutter,
                    end: tokens.gutter,
                    top: tokens.space3,
                  ),
                  child: KitText(
                    l10n.usageAlertsNothingToWatch,
                    key: const ValueKey('usage-alerts-nothing'),
                    role: KitTextRole.caption,
                    tone: KitTextTone.secondary,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
