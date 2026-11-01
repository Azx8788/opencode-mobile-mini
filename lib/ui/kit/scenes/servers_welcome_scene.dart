import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../kit_illustration.dart';
import 'servers_cast.dart';
import '../kit_motion.dart';

/// The Servers welcome's hero (no servers yet, design standard §10): the
/// computer where the agent runs, the portal on its screen, and this phone
/// in front with a dotted path between them — "your agent, in your pocket".
///
/// Entrance only (a resting screen never loops): the laptop draws itself,
/// the portal opens on it, the phone joins, the path dots across and a
/// spark lands in the portal.
class ServersWelcomeScene extends KitScene {
  const ServersWelcomeScene();

  @override
  Size get box => const Size(200, 120);

  static final _laptop = ServersLaptop(const Rect.fromLTRB(78, 14, 176, 78));
  static final _phone = ServersPhone(const Rect.fromLTRB(24, 52, 56, 108));
  static const _portal = Offset(127, 46);

  static final Path _path = Path()
    ..moveTo(40, 44)
    ..quadraticBezierTo(42, 8, 88, 9);
  static final ui.PathMetric _metric = _path.computeMetrics().first;
  static final List<Offset> _dots = [
    for (var d = 0.0; d <= _metric.length; d += 6.5)
      _metric.getTangentForOffset(d)!.position,
  ];

  @override
  void paint(Canvas canvas, KitSceneFrame frame) {
    final palette = frame.palette;
    final t = frame.entrance;

    _laptop.paint(canvas, palette, KitDraw.interval(t, 0, .5));
    ServersPortal.paint(
      canvas,
      _portal,
      36,
      palette.accent,
      KitDraw.interval(t, .25, .75),
      dot: KitDraw.interval(t, .75, 1, KitMotion.land),
    );
    _phone.paint(canvas, palette, KitDraw.interval(t, .3, .8));

    // The path from the phone to the computer, one dot at a time.
    final shown = (KitDraw.interval(t, .55, .9) * _dots.length).floor();
    final dot = KitDraw.fill(palette.accent);
    for (var i = 0; i < shown; i++) {
      canvas.drawCircle(_dots[i], 1.8, dot);
    }

    // Two small sparkles, the scene's only decoration.
    final sparkle = KitDraw.interval(t, .8, 1);
    if (sparkle > 0) {
      final pen = KitDraw.pen(
        KitDraw.fade(palette.accent, .55 * sparkle),
        KitDraw.hairline,
      );
      paintSparkle(canvas, const Offset(188, 26), 4.5 * sparkle, pen);
      paintSparkle(canvas, const Offset(14, 28), 3.5 * sparkle, pen);
    }
  }
}
