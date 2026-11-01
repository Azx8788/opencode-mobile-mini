import 'dart:math' as math;
import 'dart:ui';

import '../../../../l10n/app_localizations.dart';
import '../kit_live_style.dart';
import 'kit_live_toolkit.dart';

class KitLiveFlowThreads extends KitLiveStyle {
  const KitLiveFlowThreads();

  @override
  String get id => 'flowThreads';

  @override
  String label(AppLocalizations l10n) => l10n.liveStyleFlowThreads;

  @override
  void paint(Canvas canvas, Size size, KitLiveFrame f) {
    final p = f.palette;
    // Calibrated so text keeps its contrast at the strongest moment
    // (test/kit/kit_live_background_test.dart).
    final a = strengthOf(f) * .54;
    final run = f.running;
    final t = f.t;
    final w = size.width, h = size.height;
    final st = f.memory.of<_Threads>('s', () => _Threads(w, h));
    if (st.w != w || st.h != h) {
      st
        ..reset(w, h)
        ..last = t;
    }
    var dt = t - st.last;
    st.last = t;
    if (dt < 0 || dt > .2) dt = 1 / 24;
    final steps = dt * 30;
    final sp = (.35 + run * .9) * w / 260 * steps;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round
      ..color = withA(mixColor(p.teal, p.glow, run), .5 * a);
    for (final q in st.p) {
      final ang = fbm(q.x / w * 1.5 + t * .01, q.y / w * 1.5) * math.pi * 4;
      q.x += math.cos(ang) * sp;
      q.y += math.sin(ang) * sp;
      if (q.x < 0 || q.x > w || q.y < 0 || q.y > h) {
        q.x = st.rnd.nextDouble() * w;
        q.y = st.rnd.nextDouble() * h;
        q.trail.clear();
      }
      q.trail.add(Offset(q.x, q.y));
      if (q.trail.length > 12) q.trail.removeAt(0);
      if (q.trail.length > 1) {
        final path = Path()..moveTo(q.trail.first.dx, q.trail.first.dy);
        for (final o in q.trail.skip(1)) {
          path.lineTo(o.dx, o.dy);
        }
        canvas.drawPath(path, paint);
      }
    }
  }
}

class _Thread {
  _Thread(this.x, this.y);
  double x, y;
  final List<Offset> trail = [];
}

class _Threads {
  _Threads(double w, double h) {
    reset(w, h);
  }
  double w = 0, h = 0, last = 0;
  final math.Random rnd = math.Random(7);
  List<_Thread> p = [];

  void reset(double nw, double nh) {
    w = nw;
    h = nh;
    p = List.generate(
      220,
      (_) => _Thread(rnd.nextDouble() * nw, rnd.nextDouble() * nh),
    );
  }
}
