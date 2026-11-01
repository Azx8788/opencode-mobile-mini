import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../../../l10n/app_localizations.dart';
import '../kit_live_style.dart';
import 'kit_live_support.dart';

/// Faint circuit-board traces cover the ground; small pulses of light travel
/// along them, more of them (and greener) while a reply runs.
class KitLiveCircuit extends KitLiveStyle {
  const KitLiveCircuit();

  @override
  double get ceilingFactor => 2.0;

  @override
  String get id => 'circuit';

  @override
  String label(AppLocalizations l10n) => l10n.liveStyleCircuit;

  @override
  void paint(Canvas canvas, Size size, KitLiveFrame frame) {
    final p = frame.palette;
    final peak =
        livePeak(frame) * ceilingFactor * 0.66; // calibrated: text3 keeps 4.5:1
    if (peak <= 0) return;
    final geo = liveCached(frame, 'circuit.geo', size, () => _build(size));
    canvas.drawPath(
      geo.path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = p.ink.withValues(alpha: peak * .25),
    );
    canvas.drawPoints(
      ui.PointMode.points,
      geo.ends,
      Paint()
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 4
        ..color = p.ink.withValues(alpha: peak * .45),
    );
    final run = frame.running;
    final clock = liveClock(frame, 'circuit', 1 + run * 2.1);
    final core = liveMix(p.teal, p.glow, run);
    final dot = Paint()..color = core.withValues(alpha: peak * .45);
    final halo = Paint()..color = core.withValues(alpha: peak * .12);
    for (final tr in geo.traces) {
      for (var q = 0; q < 2; q++) {
        final k = q == 0 ? 1.0 : run;
        if (k < .02) continue;
        final at = tr.pointAt((clock * .12 + tr.offset + q * .5) % 1);
        canvas.drawCircle(
          at,
          5,
          halo..color = halo.color.withValues(alpha: peak * .12 * k),
        );
        canvas.drawCircle(
          at,
          1.8,
          dot..color = dot.color.withValues(alpha: peak * .45 * k),
        );
      }
    }
  }

  static _Geo _build(Size size) {
    final rnd = liveRandom('circuit');
    final g = size.width / 14;
    const dirs = [(1, 0), (0, 1), (1, 1), (-1, 1), (0, -1)];
    final path = Path();
    final ends = <Offset>[];
    final traces = <_Trace>[];
    for (var k = 0; k < 16; k++) {
      var x = (rnd.nextDouble() * 14).roundToDouble() * g;
      var y = (rnd.nextDouble() * size.height / g).roundToDouble() * g;
      final pts = [Offset(x, y)];
      for (var j = 0; j < 5; j++) {
        final d = dirs[rnd.nextInt(5)];
        final n = 1 + rnd.nextInt(3);
        x += d.$1 * g * n;
        y += d.$2 * g * n;
        pts.add(Offset(x, y));
      }
      path.moveTo(pts.first.dx, pts.first.dy);
      for (final q in pts.skip(1)) {
        path.lineTo(q.dx, q.dy);
      }
      ends
        ..add(pts.first)
        ..add(pts.last);
      traces.add(_Trace(pts, rnd.nextDouble()));
    }
    return _Geo(path, ends, traces);
  }
}

class _Geo {
  _Geo(this.path, this.ends, this.traces);
  final Path path;
  final List<Offset> ends;
  final List<_Trace> traces;
}

class _Trace {
  _Trace(this.pts, this.offset) {
    for (var j = 1; j < pts.length; j++) {
      final l = (pts[j] - pts[j - 1]).distance;
      lens.add(l);
      total += l;
    }
  }
  final List<Offset> pts;
  final double offset;
  final List<double> lens = [];
  double total = 0;

  Offset pointAt(double f) {
    var d = f * total;
    for (var j = 0; j < lens.length; j++) {
      if (d <= lens[j]) {
        return Offset.lerp(pts[j], pts[j + 1], lens[j] == 0 ? 0 : d / lens[j])!;
      }
      d -= lens[j];
    }
    return pts.last;
  }
}
