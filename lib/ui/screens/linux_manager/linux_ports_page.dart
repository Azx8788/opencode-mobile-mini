/// Linux › Ports: what listens inside the app's own Linux, which program
/// uses it when a command names the port, and one tap to open it in the dev
/// preview (the same preview, address rules and security checks the chat
/// uses: `openDevPreview` on this phone's loopback).
///
/// A port is listed only when a connection to it worked, so every row can
/// be opened. The OpenCode server and Paseo are listed without a preview
/// (they are not web pages). A port open to the whole network says so.
///
/// Kit parts only.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../builtin/builtin_linux.dart' show BuiltinLinux;
import '../../../builtin/linux_manager/linux_manager.dart';
import '../../../builtin/linux_manager/linux_ports.dart';
import '../../../builtin/linux_manager/linux_processes.dart';
import '../../../domain/dev_preview.dart';
import '../../../l10n/app_localizations.dart';
import '../../app_iconography.dart';
import '../../app_theme.dart' show AppIcons;
import '../../kit/kit.dart';
import '../dev_preview_screen.dart' show openDevPreview;
import 'linux_manager_common.dart';

class LinuxPortsPage extends ConsumerStatefulWidget {
  const LinuxPortsPage({super.key, this.refreshInterval, this.opener});

  /// Test seam for [openDevPreview].
  @visibleForTesting
  final Future<void> Function(DevPreviewLink link, String serverBaseUrl)?
  opener;

  /// Reads again on this interval while open; null reads on pull only.
  final Duration? refreshInterval;

  @override
  ConsumerState<LinuxPortsPage> createState() => _State();
}

class _State extends ConsumerState<LinuxPortsPage> {
  List<LinuxPort>? _ports;
  LinuxProcessScan? _scan;
  Object? _failure;
  bool _loading = true;
  bool _busy = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    final every = widget.refreshInterval;
    if (every != null) {
      _timer = Timer.periodic(every, (_) {
        if (mounted && !_busy) unawaited(_refresh());
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final manager = ref.read(linuxManagerProvider);
    try {
      final scan = await manager.scanProcesses();
      final ports = await manager.scanPorts(scan);
      if (!mounted) return;
      setState(() {
        _scan = scan;
        _ports = ports;
        _failure = null;
        _loading = false;
      });
    } on LinuxManagerException catch (error) {
      if (!mounted) return;
      setState(() {
        _failure = error;
        _loading = false;
      });
    }
  }

  Future<void> _preview(LinuxPort port) {
    final link = DevPreviewLink(port: port.port);
    // This phone's own server: the preview opens its loopback.
    final opener = widget.opener;
    if (opener != null) return opener(link, BuiltinLinux.serverUrl);
    return openDevPreview(context, link, serverBaseUrl: BuiltinLinux.serverUrl);
  }

  Future<void> _stopOwner(LinuxPort port) async {
    final owner = port.owner;
    final scan = _scan;
    if (owner == null || scan == null || owner.protected) return;
    final l10n = AppLocalizations.of(context);
    final name = linuxProcessTitle(l10n, owner);
    final helpers = scan.withDescendants([owner]).length - 1;
    final yes = await showKitConfirm(
      context,
      title: l10n.linuxMgrStopTitle(name),
      body: l10n.linuxMgrStopBody,
      confirmLabel: l10n.linuxMgrStopLabel(name),
      icon: AppIcons.stop,
      kind: KitConfirmKind.stop,
      consequenceItems: [
        if (helpers > 0) KitConsequence(l10n.linuxMgrStopHelpers(helpers)),
      ],
      sheetKey: const Key('linux-ports-confirm'),
      confirmKey: const Key('linux-ports-confirm-stop'),
    );
    if (!yes || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(linuxManagerProvider).stop([owner], scan);
    } on LinuxManagerException catch (error) {
      if (mounted) setState(() => _failure = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final ports = _ports;
    final Widget body;
    if (ports == null && _loading) {
      body = ListView(
        key: const ValueKey('linux-ports-loading'),
        padding: KitScreen.padding(context),
        children: const [KitSkeletonRows()],
      );
    } else if (ports == null) {
      body = KitStateView.error(
        key: const ValueKey('linux-ports-load-error'),
        title: l10n.linuxMgrLoadFailedTitle,
        body: linuxProblemText(l10n, _failure ?? Object()),
        details: linuxProblemDetails(_failure ?? Object()),
        retry: KitAction(label: l10n.commonRetry, onPressed: _refresh),
      );
    } else {
      body = KitRefresh(
        onRefresh: _refresh,
        child: ListView(
          key: const ValueKey('linux-ports-list'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsetsDirectional.only(
            top: KitTokens.of(context).space2,
            bottom: KitScreen.endPadding(context),
          ),
          children: [_list(context, l10n, ports)],
        ),
      );
    }
    return KitScreen(
      topBar: KitTopBar(title: l10n.linuxMgrPortsTitle),
      width: KitScreenWidth.reading,
      loading: _busy,
      loadingLabel: l10n.linuxMgrStopping,
      body: body,
    );
  }

  Widget _list(
    BuildContext context,
    AppLocalizations l10n,
    List<LinuxPort> ports,
  ) {
    final tokens = KitTokens.of(context);
    final rails = linuxRails(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_failure != null)
          Padding(
            padding: rails,
            child: KitNotice.error(
              message: linuxProblemText(l10n, _failure!),
              details: linuxProblemDetails(_failure!),
              retry: KitAction(label: l10n.commonRetry, onPressed: _refresh),
            ),
          ),
        if (ports.isEmpty)
          Padding(
            padding: rails,
            child: KitStateView(
              key: const Key('linux-ports-empty'),
              icon: AppIconography.network,
              title: l10n.linuxMgrPortsEmpty,
              body: l10n.linuxMgrPortsEmptyBody,
              size: KitStateSize.inline,
              padding: EdgeInsets.zero,
            ),
          )
        else ...[
          Padding(
            padding: rails,
            child: KitText(l10n.linuxMgrPortsNote, role: KitTextRole.caption),
          ),
          Padding(
            padding: EdgeInsetsDirectional.only(bottom: tokens.sectionGap),
            child: KitRowGroup(
              key: const Key('linux-ports-group'),
              children: [for (final p in ports) _row(context, l10n, p)],
            ),
          ),
        ],
      ],
    );
  }

  Widget _row(BuildContext context, AppLocalizations l10n, LinuxPort port) {
    final owner = port.owner;
    final kind = port.kind;
    final used = switch (kind) {
      LinuxProcessKind.openCodeServer => l10n.linuxMgrPortUsedBy(
        l10n.linuxMgrKindServer,
      ),
      _ when owner != null => l10n.linuxMgrPortUsedBy(
        linuxProcessTitle(l10n, owner),
      ),
      _ => l10n.linuxMgrPortUnknown,
    };
    final reach = port.allInterfaces == true
        ? l10n.linuxMgrPortAll
        : port.allInterfaces == false
        ? l10n.linuxMgrPortLocal
        : null;
    final line = [
      used,
      if (!port.canPreview) l10n.linuxMgrPortNotPage else ?reach,
    ].join(' · ');
    final address = 'http://127.0.0.1:${port.port}/';
    return KitRow(
      key: Key('linux-port-${port.port}'),
      leading: KitRow.icon(
        context,
        kind == null ? AppIconography.network : linuxKindIcon(kind),
      ),
      title: l10n.linuxMgrPortRow(port.port),
      supporting: TextSpan(text: line),
      supportingKey: Key('linux-port-line-${port.port}'),
      supportingMaxLines: 3,
      trailing: port.canPreview
          ? KitRowValue(l10n.linuxMgrPortPreview, chevron: true)
          : null,
      onTap: port.canPreview ? () => unawaited(_preview(port)) : null,
      menu: [
        if (port.canPreview)
          KitMenuItem(
            key: Key('linux-port-preview-${port.port}'),
            label: l10n.linuxMgrPortPreviewNamed(port.port),
            icon: AppIconography.browser,
            onSelected: () => unawaited(_preview(port)),
          ),
        KitMenuItem.copy(
          label: l10n.linuxMgrPortCopy,
          text: () => address,
          redact: false,
        ),
        if (owner != null && !owner.protected)
          KitMenuItem(
            key: Key('linux-port-stop-${port.port}'),
            label: l10n.linuxMgrStopLabel(linuxProcessTitle(l10n, owner)),
            icon: AppIcons.stop,
            destructive: true,
            enabled: !_busy,
            disabledReason: _busy ? l10n.linuxMgrStopping : null,
            onSelected: () => unawaited(_stopOwner(port)),
          ),
      ],
    );
  }
}
