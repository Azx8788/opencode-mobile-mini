import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../kit_illustration.dart';

/// The pieces the empty, quiet and failure drawings share (design standard
/// §10, motion-and-illustration spec slice C), so a folded sheet, a spark
/// or the soft wash behind a drawing look the same in every scene.
abstract final class StatesParts {
  /// The soft accent wash every state drawing sits on: it grows in first,
  /// so the line work lands on something.
  static void wash(
    Canvas canvas,
    KitSceneFrame frame, {
    Offset center = const Offset(60, 62),
    double radius = 44,
  }) {
    final grow = KitDraw.interval(frame.entrance, 0, .35);
    if (grow <= 0) return;
    canvas.drawCircle(
      center,
      radius * (.82 + .18 * grow),
      KitDraw.fill(KitDraw.fade(frame.palette.accentSoft, .75 * grow)),
    );
  }

  /// A sheet of paper with its top end corner folded over: the cast's
  /// "folded sheet" for conversations and files.
  static Path sheet(Rect rect, {double fold = 14, double radius = 6}) {
    final r = Radius.circular(radius);
    return Path()
      ..moveTo(rect.left + radius, rect.top)
      ..lineTo(rect.right - fold, rect.top)
      ..lineTo(rect.right, rect.top + fold)
      ..lineTo(rect.right, rect.bottom - radius)
      ..arcToPoint(Offset(rect.right - radius, rect.bottom), radius: r)
      ..lineTo(rect.left + radius, rect.bottom)
      ..arcToPoint(Offset(rect.left, rect.bottom - radius), radius: r)
      ..lineTo(rect.left, rect.top + radius)
      ..arcToPoint(Offset(rect.left + radius, rect.top), radius: r)
      ..close();
  }

  /// The folded-over flap of [sheet]'s corner.
  static Path fold(Rect rect, {double fold = 14}) => Path()
    ..moveTo(rect.right - fold, rect.top)
    ..lineTo(rect.right - fold, rect.top + fold - 3)
    ..quadraticBezierTo(
      rect.right - fold,
      rect.top + fold,
      rect.right - fold + 3,
      rect.top + fold,
    )
    ..lineTo(rect.right, rect.top + fold);

  /// Draws a filled, outlined shape: [fill] under a [pen] outline, the
  /// outline drawing itself in over [t].
  static void outlined(
    Canvas canvas,
    Path path,
    double t, {
    required Color fill,
    required Paint pen,
  }) {
    if (t <= 0) return;
    canvas.drawPath(path, KitDraw.fill(KitDraw.fade(fill, t)));
    KitDraw.partialPath(canvas, path, t, pen);
  }

  /// A four-pointed spark at [center], [size] from the middle to a tip,
  /// scaled by [t] (0..1, may overshoot).
  static void spark(
    Canvas canvas,
    Offset center,
    double size,
    double t,
    Color color,
  ) {
    if (t <= 0) return;
    final s = size * t;
    final w = s * .28;
    final path = Path()
      ..moveTo(center.dx, center.dy - s)
      ..quadraticBezierTo(
        center.dx + w * .35,
        center.dy - w * .35,
        center.dx + s,
        center.dy,
      )
      ..quadraticBezierTo(
        center.dx + w * .35,
        center.dy + w * .35,
        center.dx,
        center.dy + s,
      )
      ..quadraticBezierTo(
        center.dx - w * .35,
        center.dy + w * .35,
        center.dx - s,
        center.dy,
      )
      ..quadraticBezierTo(
        center.dx - w * .35,
        center.dy - w * .35,
        center.dx,
        center.dy - s,
      )
      ..close();
    canvas.drawPath(path, KitDraw.fill(color));
  }

  /// Short strokes thrown out from [center] at [angles] (degrees, 0 is to
  /// the right, clockwise), between [inner] and [outer] from the middle.
  static void ticks(
    Canvas canvas,
    Offset center,
    List<double> angles,
    double inner,
    double outer,
    double t,
    Paint pen,
  ) {
    if (t <= 0) return;
    for (final degrees in angles) {
      final a = degrees * math.pi / 180;
      final dir = Offset(math.cos(a), math.sin(a));
      final start = center + dir * inner;
      final end = center + dir * (inner + (outer - inner) * t);
      canvas.drawLine(start, end, pen);
    }
  }
}
