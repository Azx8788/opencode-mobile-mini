import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../kit_illustration.dart';
import '../kit_tokens.dart';
import 'setup_cast.dart';
import '../kit_motion.dart';

/// A server that is not answering (design standard §10): the app's plug
/// hangs just short of a quiet, grey portal, with a few small marks in the
/// gap. Ambient while the app keeps trying: the plug nudges towards the
/// portal and back, and a faint spark flickers inside it.
class SetupUnpluggedScene extends KitScene {
  const SetupUnpluggedScene();

  @override
  Size get box => const Size(160, 120);

  static final Path _cable = Path()
    ..moveTo(40, 60)
    ..cubicTo(22, 60, 30, 96, 6, 100);
  static final RRect _plug = RRect.fromRectAndRadius(
    const Rect.fromLTRB(40, 50, 60, 70),
    const Radius.circular(4),
  );
  static const _portal = Offset(120, 60);

  /// The gap's marks: short strokes fanning out between plug and portal.
  static final List<(Offset, Offset)> _marks = [
    for (final angle in [-.9, 0.0, .9])
      (
        const Offset(80, 60) + Offset(math.cos(angle), math.sin(angle)) * 5,
        const Offset(80, 60) + Offset(math.cos(angle), math.sin(angle)) * 11,
      ),
  ];

  @override
  void paint(Canvas canvas, KitSceneFrame frame) {
    final p = frame.palette;
    final t = frame.entrance;
    final reach = frame.looping ? KitDraw.wave(frame.loop) : 0.0;

    // A quiet neutral wash behind the portal, no louder than an accent wash
    // (LOOK-36).
    final wash = KitDraw.interval(t, 0, .4);
    canvas.drawCircle(
      _portal,
      34 * (.7 + .3 * wash),
      KitDraw.fill(KitDraw.fade(p.line, KitTokens.sceneWashAlpha * wash)),
    );

    // The portal: grey, open, waiting.
    SetupCast.portal(
      canvas,
      center: _portal,
      size: 48,
      color: KitDraw.fade(p.muted, .75),
      upper: KitDraw.interval(t, .1, .55),
      lower: KitDraw.interval(t, .2, .65),
      width: KitDraw.stroke,
    );
    if (frame.looping) {
      canvas.drawCircle(
        _portal,
        3.5,
        KitDraw.fill(KitDraw.fade(p.accent, .5 * reach)),
      );
    }

    // The cable and the plug, which nudges towards the portal and back.
    canvas.save();
    canvas.translate(5 * reach, 0);
    KitDraw.partialPath(
      canvas,
      _cable,
      KitDraw.interval(t, .3, .7),
      KitDraw.pen(p.muted),
    );
    final plug = KitDraw.interval(t, .5, .8, KitMotion.land);
    if (plug > 0) {
      canvas.save();
      canvas.translate(50, 60);
      canvas.scale(plug);
      canvas.translate(-50, -60);
      canvas.drawRRect(_plug, KitDraw.fill(p.accentSoft));
      canvas.drawRRect(_plug, KitDraw.pen(p.accent));
      final prong = KitDraw.pen(p.accent, 3.5);
      canvas.drawLine(const Offset(60, 55.5), const Offset(69, 55.5), prong);
      canvas.drawLine(const Offset(60, 64.5), const Offset(69, 64.5), prong);
      canvas.restore();
    }
    canvas.restore();

    // The gap: a few short marks in the muted tone (LOOK-4: "not answering"
    // is not "needs you", so it never reaches for the attention amber).
    final marks = KitDraw.interval(t, .75, 1);
    if (marks > 0) {
      final pen = KitDraw.pen(
        KitDraw.fade(p.muted, marks * (1 - .5 * reach)),
        KitDraw.hairline,
      );
      for (final (a, b) in _marks) {
        canvas.drawLine(
          Offset.lerp(a, b, 1 - marks)! + const Offset(6, 0),
          b + const Offset(6, 0),
          pen,
        );
      }
    }

    // Two quiet dots, the family's detail.
    final dots = KitDraw.interval(t, .6, 1);
    final dot = KitDraw.fill(KitDraw.fade(p.muted, .4 * dots));
    canvas.drawCircle(const Offset(142, 22), 2.2, dot);
    canvas.drawCircle(const Offset(24, 30), 1.8, dot);
  }
}
