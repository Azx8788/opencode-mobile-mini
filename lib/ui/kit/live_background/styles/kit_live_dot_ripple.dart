import 'dart:math' as math;
import 'dart:ui';

import '../../../../l10n/app_localizations.dart';
import '../kit_live_style.dart';
import 'kit_live_toolkit.dart';

class KitLiveDotRipple extends KitLiveStyle {
  const KitLiveDotRipple();

  @override
  String get id => 'dotRipple';

  @override
  String label(AppLocalizations l10n) => l10n.liveStyleDotRipple;

  @override
  void paint(Canvas canvas, Size size, KitLiveFrame f) {
    final p = f.palette;
    // Calibrated so text keeps its contrast at the strongest moment
    // (test/kit/kit_live_background_test.dart).
    final a = strengthOf(f) * .28;
    final run = f.running;
    final t = f.t;
    final w = size.width, h = size.height;
    final sp = math.max(12.0, w / 18), ox = w / 2, oy = h * .93;
    final period = run > .5 ? 2.2 : 7.0;
    final ph = (t % period) / period;
    final radius = ph * h * 1.15;
    final paint = Paint();
    for (var y = sp / 2; y < h; y += sp) {
      for (var x = sp / 2; x < w; x += sp) {
        final d = math.sqrt((x - ox) * (x - ox) + (y - oy) * (y - oy));
        final ring =
            math.exp(-math.pow(d - radius, 2) / (2 * math.pow(sp * 1.6, 2))) *
            (1 - ph);
        final al = (.10 + ring * .55 * (run > .5 ? 1 : .6)) * a;
        paint.color = withA(mixColor(p.ink, p.glow, ring * 1.5), al);
        canvas.drawCircle(Offset(x, y), 1 + ring * 1.3, paint);
      }
    }
  }
}
