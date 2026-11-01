import 'dart:math' as math;
import 'dart:ui';

import '../../../../l10n/app_localizations.dart';
import '../kit_live_style.dart';
import 'kit_live_toolkit.dart';

class KitLiveLiquidBlobs extends KitLiveStyle {
  const KitLiveLiquidBlobs();

  @override
  String get id => 'liquidBlobs';

  @override
  String label(AppLocalizations l10n) => l10n.liveStyleLiquidBlobs;

  @override
  void paint(Canvas canvas, Size size, KitLiveFrame f) {
    final p = f.palette;
    final a = strengthOf(f);
    final run = f.running;
    final t = f.t;
    final tt = t * .15;
    final blue = rgb(p.blue), teal = rgb(p.teal), glow = rgb(p.glow);
    final blobs = <(double, double, double, List<double>)>[
      (.3 + .2 * math.sin(tt * .8), .4 + .25 * math.cos(tt * .6), .05, blue),
      (.7 + .2 * math.cos(tt * .7), .8 + .3 * math.sin(tt * .5), .06, teal),
      (
        .5 + .25 * math.sin(tt * .4 + 2),
        1.3 + .2 * math.cos(tt * .9),
        .05,
        teal,
      ),
      (.5, 2.0 - run * .45, .06 * run, glow),
    ];
    paintField(canvas, size, f, 'f', 6, (u, v) {
      var s = 0.0, r = 0.0, g = 0.0, b = 0.0;
      for (final q in blobs) {
        if (q.$3 <= 0) continue;
        final d = (u - q.$1) * (u - q.$1) + (v - q.$2) * (v - q.$2) + .0001;
        final k = q.$3 / d;
        s += k;
        r += q.$4[0] * k;
        g += q.$4[1] * k;
        b += q.$4[2] * k;
      }
      return packArgb(r / s, g / s, b / s, smooth(.7, 1.4, s) * .15 * a);
    }, every: .03);
  }
}
