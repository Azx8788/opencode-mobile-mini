import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../../../l10n/app_localizations.dart';
import '../kit_live_style.dart';
import 'kit_live_support.dart';

/// A faint scope grid with a slow, steady trace across the middle; the trace
/// comes alive while a reply runs.
class KitLiveOscilloscope extends KitLiveStyle {
  const KitLiveOscilloscope();

  @override
  double get ceilingFactor => 2.0;

  @override
  String get id => 'oscilloscope';

  @override
  String label(AppLocalizations l10n) => l10n.liveStyleOscilloscope;

  @override
  void paint(Canvas canvas, Size size, KitLiveFrame frame) {
    final p = frame.palette;
    final peak = livePeak(frame) * ceilingFactor;
    if (peak <= 0) return;
    final dx = size.width / 8;
    final grid = liveCached(frame, 'scope.grid', size, () {
      final path = Path();
      for (var x = 0.0; x <= size.width; x += dx) {
        path
          ..moveTo(x, 0)
          ..lineTo(x, size.height);
      }
      for (var y = size.height % dx / 2; y <= size.height; y += dx) {
        path
          ..moveTo(0, y)
          ..lineTo(size.width, y);
      }
      return path;
    });
    canvas.drawPath(
      grid,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = p.ink.withValues(alpha: peak * .15),
    );

    final run = frame.running, t = frame.t;
    final mid = size.height * .55;
    final amp = dx * (.35 + run * .9);
    final trace = Path();
    for (var x = 0.0; x <= size.width + 3; x += 3) {
      final u = x / size.width;
      final y =
          mid +
          math.sin(u * 9 - t * 1.6) * amp * .6 +
          math.sin(u * 23 + t * 2.3) * amp * .25 * run +
          (liveFbm(u * 6 + t * .8, t * .3) - .5) * amp * (.4 + run);
      x == 0 ? trace.moveTo(x, y) : trace.lineTo(x, y);
    }
    final col = liveMix(p.teal, p.glow, run);
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(
      trace,
      pen
        ..strokeWidth = 6
        ..color = col.withValues(alpha: peak * .2),
    );
    canvas.drawPath(
      trace,
      pen
        ..strokeWidth = 1.3
        ..color = col.withValues(alpha: peak * .65),
    );
  }
}
