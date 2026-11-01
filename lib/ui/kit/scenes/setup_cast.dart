import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../kit_illustration.dart';

/// The recurring cast of the setup and connecting drawings
/// (docs/design/motion-and-illustration-2026-09-25.md, "Recurring cast"):
/// the portal brackets, a phone with a rounded screen, a terminal prompt,
/// sparkles and dots. Every path is built once; scenes place them with
/// canvas transforms, so painting a frame allocates nothing heavy.
abstract final class SetupCast {
  // mark.svg (viewBox 24..84) in unit space, centred on the origin: the
  // mark spans -0.38..0.38 on both axes.
  static Offset _m(double x, double y) => Offset((x - 54) / 60, (y - 54) / 60);

  static final Path _upper = Path()
    ..moveTo(_m(61, 31).dx, _m(61, 31).dy)
    ..lineTo(_m(43, 31).dx, _m(43, 31).dy)
    ..arcToPoint(
      _m(31, 43),
      radius: const Radius.circular(12 / 60),
      clockwise: false,
    )
    ..lineTo(_m(31, 64).dx, _m(31, 64).dy);

  static final Path _lower = Path()
    ..moveTo(_m(77, 44).dx, _m(77, 44).dy)
    ..lineTo(_m(77, 65).dx, _m(77, 65).dy)
    ..arcToPoint(
      _m(65, 77),
      radius: const Radius.circular(12 / 60),
      clockwise: true,
    )
    ..lineTo(_m(44, 77).dx, _m(44, 77).dy);

  /// The portal mark at [center], [size] scene units across its box.
  ///
  /// [upper] and [lower] (0..1) say how much of each bracket has drawn
  /// itself; [open] moves the brackets apart along the diagonal (negative
  /// closes them), in scene units. [width] is the stroke in scene units.
  static void portal(
    Canvas canvas, {
    required Offset center,
    required double size,
    required Color color,
    double upper = 1,
    double lower = 1,
    double open = 0,
    double? width,
  }) {
    final stroke = (width ?? size / 7) / size;
    final pen = KitDraw.pen(color, stroke);
    final shift = open / size;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(size);
    canvas.save();
    canvas.translate(-shift, -shift);
    KitDraw.partialPath(canvas, _upper, upper, pen);
    canvas.restore();
    canvas.save();
    canvas.translate(shift, shift);
    KitDraw.partialPath(canvas, _lower, lower, pen);
    canvas.restore();
    canvas.restore();
  }

  // A four-point sparkle in unit space: the "energy" mark.
  static final Path _sparkle = Path()
    ..moveTo(0, -1)
    ..quadraticBezierTo(.14, -.14, 1, 0)
    ..quadraticBezierTo(.14, .14, 0, 1)
    ..quadraticBezierTo(-.14, .14, -1, 0)
    ..quadraticBezierTo(-.14, -.14, 0, -1)
    ..close();

  /// A filled sparkle of [radius] at [center], scaled by [pop] (0..1, may
  /// overshoot for a celebration) and turned by [turn] radians.
  static void sparkle(
    Canvas canvas,
    Offset center,
    double radius,
    Color color, {
    double pop = 1,
    double turn = 0,
  }) {
    if (pop <= 0) return;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    if (turn != 0) canvas.rotate(turn);
    canvas.scale(radius * pop);
    canvas.drawPath(_sparkle, KitDraw.fill(color));
    canvas.restore();
  }

  /// A phone's outline as one path (so it can draw itself in), for [frame].
  static Path phone(Rect frame, double radius) =>
      Path()..addRRect(RRect.fromRectAndRadius(frame, Radius.circular(radius)));

  /// A `>` prompt whose top-left is at [origin], [size] units tall.
  static Path prompt(Offset origin, double size) => Path()
    ..moveTo(origin.dx, origin.dy)
    ..lineTo(origin.dx + size / 2, origin.dy + size / 2)
    ..lineTo(origin.dx, origin.dy + size);

  /// A check mark inside a box of [size] centred at [center].
  static Path check(Offset center, double size) => Path()
    ..moveTo(center.dx - size * .36, center.dy + size * .02)
    ..lineTo(center.dx - size * .1, center.dy + size * .28)
    ..lineTo(center.dx + size * .38, center.dy - size * .24);

  /// Whether a blinking cursor shows at [loop] (twice per loop period).
  static bool cursorOn(KitSceneFrame frame) =>
      !frame.looping || (frame.loop * 4).floor().isEven;

  /// A point on the circle of [radius] around [center] at [turns] (0..1,
  /// from the top, clockwise).
  static Offset orbit(Offset center, double radius, double turns) {
    final angle = turns * 2 * math.pi - math.pi / 2;
    return center + Offset(math.cos(angle), math.sin(angle)) * radius;
  }
}
