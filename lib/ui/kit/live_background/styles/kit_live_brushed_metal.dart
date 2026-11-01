import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../../../l10n/app_localizations.dart';
import '../kit_live_style.dart';
import 'kit_live_support.dart';

/// A fine brushed-metal grain with a soft highlight gliding across it, like
/// an aluminium case catching light; the highlight warms to green and glides
/// faster while a reply runs.
class KitLiveBrushedMetal extends KitLiveStyle {
  const KitLiveBrushedMetal();

  @override
  String get id => 'brushedMetal';

  @override
  String label(AppLocalizations l10n) => l10n.liveStyleBrushedMetal;

  @override
  void paint(Canvas canvas, Size size, KitLiveFrame frame) {
    final p = frame.palette;
    final peak = livePeak(frame);
    if (peak <= 0) return;
    final grain = liveCached<ui.Picture>(
      frame,
      'brushed.grain',
      size,
      () {
        final rec = ui.PictureRecorder();
        final c = Canvas(rec);
        final rnd = liveRandom('brushedMetal');
        final paint = Paint();
        for (var y = 0.0; y < size.height; y++) {
          final split = rnd.nextDouble() * size.width;
          paint.color = p.ink.withValues(alpha: peak * .55 * rnd.nextDouble());
          c.drawRect(Rect.fromLTWH(0, y, split, 1), paint);
          paint.color = p.ink.withValues(alpha: peak * .55 * rnd.nextDouble());
          c.drawRect(Rect.fromLTWH(split, y, size.width - split, 1), paint);
        }
        return rec.endRecording();
      },
      sig: (p.ink, peak),
      dispose: (old) => old.dispose(),
    );
    canvas.drawPicture(grain);

    final run = frame.running;
    final clock = liveClock(frame, 'brushed', 1 + run * 2);
    final x = ((clock * .05) % 1.6 - .3) * size.width * 2;
    final col = liveMix(p.ink, p.glow, run * .8);
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(x - size.width * .5, 0),
          Offset(x + size.width * .2, size.height * .6),
          [
            col.withValues(alpha: 0),
            col.withValues(alpha: peak * .45),
            col.withValues(alpha: 0),
          ],
          const [0, .5, 1],
        ),
    );
  }
}
