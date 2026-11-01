import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../kit_illustration.dart';
import '../kit_motion.dart';

/// The small drawn mark beside Stop while a reply is being written: the
/// brand's two brackets, small, with a spark inside. Entrance: the brackets
/// draw in and the spark lands. While the reply streams (ambient) the
/// brackets breathe a unit apart and back and the spark travels slowly
/// around the aperture — calm, one breath per loop. Under reduced motion it
/// is the still mark.
///
/// Drawn in a 48-unit box so the brand's stroke stays readable at 24 dp.
class StatesWorkingScene extends KitScene {
  const StatesWorkingScene();

  @override
  Size get box => const Size(48, 48);

  // The mark's geometry (mark.svg, viewBox 24..84) mapped into 4..44.
  static const _s = 40 / 60;
  static Offset _p(double x, double y) =>
      Offset((x - 24) * _s + 4, (y - 24) * _s + 4);
  static const _radius = Radius.circular(12 * _s);

  static final Path _upper = Path()
    ..moveTo(_p(61, 31).dx, _p(61, 31).dy)
    ..lineTo(_p(43, 31).dx, _p(43, 31).dy)
    ..arcToPoint(_p(31, 43), radius: _radius, clockwise: false)
    ..lineTo(_p(31, 64).dx, _p(31, 64).dy);

  static final Path _lower = Path()
    ..moveTo(_p(77, 44).dx, _p(77, 44).dy)
    ..lineTo(_p(77, 65).dx, _p(77, 65).dy)
    ..arcToPoint(_p(65, 77), radius: _radius)
    ..lineTo(_p(44, 77).dx, _p(44, 77).dy);

  static const _center = Offset(24, 24);

  @override
  void paint(Canvas canvas, KitSceneFrame frame) {
    final palette = frame.palette;
    final t = frame.entrance;
    final breath = frame.looping ? KitDraw.wave(frame.loop) : 0.0;
    final pen = KitDraw.pen(palette.accent, 5.5);
    final drift = 1.4 * breath;

    canvas.save();
    canvas.translate(-drift, -drift);
    KitDraw.partialPath(canvas, _upper, KitDraw.interval(t, 0, .55), pen);
    canvas.restore();
    canvas.save();
    canvas.translate(drift, drift);
    KitDraw.partialPath(canvas, _lower, KitDraw.interval(t, .2, .75), pen);
    canvas.restore();

    final land = KitDraw.interval(t, .6, 1, KitMotion.land);
    if (land <= 0) return;
    // The spark travels a small circle inside the aperture while working,
    // with a faint trail behind it; at rest it sits in the middle.
    if (frame.looping) {
      final angle = frame.loop * 2 * math.pi - math.pi / 2;
      const orbit = 5.0;
      canvas.drawArc(
        Rect.fromCircle(center: _center, radius: orbit),
        angle - math.pi * .6,
        math.pi * .6,
        false,
        KitDraw.pen(KitDraw.fade(palette.accent, .35), 2.2),
      );
      final spark = _center + Offset(math.cos(angle), math.sin(angle)) * orbit;
      canvas.drawCircle(spark, 3.6, KitDraw.fill(palette.accent));
    } else {
      canvas.drawCircle(_center, 3.8 * land, KitDraw.fill(palette.accent));
    }
  }
}
