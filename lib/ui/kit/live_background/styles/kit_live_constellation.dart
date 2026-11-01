import 'dart:math' as math;
import 'dart:ui';

import '../../../../l10n/app_localizations.dart';
import '../kit_live_style.dart';
import 'kit_live_toolkit.dart';

class KitLiveConstellation extends KitLiveStyle {
  const KitLiveConstellation();

  @override
  String get id => 'constellation';

  @override
  String label(AppLocalizations l10n) => l10n.liveStyleConstellation;

  @override
  void paint(Canvas canvas, Size size, KitLiveFrame f) {
    final p = f.palette;
    final a = strengthOf(f);
    final run = f.running;
    final t = f.t;
    final w = size.width, h = size.height;
    final st = f.memory.of<_Stars>('s', () => _Stars(w, h));
    if (st.w != w || st.h != h) {
      st
        ..reset(w, h)
        ..last = t;
    }
    var dt = t - st.last;
    st.last = t;
    if (dt < 0 || dt > .2) dt = 1 / 24;
    final steps = dt * 30 * (w / 390);
    final reach = w * (.22 + run * .12);
    for (final q in st.q) {
      q.x = (q.x + q.vx * (1 + run * 2) * steps + w) % w;
      q.y = (q.y + q.vy * (1 + run * 2) * steps + h) % h;
    }
    final line = Paint()..strokeWidth = .6;
    final linkColour = mixColor(p.ink, p.glow, run);
    for (var i = 0; i < st.q.length; i++) {
      for (var j = i + 1; j < st.q.length; j++) {
        final q1 = st.q[i], q2 = st.q[j];
        final d = math.sqrt(
          (q1.x - q2.x) * (q1.x - q2.x) + (q1.y - q2.y) * (q1.y - q2.y),
        );
        if (d < reach) {
          line.color = withA(linkColour, (1 - d / reach) * .16 * a);
          canvas.drawLine(Offset(q1.x, q1.y), Offset(q2.x, q2.y), line);
        }
      }
    }
    final dot = Paint()
      ..color = withA(mixColor(p.ink, p.glow, run * .7), .35 * a);
    for (final q in st.q) {
      canvas.drawCircle(Offset(q.x, q.y), 1.1, dot);
    }
  }
}

class _Star {
  _Star(this.x, this.y, this.vx, this.vy);
  double x, y, vx, vy;
}

class _Stars {
  _Stars(double w, double h) {
    reset(w, h);
  }
  double w = 0, h = 0, last = 0;
  List<_Star> q = [];

  void reset(double nw, double nh) {
    w = nw;
    h = nh;
    final rnd = math.Random(5);
    q = List.generate(
      38,
      (_) => _Star(
        rnd.nextDouble() * nw,
        rnd.nextDouble() * nh,
        (rnd.nextDouble() - .5) * .12,
        (rnd.nextDouble() - .5) * .12,
      ),
    );
  }
}
