import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../../../l10n/app_localizations.dart';
import '../kit_live_style.dart';
import 'kit_live_support.dart';

/// Range rings and a slow sweeping beam; small contacts light up as it
/// passes and fade. The sweep turns faster, with more contacts, while a
/// reply runs.
class KitLiveRadar extends KitLiveStyle {
  const KitLiveRadar();

  @override
  double get ceilingFactor => 2.0;

  @override
  String get id => 'radar';

  @override
  String label(AppLocalizations l10n) => l10n.liveStyleRadar;

  @override
  void paint(Canvas canvas, Size size, KitLiveFrame frame) {
    final p = frame.palette;
    final peak =
        livePeak(frame) * ceilingFactor * 0.72; // calibrated: text3 keeps 4.5:1
    if (peak <= 0) return;
    final c = Offset(size.width / 2, size.height * .62);
    final r = size.width * .95;
    final rings = liveCached(frame, 'radar.rings', size, () {
      final path = Path();
      for (var q = 1; q <= 4; q++) {
        path.addOval(Rect.fromCircle(center: c, radius: r * q / 4));
      }
      return path;
    });
    canvas.drawPath(
      rings,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = p.ink.withValues(alpha: peak * .3),
    );
    const tau = math.pi * 2;
    final run = frame.running;
    final a = liveClock(frame, 'radar', 1 + run * 2) * .35 % tau;
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = SweepGradient(
          colors: [
            p.glow.withValues(alpha: 0),
            p.glow.withValues(alpha: peak * .5),
            p.glow.withValues(alpha: 0),
            p.glow.withValues(alpha: 0),
          ],
          stops: const [0, .14, .143, 1],
          transform: GradientRotation(a - .9),
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
    final blips = liveCached(frame, 'radar.blips', size, () {
      final rnd = liveRandom('radar');
      return List.generate(
        14,
        (_) => (rnd.nextDouble() * tau, rnd.nextDouble() * r * .9 + r * .08),
      );
    });
    final dot = Paint(), halo = Paint();
    for (var i = 0; i < blips.length; i++) {
      final k = i < 6 ? 1.0 : run;
      if (k < .02) continue;
      var d = (a - blips[i].$1) % tau;
      if (d < 0) d += tau;
      final v = math.max(0.0, 1 - d / 2.6) * k;
      if (v < .02) continue;
      final at = c + Offset.fromDirection(blips[i].$1, blips[i].$2);
      canvas.drawCircle(
        at,
        6,
        halo..color = p.glow.withValues(alpha: peak * .15 * v),
      );
      canvas.drawCircle(
        at,
        2,
        dot..color = p.glow.withValues(alpha: peak * .55 * v),
      );
    }
  }
}
