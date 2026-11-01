import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/factsbook/factsbook_capabilities.dart';
import '../../../domain/factsbook/factsbook_types.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/factsbook/factsbook_controller.dart';
import '../../../state/factsbook/phone_zone.dart';
import '../../app_iconography.dart';
import '../../kit/kit.dart';
import 'factsbook_routes.dart';
import 'factsbook_text.dart';

/// FactsBook settings, for what the node lets a client see and change: how
/// long the locked folder stays open (shown; the node sets it), the daily
/// brief's cap (changed with this phone's approval key), the brief's time and
/// quiet hours (shown), the home time zone (shown, and switched to this
/// phone's zone with its approval key when they differ), the spending limit
/// (nothing may be spent), and a way into area sharing.
class FactsBookSettingsScreen extends ConsumerStatefulWidget {
  const FactsBookSettingsScreen({super.key});

  @override
  ConsumerState<FactsBookSettingsScreen> createState() =>
      _FactsBookSettingsScreenState();
}

class _FactsBookSettingsScreenState
    extends ConsumerState<FactsBookSettingsScreen> {
  FactsBookSettings? _settings;
  Object? _failure;
  bool _loading = true;
  bool _saving = false;
  String? _notice;

  /// This phone's IANA time zone, when Android says.
  String? _phoneZone;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  FactsBookController get _controller => ref.read(factsBookControllerProvider);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final settings = await _controller.settings();
      if (mounted) setState(() => _settings = settings);
      unawaited(
        phoneTimeZone().then((zone) {
          if (mounted && zone != _phoneZone) setState(() => _phoneZone = zone);
        }),
      );
    } on FactsBookException catch (failure) {
      if (mounted) setState(() => _failure = failure);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setCap(int cap) async {
    final settings = _settings;
    if (settings == null) return;
    final l10n = AppLocalizations.of(context);
    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      await _controller.setBriefCap(settings, cap);
      await _load();
    } on FactsBookException catch (failure) {
      if (!mounted) return;
      setState(() => _notice = failureWords(l10n, failure));
      if (failure.stale) await _load();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _usePhoneZone(String zone) async {
    final settings = _settings;
    if (settings == null) return;
    final l10n = AppLocalizations.of(context);
    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      await _controller.setHomeZone(settings, zone);
      await _load();
    } on FactsBookException catch (failure) {
      if (!mounted) return;
      setState(() => _notice = failureWords(l10n, failure));
      if (failure.stale) await _load();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final controller = ref.watch(factsBookControllerProvider);
    controller.session.approvalReason = l10n.fbAuthReason;
    final settings = _settings;
    final Widget body;
    if (settings == null && _failure == null) {
      body = ListView(
        padding: KitScreen.padding(context),
        children: const [KitSkeletonRows()],
      );
    } else if (settings == null) {
      body = KitStateView.error(
        key: const ValueKey('factsbook-settings-error'),
        title: l10n.fbErrorTitle,
        body: failureWords(l10n, _failure),
        details: failureDetails(l10n, _failure),
        retry: KitAction(
          label: l10n.commonRetry,
          onPressed: () => unawaited(_load()),
        ),
      );
    } else {
      final rails = EdgeInsetsDirectional.symmetric(horizontal: tokens.gutter);
      final canChange = controller.session.canApprove;
      final cap = settings.brief.capPerDay;
      final caps = {
        ...{0, 1, 3, 5, 10, 20},
        cap,
      }.toList()..sort();
      body = KitRefresh(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsetsDirectional.only(
            top: tokens.space2,
            bottom: KitScreen.endPadding(context),
          ),
          children: [
            if (!canChange)
              Padding(
                padding: rails.add(
                  EdgeInsetsDirectional.only(bottom: tokens.space3),
                ),
                child: KitNotice(
                  key: const ValueKey('factsbook-settings-needs-owner'),
                  icon: AppIconography.info,
                  message: l10n.fbSettingsNeedsOwner,
                  actions: [
                    KitAction(
                      label: l10n.fbCareSetupApproval,
                      onPressed: () => unawaited(openFactsBookConnect(context)),
                    ),
                  ],
                ),
              ),
            if (_notice != null)
              Padding(
                padding: rails.add(
                  EdgeInsetsDirectional.only(bottom: tokens.space3),
                ),
                child: KitNotice(
                  key: const ValueKey('factsbook-settings-notice'),
                  message: _notice!,
                  onDismiss: () => setState(() => _notice = null),
                  dismissLabel: l10n.fbDismiss,
                ),
              ),
            KitRowGroup(
              label: l10n.fbSettingsBrief,
              children: [
                KitPickerRow<int>(
                  rowKey: const ValueKey('factsbook-settings-cap'),
                  title: l10n.fbSettingsBriefCap,
                  selected: cap,
                  valueLabel: cap == 0
                      ? l10n.fbSettingsBriefOff
                      : l10n.fbSettingsBriefItems(cap),
                  supporting: l10n.fbSettingsBriefCapDetail,
                  choices: [
                    for (final n in caps)
                      KitChoice(
                        value: n,
                        title: n == 0
                            ? l10n.fbSettingsBriefOff
                            : l10n.fbSettingsBriefItems(n),
                      ),
                  ],
                  onSelected: canChange && !_saving
                      ? (n) => unawaited(_setCap(n))
                      : null,
                  disabledReason: canChange ? null : l10n.fbCareNeedsOwnerShort,
                ),
                KitRow(
                  key: const ValueKey('factsbook-settings-brief-time'),
                  title: l10n.fbSettingsBriefTime,
                  supporting: TextSpan(text: KitBidi.ltr(settings.brief.time)),
                ),
                KitRow(
                  key: const ValueKey('factsbook-settings-quiet'),
                  title: l10n.fbSettingsQuietHours,
                  supporting: TextSpan(
                    text: KitBidi.ltr(settings.brief.quietHours),
                  ),
                ),
              ],
            ),
            KitRowGroup(
              label: l10n.fbSettingsPrivacy,
              children: [
                KitRow(
                  key: const ValueKey('factsbook-settings-lock'),
                  leading: KitRow.icon(context, AppIconography.locked),
                  title: l10n.fbSettingsLockTimeout,
                  supporting: TextSpan(
                    text: l10n.fbSettingsMinutes(settings.lockTimeoutMinutes),
                  ),
                ),
                if (controller.session.capabilities.supports(
                  FactsBookCapabilities.triggers,
                ))
                  KitRow(
                    key: const ValueKey('factsbook-settings-triggers'),
                    leading: KitRow.icon(context, AppIconography.sparkle),
                    title: l10n.fbTriggersTitle,
                    supporting: TextSpan(text: l10n.fbTriggersSettingsDetail),
                    trailing: const KitChevron(),
                    onTap: () => unawaited(openFactsBookTriggers(context)),
                  ),
                KitRow(
                  key: const ValueKey('factsbook-settings-areas'),
                  leading: KitRow.icon(context, AppIconography.privacy),
                  title: l10n.fbAreasTitle,
                  supporting: TextSpan(text: l10n.fbSettingsAreasDetail),
                  trailing: const KitChevron(),
                  onTap: () => unawaited(openFactsBookAreas(context)),
                ),
              ],
            ),
            KitRowGroup(
              label: l10n.fbSettingsThisNode,
              children: [
                KitRow(
                  key: const ValueKey('factsbook-settings-zone'),
                  title: l10n.fbSettingsHomeZone,
                  supporting: TextSpan(text: KitBidi.ltr(settings.vaultZone)),
                ),
                if (_phoneZone case final phoneZone?
                    when phoneZone != settings.vaultZone &&
                        controller.session.canApprove)
                  KitRow(
                    key: const ValueKey('factsbook-settings-use-phone-zone'),
                    leading: KitRow.icon(context, AppIconography.clock),
                    title: l10n.fbSettingsUsePhoneZone,
                    supporting: TextSpan(
                      text: l10n.fbSettingsUsePhoneZoneDetail(
                        KitBidi.ltr(phoneZone),
                      ),
                    ),
                    onTap: _saving
                        ? null
                        : () => unawaited(_usePhoneZone(phoneZone)),
                  ),
                KitRow(
                  key: const ValueKey('factsbook-settings-spend'),
                  title: l10n.fbSettingsSpending,
                  supporting: TextSpan(text: l10n.fbSettingsSpendingNone),
                ),
              ],
            ),
            KitGroupNote(message: l10n.fbSettingsFootnote),
          ],
        ),
      );
    }
    return KitScreen(
      topBar: KitTopBar(title: l10n.fbSettingsTitle),
      width: KitScreenWidth.reading,
      loading: (_loading && settings != null) || _saving,
      loadingLabel: l10n.fbSettingsTitle,
      body: body,
    );
  }
}
