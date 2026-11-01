import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../../../l10n/app_localizations.dart';
import '../kit_live_style.dart';
import 'kit_live_support.dart';

/// A fine hexagon lattice, like a carbon panel; a band of light slides
/// across it (green and more often while a reply runs).
class KitLiveHoneycomb extends KitLiveStyle {
  const KitLiveHoneycomb();

  @override
  double get ceilingFactor => 2.0;

  @override
  String get id => 'honeycomb';

  @override
  String label(AppLocalizations l10n) => l10n.liveStyleHoneycomb;

  static Path _hex(Offset c, double r) {
    final path = Path();
    for (var k = 0; k < 6; k++) {
      final an = math.pi / 3 * k;
      final x = c.dx + r * math.cos(an), y = c.dy + r * math.sin(an);
      k == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    return path..close();
  }

  @override
  void paint(Canvas canvas, Size size, KitLiveFrame frame) {
    final p = frame.palette;
    final peak = livePeak(frame) * ceilingFactor;
    if (peak <= 0) return;
    final r = size.width / 16;
    final geo = liveCached(frame, 'honeycomb.geo', size, () {
      final h = r * math.sqrt(3);
      final centres = <Offset>[];
      final all = Path();
      for (var row = -1; row * h * .5 < size.height + h; row++) {
        for (var col = -1; col * r * 3 < size.width + r * 3; col++) {
          final c = Offset(
            col * r * 3 + (row.isOdd ? r * 1.5 : 0),
            row * h * .5,
          );
          centres.add(c);
          all.addPath(_hex(c, r), Offset.zero);
        }
      }
      return (centres, all);
    });
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawPath(
      geo.$2,
      stroke..color = p.ink.withValues(alpha: peak * .24),
    );
    final run = frame.running;
    final clock = liveClock(frame, 'honeycomb', 1 + run * 1.7);
    final band = ((clock * .07) % 1.4 - .2) * (size.width + size.height);
    final sigma = r * 3;
    for (final c in geo.$1) {
      final d = (c.dx + c.dy - band).abs();
      if (d > sigma * 3) continue;
      final lit = math.exp(-(d * d) / (2 * sigma * sigma));
      if (lit < .03) continue;
      canvas.drawPath(
        _hex(c, r),
        stroke
          ..color = liveMix(
            p.ink,
            p.glow,
            lit * run,
          ).withValues(alpha: peak * .12 * lit),
      );
    }
  }
}
