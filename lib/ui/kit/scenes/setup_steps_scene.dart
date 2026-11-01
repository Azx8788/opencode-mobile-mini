import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../kit_illustration.dart';
import '../kit_tokens.dart';
import 'setup_cast.dart';
import '../kit_motion.dart';

/// The part of setup that is happening now, as the drawing shows it.
enum SetupSceneStage { download, unpack, install, start }

/// Why a setup drawing stands still.
enum SetupSceneHalt { paused, failed }

/// Setup's progress as a small journey (design standard §10): a cloud, a
/// parcel, the phone. Dots carry the download from the cloud, the parcel's
/// flaps open while it unpacks, the phone's screen fills one line per
/// finished component while it installs, and the portal forms on the
/// screen when OpenCode starts. Every part it lights comes from the job's
/// real state; ambient, it carries dots along the active leg.
class SetupStepsScene extends KitScene {
  const SetupStepsScene({
    required this.stage,
    required this.done,
    required this.total,
    this.fraction,
    this.halted,
  });

  final SetupSceneStage stage;

  /// Finished components, of [total].
  final int done;
  final int total;

  /// How far the current component is (0..1), when it is measured.
  final double? fraction;

  /// Stopped part way or failed: nothing moves and the colour drains (or
  /// turns to the failure colour on the part that failed).
  final SetupSceneHalt? halted;

  @override
  Size get box => const Size(240, 100);

  /// The step strip shows progress along a line (LAY-8): it mirrors under
  /// RTL so the finished stop stays at the reading direction's end.
  @override
  bool get mirrorsInRtl => true;

  @override
  bool differs(covariant SetupStepsScene old) =>
      super.differs(old) ||
      old.stage != stage ||
      old.done != done ||
      old.total != total ||
      old.fraction != fraction ||
      old.halted != halted;

  static final Path _cloud = Path.combine(
    PathOperation.union,
    Path.combine(
      PathOperation.union,
      Path()
        ..addOval(Rect.fromCircle(center: const Offset(30, 58), radius: 10))
        ..addOval(Rect.fromCircle(center: const Offset(57, 58), radius: 11)),
      Path()
        ..addOval(Rect.fromCircle(center: const Offset(43, 48), radius: 14)),
    ),
    Path()..addRect(const Rect.fromLTRB(30, 54, 57, 69)),
  );
  static final Path _arrowHead = Path()
    ..moveTo(38, 56.5)
    ..lineTo(43, 61.5)
    ..lineTo(48, 56.5);
  static final RRect _parcel = RRect.fromRectAndRadius(
    const Rect.fromLTRB(104, 50, 138, 78),
    const Radius.circular(4),
  );
  static final Path _frame = SetupCast.phone(
    const Rect.fromLTRB(178, 6, 222, 96),
    10,
  );
  static final RRect _screen = RRect.fromRectAndRadius(
    const Rect.fromLTRB(184.5, 13, 215.5, 89),
    const Radius.circular(5),
  );
  static const _legOne = (Offset(76, 62), Offset(96, 62));
  static const _legTwo = (Offset(146, 62), Offset(168, 62));
  static const _portal = Offset(200, 76);

  int get _index => SetupSceneStage.values.indexOf(stage);

  @override
  void paint(Canvas canvas, KitSceneFrame frame) {
    final p = frame.palette;
    final t = frame.entrance;
    final halt = halted;
    final active = halt == SetupSceneHalt.failed
        ? p.failure
        : halt == SetupSceneHalt.paused
        ? p.muted
        : p.accent;
    // A halted strip washes in the quiet neutral, never louder than the
    // accent's own wash (LOOK-36: flat fills at no more than
    // KitTokens.sceneWashAlpha).
    final soft = halt == null
        ? p.accentSoft
        : KitDraw.fade(p.line, KitTokens.sceneWashAlpha);
    final loop = frame.looping && halt == null;
    final breath = loop ? KitDraw.wave(frame.loop) : 0.0;
    final measured = (fraction ?? .5).clamp(0.0, 1.0);

    Color station(int index) => index == _index
        ? active
        : index < _index
        ? p.muted
        : KitDraw.fade(p.muted, .45);

    // A wash under the part that is working now.
    final washAt = [
      const Offset(44, 58),
      const Offset(121, 64),
      const Offset(200, 50),
      const Offset(200, 50),
    ][_index];
    final wash = KitDraw.interval(t, .3, .7);
    canvas.drawCircle(
      washAt,
      (_index >= 2 ? 34 : 30) + 2 * breath,
      KitDraw.fill(KitDraw.fade(soft, wash)),
    );

    // 1. The cloud.
    KitDraw.partialPath(
      canvas,
      _cloud,
      KitDraw.interval(t, 0, .4),
      KitDraw.pen(station(0), 4),
    );
    // While downloading, an arrow inside it drops a little with each breath.
    if (stage == SetupSceneStage.download) {
      final arrow = KitDraw.interval(t, .4, .7);
      if (arrow > 0) {
        final pen = KitDraw.pen(KitDraw.fade(active, arrow), 3);
        canvas.save();
        canvas.translate(0, 2 * breath);
        canvas.drawLine(const Offset(43, 48), const Offset(43, 61), pen);
        canvas.drawPath(_arrowHead, pen);
        canvas.restore();
      }
    }

    // 2. The parcel, its tape and flaps: shut, then open once unpacked.
    final parcel = KitDraw.interval(t, .15, .5);
    if (parcel > 0) {
      final pen = KitDraw.pen(KitDraw.fade(station(1), parcel), 4);
      canvas.drawRRect(_parcel, pen);
      final opened = _index > 1
          ? 1.0
          : _index == 1
          ? math.max(.35, measured)
          : 0.0;
      final angle =
          opened * 2.2 + (stage == SetupSceneStage.unpack ? .15 * breath : 0);
      const pivotL = Offset(104, 50);
      const pivotR = Offset(138, 50);
      canvas.drawLine(
        pivotL,
        pivotL + Offset(math.cos(angle), -math.sin(angle)) * 17,
        pen,
      );
      canvas.drawLine(
        pivotR,
        pivotR + Offset(-math.cos(angle), -math.sin(angle)) * 17,
        pen,
      );
      canvas.drawLine(
        const Offset(121, 50),
        const Offset(121, 60),
        KitDraw.pen(KitDraw.fade(station(1), .6 * parcel), KitDraw.hairline),
      );
    }

    // 3. The phone and its lit screen.
    final lit = KitDraw.interval(t, .3, .6);
    if (lit > 0) {
      canvas.drawRRect(_screen, KitDraw.fill(KitDraw.fade(p.surface, lit)));
      if (_index >= 2) {
        canvas.drawRRect(_screen, KitDraw.fill(KitDraw.fade(soft, lit)));
      }
    }
    KitDraw.partialPath(
      canvas,
      _frame,
      KitDraw.interval(t, .3, .7),
      KitDraw.pen(p.muted, 4.5),
    );

    // The legs between them: dotted, lit as far as the job has come.
    _leg(
      canvas,
      _legOne,
      _index > 0 ? 1 : measured,
      t,
      p,
      active,
      travelling: loop && stage == SetupSceneStage.download,
      loopAt: frame.loop,
    );
    _leg(
      canvas,
      _legTwo,
      _index > 1
          ? 1
          : _index == 1
          ? measured
          : 0,
      t,
      p,
      active,
      travelling: loop && stage == SetupSceneStage.install,
      loopAt: frame.loop,
    );

    // One line on the screen per component: done, this one, still to come.
    final rows = math.min(total, 6);
    final shown = rows == 0 ? 0 : (done * rows / math.max(total, 1)).floor();
    for (var i = 0; i < rows; i++) {
      final y = 22.0 + i * 8.5;
      final appear = KitDraw.interval(t, .5 + i * .06, .75 + i * .05);
      if (appear <= 0) continue;
      final finished = i < shown;
      final current = i == shown && stage != SetupSceneStage.start;
      final end = 192 + 16 * appear;
      canvas.drawLine(
        Offset(192, y),
        Offset(end, y),
        KitDraw.pen(
          finished
              ? KitDraw.fade(halt == null ? p.accent : p.muted, .95)
              : KitDraw.fade(p.line, 1),
          3,
        ),
      );
      if (current) {
        final part = fraction ?? (.35 + .3 * breath);
        canvas.drawLine(
          Offset(192, y),
          Offset(192 + 16 * appear * part, y),
          KitDraw.pen(active, 3),
        );
      }
      canvas.drawCircle(
        Offset(188, y),
        1.8,
        KitDraw.fill(
          finished
              ? (halt == null ? p.accent : p.muted)
              : current
              ? active
              : p.line,
        ),
      );
    }

    // 4. OpenCode starts: the portal forms on the screen and breathes.
    if (stage == SetupSceneStage.start) {
      final form = KitDraw.interval(t, .55, .95);
      SetupCast.portal(
        canvas,
        center: _portal,
        size: 20,
        color: active,
        upper: form,
        lower: KitDraw.interval(t, .65, 1),
        open: 1.2 * breath,
        width: 3.2,
      );
      final land = KitDraw.interval(t, .85, 1, KitMotion.land);
      canvas.drawCircle(
        loop ? SetupCast.orbit(_portal, 1.5, frame.loop) : _portal,
        2 * land,
        KitDraw.fill(active),
      );
    }
  }

  void _leg(
    Canvas canvas,
    (Offset, Offset) leg,
    double lit,
    double t,
    KitPalette p,
    Color active, {
    required bool travelling,
    required double loopAt,
  }) {
    final (from, to) = leg;
    const count = 5;
    final shown = KitDraw.interval(t, .35, .7);
    if (shown <= 0) return;
    for (var i = 0; i < count; i++) {
      final at = i / (count - 1);
      final on = at <= lit + 1e-6 && lit > 0;
      canvas.drawCircle(
        Offset.lerp(from, to, at)!,
        on ? 2.1 : 1.6,
        KitDraw.fill(KitDraw.fade(on ? active : p.line, shown)),
      );
    }
    if (travelling) {
      for (var k = 0; k < 2; k++) {
        final at = (loopAt * 2 + k / 2) % 1;
        final fade = math.sin(at * math.pi);
        canvas.drawCircle(
          Offset.lerp(from, to, at)! + const Offset(0, -7),
          2.4,
          KitDraw.fill(KitDraw.fade(active, fade)),
        );
      }
    }
  }
}
