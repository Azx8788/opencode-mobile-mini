import 'dart:math' as math;
import 'dart:ui';

import '../../../../l10n/app_localizations.dart';
import '../kit_live_style.dart';
import 'kit_live_toolkit.dart';

class KitLiveHalftone extends KitLiveStyle {
  const KitLiveHalftone();

  @override
  String get id => 'halftone';

  @override
  String label(AppLocalizations l10n) => l10n.liveStyleHalftone;

  @override
  void paint(Canvas canvas, Size size, KitLiveFrame f) {
    final p = f.palette;
    // Calibrated so text keeps its contrast at the strongest moment
    // (test/kit/kit_live_background_test.dart).
    final a = strengthOf(f) * .65;
    final run = f.running;
    final t = f.t;
    final w = size.width, h = size.height;
    final sp = math.max(9.0, w / 26);
    final cols = (w / sp).ceil(), rows = (h / sp).ceil();
    final warp = f.memory.of<List<double>>('w$w$h', () {
      final out = <double>[];
      for (var r = 0; r < rows; r++) {
        for (var c = 0; c < cols; c++) {
          out.add(fbm((c * sp + sp / 2) * .01, (r * sp + sp / 2) * .01) * 3);
        }
      }
      return out;
    });
    final paint = Paint();
    for (var r = 0; r < rows; r++) {
      final y = r * sp + sp / 2;
      for (var c = 0; c < cols; c++) {
        final x = c * sp + sp / 2;
        final wv =
            .5 +
            .5 *
                math.sin(
                  x * .025 +
                      y * .018 -
                      t * (.5 + run * .9) +
                      warp[r * cols + c],
                );
        final rad = wv * wv * sp * .28;
        final g = run * smooth(.4, 1, y / h);
        paint.color = withA(mixColor(p.ink, p.glow, g), (.12 + g * .15) * a);
        canvas.drawCircle(Offset(x, y), rad, paint);
      }
    }
  }
}
