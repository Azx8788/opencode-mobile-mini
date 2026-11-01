import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../../../l10n/app_localizations.dart';
import '../kit_live_style.dart';
import 'kit_live_support.dart';

/// Out-of-focus lights drift slowly upward, like city lights through a
/// lens; green lights join and drift a little faster while a reply runs.
class KitLiveBokeh extends KitLiveStyle {
  const KitLiveBokeh();

  @override
  String get id => 'bokeh';

  @override
  String label(AppLocalizations l10n) => l10n.liveStyleBokeh;

  @override
  void paint(Canvas canvas, Size size, KitLiveFrame frame) {
    final p = frame.palette;
    final peak = livePeak(frame);
    if (peak <= 0) return;
    final run = frame.running;
    final clock = liveClock(frame, 'bokeh', 1 + run);
    final lights = liveCached(frame, 'bokeh.lights', size, () {
      final rnd = liveRandom('bokeh');
      return List.generate(
        20,
        (i) => (
          x: rnd.nextDouble(),
          y: rnd.nextDouble() * 1.4 - .2,
          r: .04 + rnd.nextDouble() * .1,
          v: .004 + rnd.nextDouble() * .01,
          c: i % 3,
          green: i >= 12,
        ),
      );
    });
    final paint = Paint();
    for (final b in lights) {
      final k = b.green ? run : 1.0;
      if (k < .02) continue;
      final y = ((b.y + .2 - b.v * clock) % 1.4 + 1.4) % 1.4 - .2;
      final x =
          b.x * size.width +
          math.sin(frame.t * .2 + b.r * 40) * size.width * .03;
      final centre = Offset(x, y * size.height);
      final radius = b.r * size.width;
      final col = b.green ? p.glow : [p.teal, p.blue, p.ink][b.c];
      final al = peak * .4 * k;
      canvas.drawCircle(
        centre,
        radius,
        paint
          ..shader = ui.Gradient.radial(
            centre,
            radius,
            [
              col.withValues(alpha: al),
              col.withValues(alpha: al * .8),
              col.withValues(alpha: 0),
            ],
            const [0, .75, 1],
          ),
      );
    }
  }
}
