import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../../../l10n/app_localizations.dart';
import '../kit_live_style.dart';
import 'kit_live_support.dart';

/// Wide ribbons of satin light fold and unfold slowly across the screen;
/// they ripple and pick up the green glow while a reply runs.
class KitLiveSilk extends KitLiveStyle {
  const KitLiveSilk();

  @override
  String get id => 'silk';

  @override
  String label(AppLocalizations l10n) => l10n.liveStyleSilk;

  @override
  void paint(Canvas canvas, Size size, KitLiveFrame frame) {
    final p = frame.palette;
    final peak = livePeak(frame);
    if (peak <= 0) return;
    final run = frame.running;
    final clock = liveClock(frame, 'silk', 1 + run * .7);
    final step = size.width / 48;
    for (var k = 0; k < 5; k++) {
      final base = size.height * (.15 + k * .18);
      final amp = size.height * .06 * (1 + run * .5);
      final ph = clock * (.18 + k * .03) + k;
      final col = liveMix(k.isOdd ? p.teal : p.blue, p.glow, run * (k / 4));
      final path = Path();
      double top(double x) =>
          base +
          math.sin(x / size.width * 3 + ph) * amp +
          math.sin(x / size.width * 7 - ph * .6) * amp * .3 -
          amp;
      double bottom(double x) =>
          base +
          math.sin(x / size.width * 3 + ph + .8) * amp +
          math.sin(x / size.width * 7 - ph * .6) * amp * .3 +
          amp;
      path.moveTo(0, top(0));
      for (var x = step; x <= size.width + step / 2; x += step) {
        path.lineTo(x, top(x));
      }
      for (var x = size.width; x >= -step / 2; x -= step) {
        path.lineTo(x, bottom(x));
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(0, base - amp * 2),
            Offset(0, base + amp * 2),
            [
              col.withValues(alpha: 0),
              col.withValues(alpha: peak * .95),
              col.withValues(alpha: 0),
            ],
            const [0, .5, 1],
          ),
      );
    }
  }
}
