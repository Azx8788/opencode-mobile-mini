import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../../../l10n/app_localizations.dart';
import '../kit_live_style.dart';
import 'kit_live_support.dart';

/// The shimmering net of light on the floor of a pool, moving gently; the
/// water gets livelier and greener while a reply runs.
///
/// A small grid of values is computed each frame and drawn as one coloured
/// mesh, which the GPU smooths up to the full screen.
class KitLiveCaustics extends KitLiveStyle {
  const KitLiveCaustics();

  @override
  String get id => 'caustics';

  @override
  String label(AppLocalizations l10n) => l10n.liveStyleCaustics;

  @override
  void paint(Canvas canvas, Size size, KitLiveFrame frame) {
    final p = frame.palette;
    final peak = livePeak(frame);
    if (peak <= 0) return;
    final run = frame.running;
    final tt = liveClock(frame, 'caustics', 1 + run * 1.4) * .25;
    final cell = math.max(8.0, size.width / 56);
    final mesh = liveCached(frame, 'caustics.mesh', size, () {
      final cols = (size.width / cell).ceil(),
          rows = (size.height / cell).ceil();
      final pos = Float32List((cols + 1) * (rows + 1) * 2);
      var n = 0;
      for (var y = 0; y <= rows; y++) {
        for (var x = 0; x <= cols; x++) {
          pos[n++] = math.min(x * cell, size.width);
          pos[n++] = math.min(y * cell, size.height);
        }
      }
      final idx = Uint16List(cols * rows * 6);
      n = 0;
      for (var y = 0; y < rows; y++) {
        for (var x = 0; x < cols; x++) {
          final a = y * (cols + 1) + x, b = a + 1, c = a + cols + 1, d = c + 1;
          idx
            ..[n++] = a
            ..[n++] = b
            ..[n++] = c
            ..[n++] = b
            ..[n++] = d
            ..[n++] = c;
        }
      }
      return _Mesh(cols, rows, pos, idx, Int32List((cols + 1) * (rows + 1)));
    });
    final rgb = liveMix(p.teal, p.glow, run);
    final r = (rgb.r * 255).round(), g = (rgb.g * 255).round();
    final b = (rgb.b * 255).round();
    final inv = size.width / cell; // columns across the width
    var n = 0;
    for (var y = 0; y <= mesh.rows; y++) {
      for (var x = 0; x <= mesh.cols; x++) {
        final u = x / inv, v = y / inv;
        final w = liveFbm(u * 2 + tt * .3, v * 2 - tt * .2) * 5;
        final a = math.sin(u * 13 + w + tt);
        final bb = math.sin(v * 11 - w * .8 - tt * .7);
        final d = math.sin((u + v) * 9 + w * .6 + tt * .5);
        final val = (a + bb + d).abs() / 3;
        final line = liveSmooth(.62, .95, 1 - val);
        final alpha = (line * peak * 255).round();
        mesh.colors[n++] = (alpha << 24) | (r << 16) | (g << 8) | b;
      }
    }
    final v = ui.Vertices.raw(
      ui.VertexMode.triangles,
      mesh.positions,
      colors: mesh.colors,
      indices: mesh.indices,
    );
    canvas.drawVertices(v, BlendMode.dst, Paint());
    v.dispose();
  }
}

class _Mesh {
  _Mesh(this.cols, this.rows, this.positions, this.indices, this.colors);
  final int cols, rows;
  final Float32List positions;
  final Uint16List indices;
  final Int32List colors;
}
