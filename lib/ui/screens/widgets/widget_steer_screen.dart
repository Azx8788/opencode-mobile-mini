import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../widgets_overlay/widget_compose_controller.dart';
import '../../../widgets_overlay/widget_overlay_api.dart';
import '../../../widgets_overlay/widget_overlay_launch.dart';
import '../../kit/kit.dart';

/// The floating box a widget's composer or microphone opens: type or dictate
/// a message and send it. Steer sends it into the running reply (or after it,
/// where the connection can only do that); the voice route opens dictation
/// at once and starts a new conversation after an explicit Send.
class WidgetSteerScreen extends StatefulWidget {
  const WidgetSteerScreen({
    super.key,
    required this.api,
    required this.launch,
    this.voice = false,
    this.closeDelay = const Duration(milliseconds: 700),
  });

  final WidgetOverlayApi api;
  final WidgetOverlayLaunch launch;
  final bool voice;
  final Duration closeDelay;

  @override
  State<WidgetSteerScreen> createState() => _WidgetSteerScreenState();
}

class _WidgetSteerScreenState extends State<WidgetSteerScreen> {
  late final WidgetComposeController _c = WidgetComposeController(
    api: widget.api,
    steerMode: widget.launch.steerMode,
    voice: widget.voice,
    closeDelay: widget.closeDelay,
  );

  String? _tag(BuildContext context) {
    final Locale locale = Localizations.localeOf(context);
    final tag = locale.toLanguageTag();
    return tag == 'und' ? null : tag;
  }

  @override
  void initState() {
    super.initState();
    if (widget.voice) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _c.dictate(languageTag: _tag(context));
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final block = _c.block;
        final title = widget.voice
            ? l10n.widgetV2VoiceTitle
            : switch (widget.launch.steerMode) {
                'afterReply' => l10n.widgetV2AfterReplyTitle,
                _ => l10n.widgetV2SteerTitle,
              };
        final blockedReason = switch (block) {
          null => null,
          WidgetComposeBlock.restart => l10n.widgetV2RestartUnavailable,
          WidgetComposeBlock.unknown => l10n.widgetV2UnknownBehavior,
          WidgetComposeBlock.uncertain => l10n.widgetV2Uncertain,
        };
        final message = switch (_c.notice) {
          null => null,
          WidgetComposeNotice.stale => l10n.widgetV2StaleRequest,
          WidgetComposeNotice.unavailable => l10n.widgetV2Unavailable,
          WidgetComposeNotice.unsupported => l10n.widgetV2Unsupported,
          WidgetComposeNotice.busy => l10n.widgetV2Busy,
          WidgetComposeNotice.invalid => l10n.widgetV2InvalidRequest,
          WidgetComposeNotice.uncertain => l10n.widgetV2Uncertain,
          WidgetComposeNotice.dictationUnavailable =>
            l10n.widgetV2DictationUnavailable,
        };
        return KitFloatingPanel(
          onDismiss: _c.phase == KitSteerBoxPhase.sending
              ? null
              : () => widget.api.close(),
          child: KitSteerBox(
            title: title,
            controller: _c.text,
            hint: l10n.widgetV2MessageHint,
            sendLabel: l10n.widgetV2Send,
            phase: _c.phase,
            message: block == WidgetComposeBlock.uncertain ? null : message,
            blockedReason: blockedReason,
            fieldKey: const ValueKey('widget-steer-field'),
            micKey: const ValueKey('widget-steer-mic'),
            onSend: _c.send,
            onDictate: () => _c.dictate(languageTag: _tag(context)),
            onClose: () => widget.api.close(),
          ),
        );
      },
    );
  }
}
