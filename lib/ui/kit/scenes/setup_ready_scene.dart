import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../kit_illustration.dart';
import 'setup_cast.dart';
import '../kit_motion.dart';

/// Setup finished (design standard §10, a celebration): the phone lights,
/// the portal on its screen springs open around a check, rays burst out
/// and fade, and sparkles and confetti settle around it. It plays once and
/// then rests; with reduced motion it is simply there, finished.
class SetupReadyScene extends KitScene {
  const SetupReadyScene();

  @override
  Size get box => const Size(160, 120);

  static const _center = Offset(80, 60);
  static const _portal = Offset(80, 58);
  static final Path _frame = SetupCast.phone(
    const Rect.fromLTRB(54, 8, 106, 112),
    12,
  );
  static final RRect _screen = RRect.fromRectAndRadius(
    const Rect.fromLTRB(61, 17, 99, 101),
    const Radius.circular(5),
  );
  static final Path _check = SetupCast.check(_portal, 15);

  /// The burst: eight rays, evenly around the phone, a little off the axes.
  static final List<Offset> _rays = [
    for (var i = 0; i < 8; i++)
      Offset(math.cos(i * math.pi / 4 + .3), math.sin(i * math.pi / 4 + .3)),
  ];

  /// Confetti that stays: short dashes at rest, each (centre, angle, muted).
  static const _confetti = [
    (Offset(28, 30), .6, false),
    (Offset(136, 72), -.5, false),
    (Offset(124, 100), .9, true),
    (Offset(24, 76), -.8, true),
    (Offset(140, 20), .2, true),
  ];

  @override
  void paint(Canvas canvas, KitSceneFrame frame) {
    final p = frame.palette;
    final t = frame.entrance;

    final wash = KitDraw.interval(t, 0, .4);
    canvas.drawCircle(
      _center,
      50 * (.7 + .3 * wash),
      KitDraw.fill(KitDraw.fade(p.accentSoft, wash)),
    );

    final lit = KitDraw.interval(t, .1, .35);
    if (lit > 0) {
      canvas.drawRRect(_screen, KitDraw.fill(KitDraw.fade(p.surface, lit)));
      canvas.drawRRect(
        _screen,
        KitDraw.fill(KitDraw.fade(p.accentSoft, lit * 1.4)),
      );
    }
    KitDraw.partialPath(
      canvas,
      _frame,
      KitDraw.interval(t, 0, .35),
      KitDraw.pen(p.ink),
    );
    canvas.drawLine(
      const Offset(74, 106.5),
      Offset(74 + 12 * KitDraw.interval(t, .3, .4), 106.5),
      KitDraw.pen(KitDraw.fade(p.muted, .8 * lit), 2),
    );

    // The portal springs open: closed brackets overshoot to open.
    final draw = KitDraw.interval(t, .25, .5);
    final open = KitDraw.interval(t, .45, .8, KitMotion.land);
    SetupCast.portal(
      canvas,
      center: _portal,
      size: 34,
      color: p.accent,
      upper: draw,
      lower: draw,
      open: -3 + 5.5 * open,
      width: 4.5,
    );
    KitDraw.partialPath(
      canvas,
      _check,
      KitDraw.interval(t, .6, .85),
      KitDraw.pen(p.accent, 3.5),
    );

    // Rays shoot out and fade: the moment, not the rest.
    final burst = KitDraw.interval(t, .55, 1, KitMotion.enter);
    if (burst > 0 && burst < 1) {
      final pen = KitDraw.pen(
        KitDraw.fade(p.accent, 1 - burst),
        KitDraw.hairline,
      );
      for (final ray in _rays) {
        final inner = 34 + 26 * burst;
        final outer = inner + 8 * (1 - burst * .6);
        canvas.drawLine(
          _center + Offset(ray.dx * inner * 1.2, ray.dy * inner),
          _center + Offset(ray.dx * outer * 1.2, ray.dy * outer),
          pen,
        );
      }
    }

    // What stays: sparkles and confetti.
    final big = KitDraw.interval(t, .6, .9, KitMotion.land);
    final small = KitDraw.interval(t, .7, 1, KitMotion.land);
    SetupCast.sparkle(canvas, const Offset(126, 30), 10, p.accent, pop: big);
    SetupCast.sparkle(
      canvas,
      const Offset(34, 50),
      6,
      KitDraw.fade(p.accent, .8),
      pop: small,
    );
    SetupCast.sparkle(
      canvas,
      const Offset(118, 88),
      4.5,
      KitDraw.fade(p.accent, .6),
      pop: small,
    );
    for (final (index, (at, angle, muted)) in _confetti.indexed) {
      final pop = KitDraw.interval(
        t,
        .6 + index * .05,
        .85 + index * .03,
        KitMotion.land,
      );
      if (pop <= 0) continue;
      final d = Offset(math.cos(angle), math.sin(angle)) * 3.5 * pop;
      canvas.drawLine(
        at - d,
        at + d,
        KitDraw.pen(
          muted ? KitDraw.fade(p.muted, .6) : KitDraw.fade(p.accent, .9),
          KitDraw.hairline,
        ),
      );
    }
  }
}
