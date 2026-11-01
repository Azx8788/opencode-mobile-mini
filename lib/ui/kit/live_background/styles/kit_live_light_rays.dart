import 'dart:math' as math;
import 'dart:ui';

import '../../../../l10n/app_localizations.dart';
import '../kit_live_style.dart';
import 'kit_live_toolkit.dart';

class KitLiveLightRays extends KitLiveStyle {
  const KitLiveLightRays();

  @override
  String get id => 'lightRays';

  @override
  String label(AppLocalizations l10n) => l10n.liveStyleLightRays;

  @override
  void paint(Canvas canvas, Size size, KitLiveFrame f) {
    final p = f.palette;
    // Calibrated so text keeps its contrast at the strongest moment
    // (test/kit/kit_live_background_test.dart).
    final a = strengthOf(f) * .7;
    final run = f.running;
    final t = f.t;
    final w = size.width, h = size.height;
    final col = mixColor(p.blue, p.glow, .3 + run * .6);
    final len = h * 1.6;
    for (var i = 0; i < 5; i++) {
      final ang = .35 + i * .16 + .05 * math.sin(t * .25 + i * 1.7);
      final wid = .05 + .03 * math.sin(t * .3 + i);
      final al = (p.dark ? .09 : .06) * (1 + run * .6) * a;
      final end = Offset(math.cos(ang) * len, math.sin(ang) * len);
      final path = Path()
        ..moveTo(-w * .1, -h * .05)
        ..lineTo(math.cos(ang - wid) * len, math.sin(ang - wid) * len)
        ..lineTo(math.cos(ang + wid) * len, math.sin(ang + wid) * len)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..shader = Gradient.linear(Offset.zero, end, [
            withA(col, al),
            withA(col, 0),
          ]),
      );
    }
  }
}
