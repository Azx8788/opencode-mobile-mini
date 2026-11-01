import 'package:flutter/material.dart';

import '../kit_illustration.dart';

/// The recurring cast of the Servers drawings (design standard §10): a
/// phone with a rounded screen, a laptop, and the brand's portal on the
/// laptop's screen. Each part draws itself in with [KitDraw.partialPath]
/// from a 0..1 [t], so the scenes stage them the same way.
///
/// Each part's paths are built once, when the scene's static instance is
/// created, never per frame.
class ServersPhone {
  ServersPhone(this.body)
    : outline = Path()
        ..addRRect(
          RRect.fromRectAndRadius(body, Radius.circular(body.width * .25)),
        ),
      speaker = Path()
        ..moveTo(body.center.dx - body.width * .14, body.top + body.height * .1)
        ..lineTo(
          body.center.dx + body.width * .14,
          body.top + body.height * .1,
        ),
      lines = [
        for (final (y, w) in const [(.34, .5), (.48, .34), (.62, .44)])
          Path()
            ..moveTo(body.left + body.width * .24, body.top + body.height * y)
            ..lineTo(
              body.left + body.width * (.24 + w),
              body.top + body.height * y,
            ),
      ];

  final Rect body;
  final Path outline;
  final Path speaker;

  /// Three short lines on the screen: a conversation.
  final List<Path> lines;

  void paint(Canvas canvas, KitPalette palette, double t, {Color? screen}) {
    if (t <= 0) return;
    final radius = Radius.circular(body.width * .25);
    canvas.drawRRect(
      RRect.fromRectAndRadius(body, radius),
      KitDraw.fill(KitDraw.fade(palette.surface, KitDraw.interval(t, .3, 1))),
    );
    KitDraw.partialPath(
      canvas,
      outline,
      KitDraw.interval(t, 0, .8),
      KitDraw.pen(palette.muted, 4),
    );
    final detail = KitDraw.interval(t, .55, 1);
    KitDraw.partialPath(
      canvas,
      speaker,
      detail,
      KitDraw.pen(palette.line, KitDraw.hairline),
    );
    for (var i = 0; i < lines.length; i++) {
      KitDraw.partialPath(
        canvas,
        lines[i],
        KitDraw.interval(t, .6 + i * .1, .9 + i * .03),
        KitDraw.pen(screen ?? palette.line, KitDraw.hairline + .5),
      );
    }
  }
}

/// A laptop: a screen with rounded corners and a base with a hinge notch.
class ServersLaptop {
  ServersLaptop(this.screen)
    : outline = Path()
        ..addRRect(
          RRect.fromRectAndRadius(screen, Radius.circular(screen.height * .14)),
        ),
      base = Path()
        ..moveTo(screen.left - screen.width * .12, screen.bottom + 9)
        ..lineTo(screen.right + screen.width * .12, screen.bottom + 9),
      hinge = Path()
        ..moveTo(screen.center.dx - screen.width * .12, screen.bottom + 9)
        ..lineTo(screen.center.dx - screen.width * .08, screen.bottom + 12.5)
        ..lineTo(screen.center.dx + screen.width * .08, screen.bottom + 12.5)
        ..lineTo(screen.center.dx + screen.width * .12, screen.bottom + 9);

  final Rect screen;
  final Path outline;
  final Path base;
  final Path hinge;

  void paint(Canvas canvas, KitPalette palette, double t) {
    if (t <= 0) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(screen, Radius.circular(screen.height * .14)),
      KitDraw.fill(KitDraw.fade(palette.surface, KitDraw.interval(t, .3, 1))),
    );
    KitDraw.partialPath(
      canvas,
      outline,
      KitDraw.interval(t, 0, .7),
      KitDraw.pen(palette.muted, 4),
    );
    KitDraw.partialPath(
      canvas,
      base,
      KitDraw.interval(t, .35, .9),
      KitDraw.pen(palette.muted, 4),
    );
    KitDraw.partialPath(
      canvas,
      hinge,
      KitDraw.interval(t, .6, 1),
      KitDraw.pen(palette.line, KitDraw.hairline),
    );
  }
}

/// The brand's "open portal" mark (assets/branding/open-portal/mark.svg) at
/// any size: its two brackets in the mark's own geometry, scaled.
abstract final class ServersPortal {
  static final Path _upper = Path()
    ..moveTo(61, 31)
    ..lineTo(43, 31)
    ..arcToPoint(
      const Offset(31, 43),
      radius: const Radius.circular(12),
      clockwise: false,
    )
    ..lineTo(31, 64);

  static final Path _lower = Path()
    ..moveTo(77, 44)
    ..lineTo(77, 65)
    ..arcToPoint(const Offset(65, 77), radius: const Radius.circular(12))
    ..lineTo(44, 77);

  /// Draws the mark centred on [center], [size] units across, each bracket
  /// drawing itself in over [t]. [dot] (0..1) lands the spark in the middle.
  static void paint(
    Canvas canvas,
    Offset center,
    double size,
    Color color,
    double t, {
    double dot = 0,
    Color? dotColor,
  }) {
    if (t <= 0 && dot <= 0) return;
    final scale = size / 60;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(scale);
    canvas.translate(-54, -54);
    final pen = KitDraw.pen(color, 10);
    KitDraw.partialPath(canvas, _upper, KitDraw.interval(t, 0, .7), pen);
    KitDraw.partialPath(canvas, _lower, KitDraw.interval(t, .25, 1), pen);
    if (dot > 0) {
      canvas.drawCircle(
        const Offset(54, 54),
        6.5 * dot,
        KitDraw.fill(dotColor ?? color),
      );
    }
    canvas.restore();
  }
}

/// A small four-point sparkle (decoration around a hero), [size] units.
void paintSparkle(Canvas canvas, Offset center, double size, Paint paint) {
  canvas.drawLine(center.translate(0, -size), center.translate(0, size), paint);
  canvas.drawLine(center.translate(-size, 0), center.translate(size, 0), paint);
}
