import 'dart:async';

import 'package:flutter/material.dart';

import '../../diagnostics/app_log.dart';
import '../../l10n/app_localizations.dart';
import '../../platform/storage_access.dart';
import '../app_iconography.dart';
import '../kit/kit.dart';

/// The running log's entry in App diagnostics: where the private and public
/// files live, whether the public mirror is on, and the two ways to open the
/// app's storage (the log folder, or the whole private tree through the
/// system picker).
class AppLogSection extends StatefulWidget {
  const AppLogSection({super.key});

  @override
  State<AppLogSection> createState() => _AppLogSectionState();
}

class _AppLogSectionState extends State<AppLogSection>
    with WidgetsBindingObserver {
  StorageAccess _access = StorageAccess.notNeeded;
  bool _publicEnabled = AppLog.publicEnabled;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_read());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_read());
  }

  Future<void> _read() async {
    final access = await StorageAccessBridge.status();
    if (!mounted) return;
    if (access == StorageAccess.granted && !AppLog.publicEnabled) {
      await AppLog.refreshPublicLog();
    }
    if (!mounted) return;
    setState(() {
      _access = access;
      _publicEnabled = AppLog.publicEnabled;
    });
  }

  Future<void> _grant() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await StorageAccessBridge.request();
      final access = await StorageAccessBridge.status();
      if (access == StorageAccess.granted) {
        await AppLog.refreshPublicLog();
      }
      if (!mounted) return;
      setState(() {
        _access = access;
        _publicEnabled = AppLog.publicEnabled;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openStorage() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await StorageAccessBridge.openInternalStorage();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _browse() async {
    final copy = _copy(context);
    final confirmed = await showKitConfirm(
      context,
      title: copy.appLogBrowseTitle,
      body: copy.appLogBrowseWarning,
      consequences: [copy.appLogBrowseKeys],
      confirmLabel: copy.appLogBrowseConfirm,
      cancelLabel: copy.appLogBrowseCancel,
      icon: AppIconography.folderOpen,
      kind: KitConfirmKind.destructive,
      confirmKey: const ValueKey('app-log-browse-confirm'),
    );
    if (!confirmed || !mounted) return;
    await _openStorage();
  }

  @override
  Widget build(BuildContext context) {
    final copy = _copy(context);
    final privatePath = AppLog.directoryPath;
    final publicPath =
        AppLog.publicDirectoryPath ?? '/storage/emulated/0/OpenCodePlus/logs';
    return KitRowGroup(
      label: copy.appLogLabel,
      children: [
        KitRow(
          leading: KitRow.icon(context, AppIconography.fileText),
          title: copy.appLogPrivateTitle,
          supporting: TextSpan(
            text: privatePath ?? copy.appLogPathUnavailable,
          ),
          supportingMaxLines: 2,
        ),
        KitRow(
          leading: KitRow.icon(context, AppIconography.folderOpen),
          title: copy.appLogPublicTitle,
          supporting: TextSpan(
            text: _publicEnabled ? publicPath : copy.appLogPublicOff,
          ),
          supportingMaxLines: 2,
        ),
        if (_access != StorageAccess.granted)
          KitRow(
            leading: KitRow.icon(context, AppIconography.permissions),
            title: copy.appLogGrantTitle,
            supporting: TextSpan(text: copy.appLogGrantBody),
            supportingMaxLines: 2,
            onTap: _busy ? null : _grant,
          ),
        KitRow(
          leading: KitRow.icon(context, AppIconography.folderOpen),
          title: copy.appLogOpenTitle,
          onTap: _busy ? null : _openStorage,
        ),
        KitRow(
          leading: KitRow.icon(context, AppIconography.storage),
          title: copy.appLogBrowseTitle,
          supporting: TextSpan(text: copy.appLogBrowseBody),
          supportingMaxLines: 2,
          onTap: _busy ? null : _browse,
        ),
      ],
    );
  }

  AppLocalizations _copy(BuildContext context) =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      lookupAppLocalizations(const Locale('en'));
}