import 'dart:ui';

import '../../../../l10n/app_localizations.dart';
import '../kit_live_style.dart';
import 'kit_live_toolkit.dart';

class KitLiveTopo extends KitLiveStyle {
  const KitLiveTopo();

  @override
  String get id => 'topo';

  @override
  String label(AppLocalizations l10n) => l10n.liveStyleTopo;

  @override
  void paint(Canvas canvas, Size size, KitLiveFrame f) {
    final p = f.palette;
    // Calibrated so text keeps its contrast at the strongest moment
    // (test/kit/kit_live_background_test.dart).
    final a = strengthOf(f) * .54;
    final run = f.running;
    final t = f.t;
    final tt = t * .02;
    final ink = rgb(p.ink), glow = rgb(p.glow);
    paintField(canvas, size, f, 'f', 3, (u, v) {
      final n = fbm(u * 1.4 + tt, v * 1.4 + tt * .6);
      final k = 8 + run * 4;
      final x = n * k;
      final b = (x - x.roundToDouble()).abs();
      final line = 1 - smooth(.03, .09, b);
      final g = run * smooth(1.3, 1.9, v);
      final c = mixRgb(ink, glow, g);
      return packArgb(c[0], c[1], c[2], line * (.09 + g * .2) * a);
    }, every: .06);
  }
}
