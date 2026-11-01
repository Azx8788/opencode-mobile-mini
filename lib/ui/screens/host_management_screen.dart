import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../platform/platform_capabilities.dart';
import '../../state/connection.dart';
import '../app_theme.dart';
import '../kit/kit_buttons.dart';
import '../kit/kit_code_block.dart';
import '../kit/kit_row.dart';
import '../kit/kit_screen.dart';
import '../kit/kit_text.dart';
import '../kit/kit_tokens.dart';
import '../kit/kit_top_bar.dart';
import '../setup_commands.dart';
import '../widgets/external_link.dart';

/// Copyable OpenCode 2 setup commands for a remote computer. The app does
/// not execute these commands: installation uses the pinned official npm
/// package, and the foreground server prints its own password.
class HostManagementScreen extends StatelessWidget {
  const HostManagementScreen({super.key, required this.controller});

  final ConnectionController controller;

  int _serverPort() {
    final uri = Uri.tryParse(controller.profile?.baseUrl ?? '');
    if (uri == null || uri.host.isEmpty) return 4096;
    return uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final l10n = lookupAppLocalizations(Localizations.localeOf(context));
        // Only a remote server has this page, so its saved name is its
        // shown name.
        final server = controller.profile?.name ?? l10n.e7SetupDefaultServer;
        return KitScreen(
          topBar: KitTopBar(title: l10n.hostServiceTitle(server)),
          width: KitScreenWidth.reading,
          body: _list(context, l10n, server),
        );
      },
    );
  }

  Widget _list(BuildContext context, AppLocalizations l10n, String server) {
    final tokens = KitTokens.of(context);
    final port = _serverPort();
    return ListView(
      padding: EdgeInsets.only(
        top: tokens.space3,
        bottom: KitScreen.endPadding(context),
      ),
      children: [
        // Where the commands run, once, under the bar.
        Padding(
          padding: EdgeInsetsDirectional.symmetric(horizontal: tokens.gutter),
          child: KitText(
            l10n.hostServiceIntro(server),
            key: const ValueKey('host-service-intro'),
            tone: KitTextTone.secondary,
          ),
        ),
        KitRowGroup(
          label: l10n.e7SetupHostFirstSetup,
          leadingIcons: false,
          children: [
            _HostCommand(
              key: const ValueKey('host-command-install'),
              label: l10n.openCode2HostInstall,
              detail: l10n.openCode2HostInstallDetail,
              command: HostScripts.install(port),
            ),
            // `adb reverse` forwards a port to an attached *Android* device.
            // On desktop the app and the server share a machine, so the tile
            // described a cable that is not there.
            if (platformCapabilities.supportsUsbHostBridge)
              _HostCommand(
                key: const Key('host-command-adb-reverse'),
                label: l10n.e7SetupUsbAccess,
                command: 'adb reverse tcp:$port tcp:$port',
              ),
          ],
        ),
        Padding(
          padding: EdgeInsetsDirectional.only(
            start: tokens.gutter,
            end: tokens.gutter,
            top: tokens.space3,
          ),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: KitButton.tertiary(
              key: const ValueKey('host-docs-link'),
              label: l10n.e7SetupFullWalkthrough,
              icon: AppIconography.externalLink,
              onPressed: () =>
                  openExternalLink(context, HostScripts.ubuntuGuideUrl),
            ),
          ),
        ),
      ],
    );
  }
}

/// One host command: what it does, why (optional), and the command itself
/// in the kit's code block with its own copy button.
class _HostCommand extends StatelessWidget {
  const _HostCommand({
    super.key,
    required this.label,
    required this.command,
    this.detail,
  });

  final String label;
  final String? detail;
  final String command;

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final detail = this.detail;
    return KitRow(
      title: label,
      titleMaxLines: 2,
      supporting: detail == null ? null : TextSpan(text: detail),
      supportingMaxLines: 4,
      below: Padding(
        padding: EdgeInsets.only(top: tokens.space2, bottom: tokens.space2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KitCodeBlock(
              text: command,
              kind: KitCodeKind.command,
              // A block of several lines reads its Copy in a header right
              // under the row's title, so it does not repeat the title.
              copyLabel: command.contains('\n')
                  ? l10n.kitCodeCopyCommand
                  : l10n.e7SetupCopyCommandLabel(label),
              copyKey: ValueKey('copy-host-command-$label'),
            ),
          ],
        ),
      ),
    );
  }
}
