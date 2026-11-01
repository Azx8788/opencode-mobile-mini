import 'package:flutter/material.dart';

import '../kit_illustration.dart';
import '../kit_motion.dart';

/// A folder opening (design standard §10), for a folder with nothing in it
/// yet: the back of the folder draws itself, a folded sheet rises out of
/// it, the front swings into place in the accent, and a spark lands where
/// the next project will be. It plays once; it has no loop (an empty folder
/// is a resting screen).
class KitFoldersOpenScene extends KitScene {
  const KitFoldersOpenScene();

  // The back of the folder with its tab, drawn from the tab's end round.
  static final Path _back = Path()
    ..moveTo(52, 36)
    ..lineTo(46, 29)
    ..lineTo(28, 29)
    ..arcToPoint(const Offset(22, 35), radius: const Radius.circular(6))
    ..lineTo(22, 86)
    ..arcToPoint(
      const Offset(28, 92),
      radius: const Radius.circular(6),
      clockwise: false,
    )
    ..lineTo(92, 92)
    ..arcToPoint(
      const Offset(98, 86),
      radius: const Radius.circular(6),
      clockwise: false,
    )
    ..lineTo(98, 42)
    ..arcToPoint(
      const Offset(92, 36),
      radius: const Radius.circular(6),
      clockwise: false,
    )
    ..close();

  // A folded sheet: the outline, then its turned corner.
  static final Path _sheet = Path()
    ..moveTo(40, 62)
    ..lineTo(40, 30)
    ..lineTo(66, 30)
    ..lineTo(76, 40)
    ..lineTo(76, 62);
  static final Path _fold = Path()
    ..moveTo(66, 30)
    ..lineTo(66, 40)
    ..lineTo(76, 40);

  // The front, leaning open: its top edge is wider than the folder.
  static final Path _front = Path()
    ..moveTo(26, 92)
    ..lineTo(92, 92)
    ..arcToPoint(
      const Offset(97, 88),
      radius: const Radius.circular(5),
      clockwise: false,
    )
    ..lineTo(103, 60)
    ..arcToPoint(
      const Offset(98, 54),
      radius: const Radius.circular(5),
      clockwise: false,
    )
    ..lineTo(22, 54)
    ..arcToPoint(
      const Offset(17, 60),
      radius: const Radius.circular(5),
      clockwise: false,
    )
    ..lineTo(21, 88)
    ..arcToPoint(
      const Offset(26, 92),
      radius: const Radius.circular(5),
      clockwise: false,
    )
    ..close();

  static const _spark = Offset(88, 22);

  @override
  void paint(Canvas canvas, KitSceneFrame frame) {
    final palette = frame.palette;
    final t = frame.entrance;

    KitDraw.partialPath(
      canvas,
      _back,
      KitDraw.interval(t, 0, .45),
      KitDraw.pen(palette.muted),
    );

    final rise = KitDraw.interval(t, .3, .7, KitMotion.enter);
    if (rise > 0) {
      canvas.save();
      canvas.translate(0, 14 * (1 - rise));
      final sheetPen = KitDraw.pen(
        KitDraw.fade(palette.ink, rise),
        KitDraw.hairline,
      );
      canvas.drawPath(_sheet, sheetPen);
      canvas.drawPath(_fold, sheetPen);
      canvas.restore();
    }

    final swing = KitDraw.interval(t, .45, .9, KitMotion.land);
    if (swing > 0) {
      canvas.save();
      // Hinged at the bottom edge: it tips up into place.
      canvas.translate(0, 92);
      canvas.scale(1, swing.clamp(0, 1.2));
      canvas.translate(0, -92);
      // Opaque first, so the sheet behind it is hidden, then the wash.
      canvas.drawPath(_front, KitDraw.fill(palette.surface));
      canvas.drawPath(_front, KitDraw.fill(palette.accentSoft));
      canvas.drawPath(_front, KitDraw.pen(palette.accent));
      canvas.restore();
    }

    final land = KitDraw.interval(t, .75, 1, KitMotion.land);
    if (land > 0) {
      canvas.drawCircle(_spark, 4.5 * land, KitDraw.fill(palette.accent));
      final ray = KitDraw.pen(
        KitDraw.fade(palette.accent, land.clamp(0, 1)),
        KitDraw.hairline,
      );
      for (final (from, to) in const [
        (Offset(88, 12), Offset(88, 7)),
        (Offset(98, 22), Offset(103, 22)),
        (Offset(95, 15), Offset(99, 11)),
      ]) {
        canvas.drawLine(
          Offset.lerp(_spark, from, land)!,
          Offset.lerp(_spark, to, land)!,
          ray,
        );
      }
    }
  }
}
