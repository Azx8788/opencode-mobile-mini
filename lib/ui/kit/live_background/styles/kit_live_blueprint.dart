import 'package:flutter/painting.dart';

import '../../../../l10n/app_localizations.dart';
import '../kit_live_style.dart';
import 'kit_live_support.dart';

/// A technical-drawing grid with measurement ticks drifting slowly, like the
/// back of an engineering sheet; a scan line sweeps down it while a reply
/// runs.
class KitLiveBlueprint extends KitLiveStyle {
  const KitLiveBlueprint();

  @override
  double get ceilingFactor => 2.0;

  @override
  String get id => 'blueprint';

  @override
  String label(AppLocalizations l10n) => l10n.liveStyleBlueprint;

  @override
  void paint(Canvas canvas, Size size, KitLiveFrame frame) {
    final p = frame.palette;
    final peak =
        livePeak(frame) * ceilingFactor * 0.64; // calibrated: text3 keeps 4.5:1
    if (peak <= 0) return;
    final m = size.width / 18, big = m * 5;
    final o = (frame.t * m * .15) % big;
    final col = liveMix(p.ink, p.blue, .6);
    final minor = Path(), major = Path();
    var k = 0;
    for (var x = -big + o; x < size.width + big; x += m, k++) {
      (k % 5 == 0 ? major : minor)
        ..moveTo(x, 0)
        ..lineTo(x, size.height);
    }
    k = 0;
    for (var y = -big + o; y < size.height + big; y += m, k++) {
      (k % 5 == 0 ? major : minor)
        ..moveTo(0, y)
        ..lineTo(size.width, y);
    }
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawPath(minor, line..color = col.withValues(alpha: peak * .3));
    canvas.drawPath(major, line..color = col.withValues(alpha: peak * .55));

    final fs = m * .5 < 7 ? 7.0 : m * .5;
    final labels = frame.memory.of<_Labels>('blueprint.labels', _Labels.new)
      ..ensure(fs, col.withValues(alpha: peak * .6));
    var i = 0;
    for (var x = o; x < size.width; x += big, i++) {
      labels.get('${i * 50}').paint(canvas, Offset(x + 2, m * .25));
    }

    final run = frame.running;
    if (run > .02) {
      final y = ((frame.t * .18) % 1) * size.height;
      final rect = Rect.fromLTRB(0, y - m * 2, size.width, y);
      canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              p.glow.withValues(alpha: 0),
              p.glow.withValues(alpha: peak * .7 * run),
            ],
          ).createShader(rect),
      );
    }
  }
}

class _Labels {
  double _fs = 0;
  Color? _c;
  final Map<String, TextPainter> _cache = {};

  void ensure(double fs, Color c) {
    if (fs == _fs && c == _c) return;
    for (final t in _cache.values) {
      t.dispose();
    }
    _cache.clear();
    _fs = fs;
    _c = c;
  }

  TextPainter get(String s) => _cache.putIfAbsent(
    s,
    () => TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(fontFamily: 'AppMono', fontSize: _fs, color: _c),
      ),
      textDirection: TextDirection.ltr,
    )..layout(),
  );
}
