import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../app_iconography.dart';
import '../kit/kit_buttons.dart';
import '../kit/kit_log_panel.dart';
import '../kit/kit_notice.dart';
import '../kit/kit_sheet.dart';

/// The logs of a dev server found running, in one sheet: follows new lines,
/// pause and follow, search with marked matches, wrap, copy all and selection
/// (all the kit log panel's). [read] returns the end of the output as plain
/// text and is called again every few seconds while the sheet is open.
/// [unavailable] replaces the viewer with one plain sentence when the
/// output cannot be read at all.
Future<void> showDevServerLogs(
  BuildContext context, {
  required String title,
  required Future<String> Function() read,
  String? unavailable,
  KitAction? primary,
  KitAction? secondary,
  Key? sheetKey,
}) {
  final l10n = AppLocalizations.of(context);
  return showKitSheet<void>(
    context,
    title: '$title · ${l10n.servicesLogs}',
    icon: AppIconography.text,
    height: KitSheetHeight.full,
    sheetKey: sheetKey ?? const ValueKey('dev-server-logs'),
    body: (_) => unavailable != null
        ? KitNotice(
            key: const ValueKey('dev-server-logs-unavailable'),
            message: unavailable,
            icon: AppIconography.info,
          )
        : _DevServerLogs(read: read),
    primary: primary,
    secondary: secondary,
  );
}

class _DevServerLogs extends StatefulWidget {
  const _DevServerLogs({required this.read});
  final Future<String> Function() read;

  @override
  State<_DevServerLogs> createState() => _DevServerLogsState();
}

class _DevServerLogsState extends State<_DevServerLogs> {
  final _buffer = KitLogBuffer(capacity: KitLogPanel.defaultMaxLines);
  bool _first = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load().catchError((_) {}));
  }

  Future<void> _load() async {
    final text = await widget.read();
    if (!mounted) return;
    _first = false;
    _buffer.replaceText(text);
  }

  @override
  void dispose() {
    _buffer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .6,
      child: KitLogPanel(
        panelKey: const ValueKey('dev-server-log-panel'),
        lines: _buffer,
        title: l10n.servicesLogs,
        live: true,
        size: KitLogSize.fill,
        searchable: true,
        emptyText: _first ? l10n.servicesLogEmpty : null,
        onRefresh: _load,
      ),
    );
  }
}
