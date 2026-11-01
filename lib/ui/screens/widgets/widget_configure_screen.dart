import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../widgets_overlay/widget_accents.dart';
import '../../../widgets_overlay/widget_overlay_api.dart';
import '../../../widgets_overlay/widget_overlay_launch.dart';
import '../../../widgets_overlay/widget_style_controller.dart';
import '../../app_iconography.dart';
import '../../app_theme.dart' show AppStatusTone;
import '../../kit/kit.dart';
import '../../theme_roles.dart';

/// The small window a home-screen widget opens when it is placed (and when it
/// is reconfigured): its ground, its accent, a drawing of the result, Save.
/// Saving styles this one widget; the host closes itself when it is saved.
class WidgetConfigureScreen extends StatefulWidget {
  const WidgetConfigureScreen({
    super.key,
    required this.api,
    required this.launch,
  });

  final WidgetOverlayApi api;
  final WidgetOverlayLaunch launch;

  @override
  State<WidgetConfigureScreen> createState() => _WidgetConfigureScreenState();
}

class _WidgetConfigureScreenState extends State<WidgetConfigureScreen> {
  late final WidgetStyleController _style = WidgetStyleController(
    api: widget.api,
    backgroundId: widget.launch.styleBackground,
    accentId: widget.launch.styleAccent,
  );

  @override
  void dispose() {
    _style.dispose();
    super.dispose();
  }

  String _accentName(AppLocalizations l10n, String id) => switch (id) {
    'wallpaper' => l10n.widgetV2AccentWallpaper,
    'app' => l10n.widgetV2AccentApp,
    'green' => l10n.widgetV2AccentGreen,
    'teal' => l10n.widgetV2AccentTeal,
    'blue' => l10n.widgetV2AccentBlue,
    _ => l10n.widgetV2AccentAmber,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final ThemeRoles roles = tokens.roles;
    return KitFloatingPanel(
      onDismiss: () => widget.api.close(),
      child: ListenableBuilder(
        listenable: _style,
        builder: (context, _) {
          final s = _style;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: KitText(
                      l10n.widgetV2ConfigureTitle,
                      role: KitTextRole.headline,
                      tone: KitTextTone.primary,
                    ),
                  ),
                  KitIconButton(
                    icon: AppIconography.close,
                    tooltip: l10n.widgetV2Cancel,
                    onPressed: s.saving ? null : () => widget.api.close(),
                    disabledReason: l10n.widgetV2Sending,
                  ),
                ],
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.only(top: tokens.space3),
                  children: [
                    KitWidgetStyleForm(
                      previewSize: s.previewSize,
                      background: s.backgroundId,
                      accent: s.accentId,
                      accentIds: WidgetOverlayLaunch.accents,
                      accentName: (id) => _accentName(l10n, id),
                      accentColor: (id) => widgetAccentColor(id, roles),
                      onPreviewSize: s.choosePreviewSize,
                      onBackground: s.chooseBackground,
                      onAccent: s.chooseAccent,
                      locked: s.saving,
                    ),
                  ],
                ),
              ),
              if (s.problem != null) ...[
                SizedBox(height: tokens.space3),
                KitNotice(
                  icon: AppIconography.info,
                  tone: AppStatusTone.neutral,
                  message: switch (s.problem!) {
                    WidgetStyleProblem.stale => l10n.widgetV2StyleStale,
                    WidgetStyleProblem.unavailable =>
                      l10n.widgetV2StyleUnavailable,
                  },
                ),
              ],
              SizedBox(height: tokens.space4),
              KitButton.primary(
                key: const ValueKey('widget-style-save'),
                label: s.saving ? l10n.widgetV2Sending : l10n.widgetV2SaveStyle,
                working: s.saving,
                onPressed: s.saving ? null : s.save,
              ),
            ],
          );
        },
      ),
    );
  }
}
