import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import '../../../../l10n/app_localizations.dart';
import '../kit_live_style.dart';
import 'kit_live_toolkit.dart';

class KitLiveGlowSpill extends KitLiveStyle {
  const KitLiveGlowSpill();

  @override
  String get id => 'glowSpill';

  @override
  String label(AppLocalizations l10n) => l10n.liveStyleGlowSpill;

  @override
  void paint(Canvas canvas, Size size, KitLiveFrame f) {
    final p = f.palette;
    // Calibrated so text keeps its contrast at the strongest moment
    // (test/kit/kit_live_background_test.dart).
    final a = strengthOf(f) * .54;
    final run = f.running;
    final t = f.t;
    final w = size.width, h = size.height;
    final br = .5 + .5 * math.sin(t * (1.2 + run * 1.6));
    final r = h * (.45 + run * .3 + br * .05);
    final centre = Offset(w / 2, h * 1.02);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = Gradient.radial(centre, r, [
          withA(p.glow, (.16 + run * .12) * a),
          withA(p.glow, 0),
        ]),
    );
    final grain = f.memory.of<_Grain>('g', () => _Grain(w, h));
    if (grain.w != w || grain.h != h) grain.reset(w, h);
    canvas.drawRawPoints(
      PointMode.points,
      grain.points,
      Paint()
        ..color = withA(p.ink, .05 * a)
        ..strokeWidth = 1,
    );
  }
}

class _Grain {
  _Grain(double w, double h) {
    reset(w, h);
  }
  double w = 0, h = 0;
  Float32List points = Float32List(0);

  void reset(double nw, double nh) {
    w = nw;
    h = nh;
    final rnd = math.Random(11);
    final n = (nw * nh / 90).round();
    points = Float32List(n * 2);
    for (var i = 0; i < n; i++) {
      points[i * 2] = rnd.nextDouble() * nw;
      points[i * 2 + 1] = rnd.nextDouble() * nh;
    }
  }
}
