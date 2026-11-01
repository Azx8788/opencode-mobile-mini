import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../../../l10n/app_localizations.dart';
import '../kit_live_style.dart';
import 'kit_live_support.dart';

/// Thin columns of glyphs fall slowly, the classic digital rain; a short
/// trail of dimmer glyphs follows each head. Faster and brighter while a
/// reply runs.
class KitLiveMatrixRain extends KitLiveStyle {
  /// [glyphs] is the set the rain draws from. The default needs the system's
  /// CJK face for the katakana (Android has one); tests that must not depend
  /// on it pass [asciiGlyphs].
  const KitLiveMatrixRain({this.glyphs = defaultGlyphs});

  final String glyphs;

  @override
  double get ceilingFactor => 2.0;

  @override
  String get id => 'matrixRain';

  @override
  String label(AppLocalizations l10n) => l10n.liveStyleMatrixRain;

  /// Half-width katakana, digits and symbols (the classic rain).
  static const String defaultGlyphs =
      'ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ0123456789:.=*+<>';

  /// Only what the bundled mono face has; deterministic in tests.
  static const String asciiGlyphs = '0123456789:.=*+<>|/ZXYWMK';
  static const int _levels = 12;
  static const int _trail = 14;

  @override
  void paint(Canvas canvas, Size size, KitLiveFrame frame) {
    final p = frame.palette;
    final peak =
        livePeak(frame) * ceilingFactor * 0.55; // calibrated: text3 keeps 4.5:1
    if (peak <= 0) return;
    final fs = math.max(9.0, size.width / 22);
    final cache = frame.memory.of<_Glyphs>('matrix.glyphs', _Glyphs.new)
      ..ensure(fs, p.glow, liveMix(p.glow, p.ink, .35), peak, glyphs);
    final clock = liveClock(frame, 'matrix', 1 + frame.running * 3);
    final rows = size.height / fs;
    final cols = (size.width / fs).ceil();
    final headLevel = .85 + .15 * frame.running;
    final tick = (clock * 6).floor();
    for (var i = 0; i < cols; i++) {
      final speed = 2.6 * (.6 + ((i * 7) % 5) / 8);
      final cycle = rows + _trail + 2 + 6 * liveHash(i, 2);
      final head = ((clock * speed + liveHash(i, 3) * cycle) % cycle - _trail)
          .floor();
      for (var k = 0; k < _trail; k++) {
        final row = head - k;
        if (row < 0 || row > rows) continue;
        final fade = k == 0 ? 1.0 : math.pow(1 - k / (_trail + 1), 1.5) * .5;
        final level = (headLevel * fade * _levels).round();
        if (level < 1) continue;
        final g =
            (liveHash(i, row, k == 0 ? tick : (clock * .8).floor()) *
                    glyphs.length)
                .floor() %
            glyphs.length;
        cache.get(g, level, k == 0).paint(canvas, Offset(i * fs, row * fs));
      }
    }
  }
}

class _Glyphs {
  double _fs = 0;
  Color? _colour;
  Color? _head;
  double _peak = 0;
  String _set = '';
  final Map<int, TextPainter> _cache = {};

  void ensure(double fs, Color colour, Color head, double peak, String set) {
    if (fs == _fs && colour == _colour && peak == _peak && set == _set) return;
    for (final t in _cache.values) {
      t.dispose();
    }
    _cache.clear();
    _fs = fs;
    _colour = colour;
    _head = head;
    _peak = peak;
    _set = set;
  }

  TextPainter get(int glyph, int level, bool head) => _cache.putIfAbsent(
    glyph * 64 + level + (head ? 1 << 20 : 0),
    () => TextPainter(
      text: TextSpan(
        text: _set[glyph],
        style: TextStyle(
          fontFamily: 'AppMono',
          fontFamilyFallback: const [
            'sans-serif',
            'Noto Sans CJK JP',
            'Noto Sans JP',
          ],
          fontSize: _fs,
          height: 1,
          color: (head ? _head! : _colour!).withValues(
            alpha: _peak * level / KitLiveMatrixRain._levels,
          ),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(),
  );
}
