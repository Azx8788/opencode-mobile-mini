import 'package:flutter/material.dart';

import 'theme_packs.dart';

/// Themes described by their source colours.
///
/// The four curated packs spell out every role by hand. These do not: a
/// theme here is a background, a text colour and two accents per brightness
/// (the colours a palette's own documentation gives), and [_build] derives
/// every Material role from them the same way each time: containers as
/// steps from the background toward the text, tonal containers as the accent
/// laid over the background, "on" colours by luminance. One recipe keeps
/// twenty-six themes consistent and lets a test hold all of them to the same
/// contrast floor.
class _Tones {
  const _Tones(
    this.background,
    this.text,
    this.primary,
    this.secondary, {
    this.success,
  });

  final Color background;
  final Color text;
  final Color primary;
  final Color secondary;
  final Color? success;
}

class _Spec {
  const _Spec(this.label, this.dark, this.light);

  final String label;
  final _Tones dark;
  final _Tones light;
}

const _specs = <ThemePackId, _Spec>{
  ThemePackId.dracula: _Spec(
    'Dracula',
    _Tones(
      Color(0xFF282A36),
      Color(0xFFF8F8F2),
      Color(0xFFBD93F9),
      Color(0xFFFF79C6),
      success: Color(0xFF50FA7B),
    ),
    _Tones(
      Color(0xFFF8F8F2),
      Color(0xFF282A36),
      Color(0xFF7C4DDB),
      Color(0xFFC2185B),
      success: null,
    ),
  ),
  ThemePackId.nord: _Spec(
    'Nord',
    _Tones(
      Color(0xFF2E3440),
      Color(0xFFECEFF4),
      Color(0xFF88C0D0),
      Color(0xFF81A1C1),
      success: Color(0xFFA3BE8C),
    ),
    _Tones(
      Color(0xFFECEFF4),
      Color(0xFF2E3440),
      Color(0xFF3B6EA8),
      Color(0xFF4C7A8A),
      success: null,
    ),
  ),
  ThemePackId.tokyoNight: _Spec(
    'Tokyo Night',
    _Tones(
      Color(0xFF1A1B26),
      Color(0xFFC0CAF5),
      Color(0xFF7AA2F7),
      Color(0xFFBB9AF7),
      success: Color(0xFF9ECE6A),
    ),
    _Tones(
      Color(0xFFE1E2E7),
      Color(0xFF343B58),
      Color(0xFF2E7DE9),
      Color(0xFF9854F1),
      success: null,
    ),
  ),
  ThemePackId.oneDark: _Spec(
    'One Dark',
    _Tones(
      Color(0xFF282C34),
      Color(0xFFD7DAE0),
      Color(0xFF61AFEF),
      Color(0xFFC678DD),
      success: Color(0xFF98C379),
    ),
    _Tones(
      Color(0xFFFAFAFA),
      Color(0xFF383A42),
      Color(0xFF4078F2),
      Color(0xFFA626A4),
      success: null,
    ),
  ),
  ThemePackId.monokai: _Spec(
    'Monokai',
    _Tones(
      Color(0xFF272822),
      Color(0xFFF8F8F2),
      Color(0xFFFD971F),
      Color(0xFF66D9EF),
      success: Color(0xFFA6E22E),
    ),
    _Tones(
      Color(0xFFFAF8F2),
      Color(0xFF272822),
      Color(0xFFC2570C),
      Color(0xFF0E7490),
      success: null,
    ),
  ),
  ThemePackId.rosePine: _Spec(
    'Rosé Pine',
    _Tones(
      Color(0xFF191724),
      Color(0xFFE0DEF4),
      Color(0xFFC4A7E7),
      Color(0xFFEBBCBA),
      success: Color(0xFF9CCFD8),
    ),
    _Tones(
      Color(0xFFFAF4ED),
      Color(0xFF575279),
      Color(0xFF907AA9),
      Color(0xFFD7827E),
      success: Color(0xFF56949F),
    ),
  ),
  ThemePackId.everforest: _Spec(
    'Everforest',
    _Tones(
      Color(0xFF2D353B),
      Color(0xFFD3C6AA),
      Color(0xFFA7C080),
      Color(0xFF7FBBB3),
      success: Color(0xFFA7C080),
    ),
    _Tones(
      Color(0xFFFDF6E3),
      Color(0xFF5C6A72),
      Color(0xFF5F8A1E),
      Color(0xFF3A94C5),
      success: null,
    ),
  ),
  ThemePackId.kanagawa: _Spec(
    'Kanagawa',
    _Tones(
      Color(0xFF1F1F28),
      Color(0xFFDCD7BA),
      Color(0xFF7E9CD8),
      Color(0xFF957FB8),
      success: Color(0xFF98BB6C),
    ),
    _Tones(
      Color(0xFFF2ECBC),
      Color(0xFF545464),
      Color(0xFF4D699B),
      Color(0xFF624C83),
      success: null,
    ),
  ),
  ThemePackId.ayu: _Spec(
    'Ayu',
    _Tones(
      Color(0xFF0B0E14),
      Color(0xFFBFBDB6),
      Color(0xFFE6B450),
      Color(0xFF39BAE6),
      success: Color(0xFFAAD94C),
    ),
    _Tones(
      Color(0xFFFCFCFC),
      Color(0xFF5C6166),
      Color(0xFFC77700),
      Color(0xFF2B7BB9),
      success: null,
    ),
  ),
  ThemePackId.nightOwl: _Spec(
    'Night Owl',
    _Tones(
      Color(0xFF011627),
      Color(0xFFD6DEEB),
      Color(0xFF82AAFF),
      Color(0xFFC792EA),
      success: Color(0xFFADDB67),
    ),
    _Tones(
      Color(0xFFFBFBFB),
      Color(0xFF403F53),
      Color(0xFF1F6FB5),
      Color(0xFF994CC3),
      success: null,
    ),
  ),
  ThemePackId.github: _Spec(
    'GitHub',
    _Tones(
      Color(0xFF0D1117),
      Color(0xFFE6EDF3),
      Color(0xFF4493F8),
      Color(0xFFA371F7),
      success: Color(0xFF3FB950),
    ),
    _Tones(
      Color(0xFFFFFFFF),
      Color(0xFF1F2328),
      Color(0xFF0969DA),
      Color(0xFF8250DF),
      success: Color(0xFF1A7F37),
    ),
  ),
  ThemePackId.palenight: _Spec(
    'Palenight',
    _Tones(
      Color(0xFF292D3E),
      Color(0xFFD0D6F0),
      Color(0xFFC792EA),
      Color(0xFF89DDFF),
      success: null,
    ),
    _Tones(
      Color(0xFFF4F3FA),
      Color(0xFF3B3F58),
      Color(0xFF7C4DFF),
      Color(0xFF0086B3),
      success: null,
    ),
  ),
  ThemePackId.synthwave: _Spec(
    'Synthwave',
    _Tones(
      Color(0xFF241B2F),
      Color(0xFFF4EEFF),
      Color(0xFFFF7EDB),
      Color(0xFF36F9F6),
      success: Color(0xFF72F1B8),
    ),
    _Tones(
      Color(0xFFFBF5FF),
      Color(0xFF2A1B3D),
      Color(0xFFC2189B),
      Color(0xFF0E8A8A),
      success: null,
    ),
  ),
  ThemePackId.cobalt: _Spec(
    'Cobalt',
    _Tones(
      Color(0xFF193549),
      Color(0xFFE1EFFF),
      Color(0xFFFFC600),
      Color(0xFF9EFFFF),
      success: Color(0xFF3AD900),
    ),
    _Tones(
      Color(0xFFF2F8FF),
      Color(0xFF14324A),
      Color(0xFF0B63C5),
      Color(0xFFB07D00),
      success: null,
    ),
  ),
  ThemePackId.midnight: _Spec(
    'Midnight',
    _Tones(
      Color(0xFF000000),
      Color(0xFFEDEDED),
      Color(0xFF8AB4F8),
      Color(0xFFC58AF9),
      success: null,
    ),
    _Tones(
      Color(0xFFFFFFFF),
      Color(0xFF111111),
      Color(0xFF1A56DB),
      Color(0xFF7C3AED),
      success: null,
    ),
  ),
  ThemePackId.paper: _Spec(
    'Paper',
    _Tones(
      Color(0xFF121212),
      Color(0xFFE8E6E3),
      Color(0xFFD6C7A1),
      Color(0xFFA8A29E),
      success: null,
    ),
    _Tones(
      Color(0xFFFBF9F4),
      Color(0xFF1C1917),
      Color(0xFF44403C),
      Color(0xFF78716C),
      success: null,
    ),
  ),
  ThemePackId.forest: _Spec(
    'Forest',
    _Tones(
      Color(0xFF0F1A14),
      Color(0xFFDCE8DD),
      Color(0xFF6FCF97),
      Color(0xFF8FB9A8),
      success: null,
    ),
    _Tones(
      Color(0xFFF3F8F3),
      Color(0xFF17301F),
      Color(0xFF1F7A45),
      Color(0xFF4B7F68),
      success: null,
    ),
  ),
  ThemePackId.ocean: _Spec(
    'Ocean',
    _Tones(
      Color(0xFF0A1929),
      Color(0xFFD7E6F5),
      Color(0xFF4FC3F7),
      Color(0xFF80CBC4),
      success: null,
    ),
    _Tones(
      Color(0xFFF1F8FD),
      Color(0xFF0F2A43),
      Color(0xFF0277BD),
      Color(0xFF00796B),
      success: null,
    ),
  ),
  ThemePackId.sunset: _Spec(
    'Sunset',
    _Tones(
      Color(0xFF1F1410),
      Color(0xFFF6E3D7),
      Color(0xFFFF8A5B),
      Color(0xFFFFC078),
      success: null,
    ),
    _Tones(
      Color(0xFFFFF7F1),
      Color(0xFF3A1F14),
      Color(0xFFC2410C),
      Color(0xFFB45309),
      success: null,
    ),
  ),
  ThemePackId.sakura: _Spec(
    'Sakura',
    _Tones(
      Color(0xFF22161C),
      Color(0xFFF8E1EA),
      Color(0xFFF48FB1),
      Color(0xFFCE93D8),
      success: null,
    ),
    _Tones(
      Color(0xFFFFF5F8),
      Color(0xFF3D1F2B),
      Color(0xFFC2185B),
      Color(0xFF8E24AA),
      success: null,
    ),
  ),
  ThemePackId.lavender: _Spec(
    'Lavender',
    _Tones(
      Color(0xFF1A1726),
      Color(0xFFE6E1F7),
      Color(0xFFB39DDB),
      Color(0xFF9FA8DA),
      success: null,
    ),
    _Tones(
      Color(0xFFF8F6FE),
      Color(0xFF2A2340),
      Color(0xFF6A4BC4),
      Color(0xFF4F5BB5),
      success: null,
    ),
  ),
  ThemePackId.mint: _Spec(
    'Mint',
    _Tones(
      Color(0xFF10201D),
      Color(0xFFDBF1EC),
      Color(0xFF5EEAD4),
      Color(0xFF7DD3FC),
      success: null,
    ),
    _Tones(
      Color(0xFFF1FBF9),
      Color(0xFF12332D),
      Color(0xFF0F766E),
      Color(0xFF0369A1),
      success: null,
    ),
  ),
  ThemePackId.coffee: _Spec(
    'Coffee',
    _Tones(
      Color(0xFF1C1612),
      Color(0xFFEBDDCF),
      Color(0xFFD4A373),
      Color(0xFFC9ADA7),
      success: null,
    ),
    _Tones(
      Color(0xFFFAF5EF),
      Color(0xFF33261C),
      Color(0xFF8B5E34),
      Color(0xFF7A5C58),
      success: null,
    ),
  ),
  ThemePackId.slate: _Spec(
    'Slate',
    _Tones(
      Color(0xFF0F172A),
      Color(0xFFE2E8F0),
      Color(0xFF38BDF8),
      Color(0xFFA5B4FC),
      success: null,
    ),
    _Tones(
      Color(0xFFF8FAFC),
      Color(0xFF0F172A),
      Color(0xFF2563EB),
      Color(0xFF4F46E5),
      success: null,
    ),
  ),
  ThemePackId.amber: _Spec(
    'Amber',
    _Tones(
      Color(0xFF1A1608),
      Color(0xFFF3EBD3),
      Color(0xFFFFCA28),
      Color(0xFFFFAB40),
      success: null,
    ),
    _Tones(
      Color(0xFFFFFBF0),
      Color(0xFF33290A),
      Color(0xFF9A6700),
      Color(0xFFB45309),
      success: null,
    ),
  ),
  ThemePackId.highContrast: _Spec(
    'High contrast',
    _Tones(
      Color(0xFF000000),
      Color(0xFFFFFFFF),
      Color(0xFFFFEB3B),
      Color(0xFF80D8FF),
      success: Color(0xFF69F0AE),
    ),
    _Tones(
      Color(0xFFFFFFFF),
      Color(0xFF000000),
      Color(0xFF0037A6),
      Color(0xFF6A00A8),
      success: Color(0xFF00600F),
    ),
  ),
};

/// Labels for [themePackLabels].
final generatedThemePackLabels = {
  for (final entry in _specs.entries) entry.key: entry.value.label,
};

final _built = <ThemePackId, ThemePack>{};

/// The generated pack for [id], or null when [id] is a curated or dynamic one.
ThemePack? generatedThemePack(ThemePackId id) {
  final spec = _specs[id];
  if (spec == null) return null;
  return _built.putIfAbsent(
    id,
    () => ThemePack(
      id: id,
      label: spec.label,
      tagline: '',
      dark: _build(spec.dark, Brightness.dark),
      light: _build(spec.light, Brightness.light),
    ),
  );
}

Color _mix(Color from, Color to, double amount) =>
    Color.lerp(from, to, amount)!;

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + .05) / (lo + .05);
}

const _ink = Color(0xFF111214);

/// Text that reads on [fill]: near-black or white, whichever measures better.
Color _on(Color fill) => _contrast(_ink, fill) >= _contrast(Colors.white, fill)
    ? _ink
    : Colors.white;

/// [color], moved toward [toward] only as far as it takes to reach [min]
/// contrast against every one of [grounds]. A palette's own colour is kept
/// whenever it already reads.
Color _readable(Color color, List<Color> grounds, double min, Color toward) {
  var result = color;
  for (var t = 0.0; t <= 1.0; t += .04) {
    result = _mix(color, toward, t);
    if (grounds.every((ground) => _contrast(result, ground) >= min)) break;
  }
  return result;
}

ThemePalette _build(_Tones t, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final bg = t.background;
  // Toward this, a colour gains contrast with the page.
  final far = dark ? Colors.white : Colors.black;
  double step(double darkStep, double lightStep) => dark ? darkStep : lightStep;

  final surface = dark ? _mix(bg, t.text, .04) : _mix(bg, Colors.white, .6);
  var low = _mix(bg, t.text, step(.06, .04));
  final mid = _mix(bg, t.text, step(.09, .07));
  final high = _mix(bg, t.text, step(.13, .10));
  final highest = _mix(bg, t.text, step(.18, .14));
  // Everything text is laid on.
  final grounds = [bg, surface, low, mid, high];

  final fg = _readable(t.text, grounds, 7, far);
  final muted = _readable(_mix(fg, bg, step(.26, .22)), grounds, 4.5, far);
  // Recognised by colour, not read: the 3:1 of non-text contrast.
  final primary = _readable(t.primary, [bg, surface], 3, far);
  // The frosted navigation bar is this surface at 78% over whatever scrolls
  // under it, with the selected tab's accent wash on top. Over the worst
  // backdrop (white under a dark theme, black under a light one) its labels
  // must still read, so a mid-tone background gets a deeper bar.
  final worst = dark ? Colors.white : Colors.black;
  final away = dark ? Colors.black : Colors.white;
  for (var i = 0; i < 25; i++) {
    final bar = Color.alphaBlend(
      low.withValues(alpha: dark ? .78 : .72),
      worst,
    );
    final selected = Color.alphaBlend(primary.withValues(alpha: .17), bar);
    if (_contrast(fg, bar) >= 4.6 && _contrast(fg, selected) >= 4.6) break;
    low = _mix(low, away, .06);
  }
  final secondary = _readable(t.secondary, [bg, surface], 3, far);
  // No red: Material's error roles are the neutral text.
  final error = fg;
  final success = _readable(
    t.success ?? (dark ? const Color(0xFF86D8A5) : const Color(0xFF1E7A44)),
    [bg, surface],
    3,
    far,
  );
  Color container(Color accent, double d, double l) =>
      _mix(bg, accent, step(d, l));
  Color onContainer(Color accent, Color fill) =>
      _readable(_mix(accent, fg, step(.60, .70)), [fill], 4.5, far);
  final primaryContainer = container(primary, .30, .22);
  final secondaryContainer = container(secondary, .26, .18);
  final errorContainer = high;

  final scheme =
      ColorScheme.fromSeed(
        seedColor: t.primary,
        brightness: brightness,
      ).copyWith(
        primary: primary,
        onPrimary: _on(primary),
        primaryContainer: primaryContainer,
        onPrimaryContainer: onContainer(primary, primaryContainer),
        secondary: secondary,
        onSecondary: _on(secondary),
        secondaryContainer: secondaryContainer,
        onSecondaryContainer: onContainer(secondary, secondaryContainer),
        surface: surface,
        onSurface: fg,
        onSurfaceVariant: muted,
        outline: _mix(fg, bg, .52),
        outlineVariant: _mix(fg, bg, .78),
        error: error,
        onError: _on(error),
        errorContainer: errorContainer,
        onErrorContainer: onContainer(error, errorContainer),
        surfaceContainerLowest: dark
            ? _mix(bg, Colors.black, .30)
            : Colors.white,
        surfaceContainerLow: low,
        surfaceContainer: mid,
        surfaceContainerHigh: high,
        surfaceContainerHighest: highest,
      );
  return ThemePalette(
    scheme: scheme,
    background: bg,
    navigation: _mix(bg, fg, step(.03, .025)),
    success: success,
  );
}
