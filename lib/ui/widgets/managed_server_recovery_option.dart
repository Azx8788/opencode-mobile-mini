import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../platform/platform_capabilities.dart';
import '../../termux/managed_server_recovery.dart';
import '../app_iconography.dart';
import '../kit/kit.dart';

/// "Restart after a crash": the opt-in foreground recovery of the server
/// this app runs in Termux, as one switch row in the phone server's
/// Options (docs/design/phone-server-screens-cleanup-2026-09-24.md §1, §2).
/// It moved here from the servers list, which is for choosing a server.
///
/// Under the switch: the attempts used (the budget survives app restarts),
/// what recovery is doing, any error with its way out, and the Android
/// caveat. It reads and writes [ManagedServerRecovery] only; nothing here
/// installs, updates or starts anything by itself.
///
/// Kit only (shared-phone-1): a [KitSwitchRow], its notes as [KitText] in
/// the row's own inset, and the ways out in a [KitActionBlock].
class ManagedServerRecoveryOption extends StatefulWidget {
  const ManagedServerRecoveryOption({
    super.key,
    required this.prefs,
    required this.profileID,
  });

  final SharedPreferences prefs;
  final String profileID;

  @override
  State<ManagedServerRecoveryOption> createState() =>
      _ManagedServerRecoveryOptionState();
}

class _ManagedServerRecoveryOptionState
    extends State<ManagedServerRecoveryOption> {
  ManagedServerRecovery? _recovery;

  /// Null: no error. True: saving or revoking the setting failed. False:
  /// checking recovery failed.
  bool? _policyError;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(ManagedServerRecoveryOption oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.prefs != widget.prefs ||
        oldWidget.profileID != widget.profileID) {
      _recovery?.removeListener(_changed);
      _bind();
    }
  }

  void _bind() {
    _recovery = platformCapabilities.supportsTermux
        ? ManagedServerRecovery.forProfile(widget.prefs, widget.profileID)
        : null;
    _recovery?.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _recovery?.removeListener(_changed);
    super.dispose();
  }

  Future<void> _set(bool enabled) async {
    setState(() => _policyError = null);
    try {
      await _recovery?.setEnabled(enabled);
    } catch (_) {
      if (mounted) setState(() => _policyError = true);
    }
  }

  Future<void> _retryCheck(ManagedServerRecovery recovery) async {
    try {
      await recovery.retryCheck();
    } catch (_) {
      if (mounted) setState(() => _policyError = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final recovery = _recovery;
    if (recovery == null) return const SizedBox.shrink();
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final tokens = KitTokens.of(context);
    Widget note(String text, {Key? key}) => KitText(
      text,
      key: key,
      role: KitTextRole.secondary,
      tone: KitTextTone.secondary,
    );
    // A problem is said in words, in text1 (LOOK-5: the error tone marks
    // acts that lose data, never a failure state).
    Widget problem(String text) =>
        KitText(text, role: KitTextRole.secondary, tone: KitTextTone.primary);
    // The counter and the caveat matter once recovery is on (or has been):
    // off, the row's own line says what it would do.
    final used = recovery.enabled || recovery.attempts > 0;
    final notes = <Widget>[
      if (used)
        note(
          l10n.managedRecoveryAttempts(recovery.attempts),
          key: const ValueKey('managed-recovery-attempts'),
        ),
      if (recovery.exhausted) note(l10n.managedRecoveryExhausted),
      if (recovery.enabled && recovery.paused && recovery.error == null)
        note(l10n.managedRecoveryBackground),
      if (recovery.busy) note(l10n.managedRecoveryChecking),
      if (recovery.nextAttemptAt case final next?)
        if (recovery.enabled && !recovery.exhausted)
          note(
            l10n.managedRecoveryNext(
              MaterialLocalizations.of(
                context,
              ).formatTimeOfDay(TimeOfDay.fromDateTime(next)),
            ),
          ),
      if (recovery.error case final error?)
        problem(switch (error) {
          ManagedRecoveryError.settingsUnreadable =>
            l10n.managedRecoverySettingsUnreadable,
          ManagedRecoveryError.enableFailed => l10n.managedRecoveryEnableFailed,
          ManagedRecoveryError.ownershipChanged =>
            l10n.managedRecoveryOwnershipChanged,
          ManagedRecoveryError.uncertainResult => l10n.managedRecoveryUncertain,
        }),
      if (_policyError case final revoke?)
        problem(
          revoke
              ? l10n.managedRecoveryRevokeFailed
              : l10n.managedRecoverySaveFailed,
        ),
    ];
    final actions = <KitAction>[
      if (_policyError == true)
        KitAction(
          label: l10n.managedRecoveryRetryDisable,
          onPressed: () => _set(false),
        ),
      if (recovery.enabled && recovery.error != null)
        KitAction(
          label: l10n.managedRecoveryCheck,
          onPressed: recovery.busy ? null : () => _retryCheck(recovery),
        ),
      if (recovery.exhausted)
        KitAction(
          label: l10n.managedRecoveryReset,
          onPressed: recovery.busy ? null : () => _set(true),
        ),
    ];
    if (recovery.enabled) {
      notes.add(
        note(
          l10n.managedHealthLifetime,
          key: const ValueKey('managed-recovery-caveat'),
        ),
      );
    }
    // A search result for "crash" arrives here (KitArrival).
    return KitArrival(
      id: 'managed-recovery-option',
      child: Column(
        key: const ValueKey('managed-recovery-option'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          KitSwitchRow(
            switchKey: const ValueKey('managed-recovery-switch'),
            leading: KitRow.icon(context, AppIconography.restart),
            title: l10n.managedRecoveryRowTitle,
            supporting: l10n.managedRecoveryRowDetail,
            value: recovery.enabled,
            onChanged: recovery.busy && !recovery.enabled ? null : _set,
          ),
          if (notes.isNotEmpty || actions.isNotEmpty)
            Padding(
              // Under the row's words: past its icon tile and the gap after
              // it, the inset of the row's own hairline (KitDividerInset.text).
              padding: EdgeInsetsDirectional.only(
                start: tokens.space4 + tokens.iconTileSize + tokens.space3,
                end: tokens.space4,
                bottom: tokens.space2,
              ),
              child: Semantics(
                liveRegion: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final note in notes)
                      Padding(
                        padding: EdgeInsetsDirectional.only(
                          bottom: tokens.space1,
                        ),
                        child: note,
                      ),
                    if (actions.isNotEmpty) KitActionBlock(tertiary: actions),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
