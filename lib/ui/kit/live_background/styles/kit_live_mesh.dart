import 'dart:math' as math;
import 'dart:ui';

import '../../../../l10n/app_localizations.dart';
import '../kit_live_style.dart';
import 'kit_live_toolkit.dart';

class KitLiveMesh extends KitLiveStyle {
  const KitLiveMesh();

  @override
  String get id => 'mesh';

  @override
  String label(AppLocalizations l10n) => l10n.liveStyleMesh;

  @override
  void paint(Canvas canvas, Size size, KitLiveFrame f) {
    final p = f.palette;
    final a = strengthOf(f);
    final run = f.running;
    final t = f.t;
    final tt = t * .12;
    final blue = rgb(p.blue), teal = rgb(p.teal), glow = rgb(p.glow);
    final third = mixRgb(teal, glow, .4 + run * .6);
    final pts = <(double, double, List<double>)>[
      (.2 + .15 * math.sin(tt * .7), .2 + .1 * math.cos(tt * .5), blue),
      (.85 + .1 * math.cos(tt * .6), .3 + .15 * math.sin(tt * .4), teal),
      (.3 + .2 * math.sin(tt * .3), .9 + .1 * math.cos(tt * .8), third),
      (
        .7 + .15 * math.sin(tt * .5 + 1),
        1.5 - .25 * run + .1 * math.cos(tt * .9),
        glow,
      ),
    ];
    final alpha = .13 * a * (.8 + .2 * math.sin(tt));
    paintField(canvas, size, f, 'f', 8, (u, v) {
      var w = 0.0, r = 0.0, g = 0.0, b = 0.0;
      for (final q in pts) {
        final dx = u - q.$1, dy = v - q.$2 * 1.9;
        final d = 1 / (dx * dx + dy * dy + .02);
        w += d;
        r += q.$3[0] * d;
        g += q.$3[1] * d;
        b += q.$3[2] * d;
      }
      return packArgb(r / w, g / w, b / w, alpha);
    }, every: .03);
  }
}
