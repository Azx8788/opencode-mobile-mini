import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../kit_illustration.dart';
import '../kit_motion.dart';

/// The brand's "open portal" (assets/branding/open-portal/mark.svg): two
/// open brackets forming an aperture. Entrance: each bracket draws itself,
/// then a spark lands in the middle. Ambient: the brackets breathe apart
/// and back while the spark circles inside — the app waiting on something
/// (connecting, starting a server).
///
/// The reference scene for design standard §10: other scenes use the same
/// stroke, staging and loop rules.
class KitPortalScene extends KitScene {
  const KitPortalScene();

  // mark.svg's geometry (viewBox 24..84) mapped into the 120-unit box.
  static const _scale = 1.5;
  static Offset _p(double x, double y) =>
      Offset((x - 24) * _scale + 15, (y - 24) * _scale + 15);
  static const _radius = Radius.circular(12 * _scale);

  static final Path _upper = Path()
    ..moveTo(_p(61, 31).dx, _p(61, 31).dy)
    ..lineTo(_p(43, 31).dx, _p(43, 31).dy)
    ..arcToPoint(_p(31, 43), radius: _radius, clockwise: false)
    ..lineTo(_p(31, 64).dx, _p(31, 64).dy);

  static final Path _lower = Path()
    ..moveTo(_p(77, 44).dx, _p(77, 44).dy)
    ..lineTo(_p(77, 65).dx, _p(77, 65).dy)
    ..arcToPoint(_p(65, 77), radius: _radius, clockwise: true)
    ..lineTo(_p(44, 77).dx, _p(44, 77).dy);

  static const _center = Offset(60, 60);

  @override
  void paint(Canvas canvas, KitSceneFrame frame) {
    final palette = frame.palette;
    final t = frame.entrance;
    final breath = frame.looping ? KitDraw.wave(frame.loop) : 0.0;

    // A soft halo that swells with each breath (only while waiting).
    if (frame.looping) {
      canvas.drawCircle(
        _center,
        44 + 8 * breath,
        KitDraw.pen(
          KitDraw.fade(palette.accent, .22 * (1 - breath)),
          KitDraw.hairline,
        ),
      );
    }

    final pen = KitDraw.pen(palette.accent, 9);
    final drift = 3.0 * breath;
    canvas.save();
    canvas.translate(-drift, -drift);
    KitDraw.partialPath(canvas, _upper, KitDraw.interval(t, 0, .55), pen);
    canvas.restore();
    canvas.save();
    canvas.translate(drift, drift);
    KitDraw.partialPath(canvas, _lower, KitDraw.interval(t, .2, .75), pen);
    canvas.restore();

    // The spark: lands with a small overshoot, then circles while waiting.
    final land = KitDraw.interval(t, .6, 1, KitMotion.land);
    if (land > 0) {
      final angle = frame.loop * 2 * math.pi - math.pi / 2;
      final orbit = frame.looping ? 7.0 : 0.0;
      final spark = _center + Offset(math.cos(angle), math.sin(angle)) * orbit;
      canvas.drawCircle(spark, 5.5 * land, KitDraw.fill(palette.accent));
    }
  }
}
