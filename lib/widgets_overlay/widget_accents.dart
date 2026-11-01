import 'package:flutter/painting.dart';

import '../ui/theme_roles.dart';

/// The colour a widget accent choice draws in the preview. The presets match
/// the launcher widget's own table; "wallpaper" (the phone's own colours,
/// known only to the launcher) and "app" are drawn in the app's accent, so
/// the preview is an approximation for those two.
Color widgetAccentColor(String id, ThemeRoles roles) => switch (id) {
  'green' => const Color(0xFF48AC6F),
  'teal' => const Color(0xFF258783),
  'blue' => const Color(0xFF4187CD),
  'amber' => const Color(0xFFBA8420),
  'wallpaper' => Color.lerp(roles.accent, roles.text1, .4)!,
  _ => roles.accent,
};
