import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../kit_illustration.dart';
import 'states_parts.dart';
import '../kit_motion.dart';

// The empty, quiet and failure drawings (design standard §10; spec
// docs/design/motion-and-illustration-2026-09-25.md, slice C). One drawing
// per kind of state, reused wherever that state is the same:
//
// | Drawing | State |
// |---|---|
// | [StatesSheetScene] | no conversations yet (Work, All conversations, a new chat) |
// | [StatesFolderScene] | no project yet, an empty folder |
// | [StatesTrayScene] | all caught up (Inbox) |
// | [StatesSearchScene] | a search that found nothing |
// | [StatesTerminalScene] | no terminal yet / not set up; a shell that ended |
// | [StatesUnpluggedScene] | not answering, offline, could not load |
//
// Every one sits on the same soft wash, draws its outline in muted line
// work and keeps the accent for the one thing that matters. They are still
// once drawn: none of them loops (these are resting screens).

/// A fresh folded sheet with a caret waiting on its last line, and a spark:
/// nothing written yet, ready to start. Used for "no conversations yet".
class StatesSheetScene extends KitScene {
  const StatesSheetScene();

  static const _back = Rect.fromLTRB(44, 20, 92, 84);
  static const _front = Rect.fromLTRB(26, 32, 80, 102);
  static final Path _backPath = StatesParts.sheet(_back, fold: 12);
  static final Path _frontPath = StatesParts.sheet(_front);
  static final Path _frontFold = StatesParts.fold(_front);
  static final List<(Offset, Offset)> _lines = [
    (const Offset(36, 58), const Offset(68, 58)),
    (const Offset(36, 70), const Offset(62, 70)),
    (const Offset(36, 82), const Offset(50, 82)),
  ];

  @override
  void paint(Canvas canvas, KitSceneFrame frame) {
    final p = frame.palette;
    final t = frame.entrance;
    StatesParts.wash(canvas, frame);

    // The sheet behind: another page, quieter.
    StatesParts.outlined(
      canvas,
      _backPath,
      KitDraw.interval(t, .05, .45),
      fill: p.surface,
      pen: KitDraw.pen(p.line, KitDraw.hairline),
    );
    StatesParts.outlined(
      canvas,
      _frontPath,
      KitDraw.interval(t, .12, .6),
      fill: p.surface,
      pen: KitDraw.pen(p.muted),
    );
    KitDraw.partialPath(
      canvas,
      _frontFold,
      KitDraw.interval(t, .5, .65),
      KitDraw.pen(p.muted),
    );
    final linePen = KitDraw.pen(p.line, 4);
    for (final (index, (from, to)) in _lines.indexed) {
      final draw = KitDraw.interval(t, .5 + index * .08, .66 + index * .08);
      if (draw > 0) {
        canvas.drawLine(from, Offset.lerp(from, to, draw)!, linePen);
      }
    }
    // The block caret where the next words go (the chat's own caret).
    final caret = KitDraw.interval(t, .78, .92);
    if (caret > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(55, 88 - 13 * caret, 62, 88),
          const Radius.circular(1.5),
        ),
        KitDraw.fill(p.accent),
      );
    }
    final pop = KitDraw.interval(t, .8, 1, KitMotion.land);
    StatesParts.spark(canvas, const Offset(100, 38), 8, pop, p.accent);
    canvas.drawCircle(
      const Offset(90, 100),
      2.6 * pop.clamp(0, 1),
      KitDraw.fill(KitDraw.fade(p.accent, .55)),
    );
  }
}

/// An open folder with a spark rising out of it: a place with nothing in
/// it yet. Used for "no project yet" and an empty folder.
class StatesFolderScene extends KitScene {
  const StatesFolderScene();

  static final Path _back = Path()
    ..moveTo(20, 92)
    ..lineTo(20, 42)
    ..arcToPoint(const Offset(26, 36), radius: const Radius.circular(6))
    ..lineTo(44, 36)
    ..lineTo(51, 44)
    ..lineTo(88, 44)
    ..arcToPoint(const Offset(94, 50), radius: const Radius.circular(6))
    ..lineTo(94, 58);

  static final Path _front = Path()
    ..moveTo(31, 58)
    ..lineTo(100, 58)
    ..quadraticBezierTo(104, 58, 103, 62)
    ..lineTo(96, 92)
    ..quadraticBezierTo(95, 96, 91, 96)
    ..lineTo(24, 96)
    ..quadraticBezierTo(19, 96, 20, 91)
    ..lineTo(27, 62)
    ..quadraticBezierTo(28, 58, 31, 58)
    ..close();

  @override
  void paint(Canvas canvas, KitSceneFrame frame) {
    final p = frame.palette;
    final t = frame.entrance;
    StatesParts.wash(canvas, frame, center: const Offset(60, 64));

    KitDraw.partialPath(
      canvas,
      _back,
      KitDraw.interval(t, .05, .5),
      KitDraw.pen(p.muted),
    );
    // Inside the folder: a quiet sheet edge, nothing on it.
    final inside = KitDraw.interval(t, .35, .6);
    if (inside > 0) {
      canvas.drawLine(
        const Offset(32, 52),
        Offset(32 + 48 * inside, 52),
        KitDraw.pen(p.line, KitDraw.hairline),
      );
    }
    StatesParts.outlined(
      canvas,
      _front,
      KitDraw.interval(t, .25, .75),
      fill: p.surface,
      pen: KitDraw.pen(p.muted),
    );
    // The spark rises out of the folder and settles above it.
    final rise = KitDraw.interval(t, .65, 1, KitMotion.land);
    if (rise > 0) {
      final y = 58 - 34 * rise;
      StatesParts.spark(canvas, Offset(64, y), 9, rise.clamp(0, 1.2), p.accent);
      canvas.drawCircle(
        Offset(80, y + 10),
        2.6 * rise.clamp(0, 1),
        KitDraw.fill(KitDraw.fade(p.accent, .55)),
      );
      canvas.drawCircle(
        Offset(50, y + 16),
        2 * rise.clamp(0, 1),
        KitDraw.fill(KitDraw.fade(p.accent, .35)),
      );
    }
  }
}

/// An inbox tray: the last sheet settles into it and a check draws itself
/// on top. Used for "all caught up".
class StatesTrayScene extends KitScene {
  const StatesTrayScene();

  static const _sheet = Rect.fromLTRB(36, 26, 84, 80);
  static final Path _sheetPath = StatesParts.sheet(_sheet, fold: 12);
  static final Path _check = Path()
    ..moveTo(49, 47)
    ..lineTo(57, 55)
    ..lineTo(72, 39);

  static final Path _tray = Path()
    ..moveTo(18, 70)
    ..lineTo(40, 70)
    ..quadraticBezierTo(43, 70, 44, 73)
    ..lineTo(46, 77)
    ..quadraticBezierTo(47, 80, 50, 80)
    ..lineTo(70, 80)
    ..quadraticBezierTo(73, 80, 74, 77)
    ..lineTo(76, 73)
    ..quadraticBezierTo(77, 70, 80, 70)
    ..lineTo(102, 70)
    ..lineTo(102, 92)
    ..arcToPoint(const Offset(94, 100), radius: const Radius.circular(8))
    ..lineTo(26, 100)
    ..arcToPoint(const Offset(18, 92), radius: const Radius.circular(8))
    ..close();

  static final Path _rim = Path()
    ..moveTo(18, 70)
    ..lineTo(26, 54)
    ..moveTo(102, 70)
    ..lineTo(94, 54);

  @override
  void paint(Canvas canvas, KitSceneFrame frame) {
    final p = frame.palette;
    final t = frame.entrance;
    StatesParts.wash(canvas, frame, center: const Offset(60, 64));

    // The tray's back rim, behind the sheet.
    KitDraw.partialPath(
      canvas,
      _rim,
      KitDraw.interval(t, .05, .35),
      KitDraw.pen(p.muted),
    );

    // The sheet drops in from above and settles with a small give.
    final drop = KitDraw.interval(t, .2, .7, KitMotion.land);
    if (drop > 0) {
      canvas.save();
      canvas.translate(0, -34 * (1 - drop));
      final appear = drop.clamp(0.0, 1.0);
      canvas.drawPath(
        _sheetPath,
        KitDraw.fill(KitDraw.fade(p.surface, appear)),
      );
      canvas.drawPath(
        _sheetPath,
        KitDraw.pen(KitDraw.fade(p.muted, appear), KitDraw.hairline + 1),
      );
      KitDraw.partialPath(
        canvas,
        _check,
        KitDraw.interval(t, .7, .95),
        KitDraw.pen(p.accent, 6),
      );
      canvas.restore();
    }

    StatesParts.outlined(
      canvas,
      _tray,
      KitDraw.interval(t, .05, .5),
      fill: p.surface,
      pen: KitDraw.pen(p.muted),
    );
  }
}

/// A magnifier over a sheet, its lens resting on a blank part of the page:
/// looked, found nothing. Used for a search that found no match.
class StatesSearchScene extends KitScene {
  const StatesSearchScene();

  static const _sheet = Rect.fromLTRB(22, 22, 72, 86);
  static final Path _sheetPath = StatesParts.sheet(_sheet, fold: 12);
  static final Path _sheetFold = StatesParts.fold(_sheet, fold: 12);
  static const _lens = Offset(70, 64);
  static const _lensRadius = 21.0;

  @override
  void paint(Canvas canvas, KitSceneFrame frame) {
    final p = frame.palette;
    final t = frame.entrance;
    StatesParts.wash(canvas, frame);

    StatesParts.outlined(
      canvas,
      _sheetPath,
      KitDraw.interval(t, .05, .45),
      fill: p.surface,
      pen: KitDraw.pen(p.muted, KitDraw.hairline + 1),
    );
    KitDraw.partialPath(
      canvas,
      _sheetFold,
      KitDraw.interval(t, .35, .5),
      KitDraw.pen(p.muted, KitDraw.hairline + 1),
    );
    final lines = KitDraw.interval(t, .3, .55);
    if (lines > 0) {
      final pen = KitDraw.pen(p.line, 4);
      canvas.drawLine(const Offset(31, 46), Offset(31 + 22 * lines, 46), pen);
      canvas.drawLine(const Offset(31, 57), Offset(31 + 14 * lines, 57), pen);
    }

    // The magnifier slides in a little and lands over the sheet.
    final land = KitDraw.interval(t, .35, .85, KitMotion.land);
    if (land > 0) {
      canvas.save();
      canvas.translate(10 * (1 - land), 10 * (1 - land));
      final appear = land.clamp(0.0, 1.0);
      canvas.drawCircle(
        _lens,
        _lensRadius,
        KitDraw.fill(KitDraw.fade(p.surface, appear)),
      );
      final handleFrom = _lens + const Offset(1, 1) * (_lensRadius * .72);
      canvas.drawLine(
        handleFrom,
        handleFrom + const Offset(15, 15) * appear,
        KitDraw.pen(p.muted, 8),
      );
      canvas.drawCircle(
        _lens,
        _lensRadius,
        KitDraw.pen(KitDraw.fade(p.accent, appear)),
      );
      // A glint on the glass.
      canvas.drawArc(
        Rect.fromCircle(center: _lens, radius: _lensRadius - 7),
        math.pi * 1.1,
        math.pi * .4,
        false,
        KitDraw.pen(KitDraw.fade(p.accent, .45 * appear), KitDraw.hairline),
      );
      canvas.restore();
    }
  }
}

/// A terminal window with a `>_` prompt. Its cursor blinks twice as it
/// arrives and then rests lit; [ended] draws the prompt and cursor dim, the
/// way a terminal looks when its shell is gone.
///
/// With `ambient` (only where the person waits for the shell), the cursor
/// keeps blinking.
class StatesTerminalScene extends KitScene {
  const StatesTerminalScene({this.ended = false});

  /// The shell has ended: no live cursor.
  final bool ended;

  static const _window = Rect.fromLTRB(14, 26, 106, 96);
  static final Path _windowPath = Path()
    ..addRRect(RRect.fromRectAndRadius(_window, const Radius.circular(10)));
  static final Path _prompt = Path()
    ..moveTo(28, 56)
    ..lineTo(38, 64)
    ..lineTo(28, 72);

  @override
  bool differs(covariant StatesTerminalScene old) =>
      super.differs(old) || old.ended != ended;

  @override
  void paint(Canvas canvas, KitSceneFrame frame) {
    final p = frame.palette;
    final t = frame.entrance;
    StatesParts.wash(canvas, frame);

    StatesParts.outlined(
      canvas,
      _windowPath,
      KitDraw.interval(t, .05, .5),
      fill: p.surface,
      pen: KitDraw.pen(p.muted),
    );
    // The title bar: a hairline and three dots.
    final bar = KitDraw.interval(t, .3, .55);
    if (bar > 0) {
      canvas.drawLine(
        Offset(_window.left, 41),
        Offset(_window.left + _window.width * bar, 41),
        KitDraw.pen(p.line, KitDraw.hairline),
      );
      for (var i = 0; i < 3; i++) {
        canvas.drawCircle(
          Offset(24 + i * 8.0, 33.5),
          2.3 * bar,
          KitDraw.fill(p.line),
        );
      }
    }
    final promptColor = ended ? p.muted : p.accent;
    KitDraw.partialPath(
      canvas,
      _prompt,
      KitDraw.interval(t, .45, .7),
      KitDraw.pen(promptColor),
    );
    if (ended) {
      // No live cursor: a dim one where the prompt was.
      final rest = KitDraw.interval(t, .65, .9);
      if (rest > 0) {
        canvas.drawLine(
          const Offset(47, 72),
          Offset(47 + 14 * rest, 72),
          KitDraw.pen(p.line),
        );
      }
      return;
    }
    // The cursor: arrives, blinks twice, then rests lit. While waiting it
    // keeps blinking, slowly.
    final arrived = t >= .7;
    final blink = frame.looping
        ? (frame.loop * 4) % 1 < .5
        : !(t > .78 && t < .84) && !(t > .9 && t < .96);
    if (arrived && blink) {
      canvas.drawLine(
        const Offset(47, 72),
        const Offset(61, 72),
        KitDraw.pen(p.accent),
      );
    }
  }
}

/// A plug pulled out of its socket, with a small spark in the gap: the
/// server is not answering, the phone is offline, or something could not
/// load over the connection.
class StatesUnpluggedScene extends KitScene {
  const StatesUnpluggedScene();

  static final Path _leftCable = Path()
    ..moveTo(0, 74)
    ..cubicTo(10, 74, 12, 62, 22, 62);
  static final Path _rightCable = Path()
    ..moveTo(98, 58)
    ..cubicTo(106, 58, 108, 52, 118, 52);
  static final Path _plug = Path()
    ..addRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(22, 49, 44, 75),
        const Radius.circular(5),
      ),
    );
  static final Path _socket = Path()
    ..addRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(74, 44, 98, 72),
        const Radius.circular(6),
      ),
    );

  @override
  void paint(Canvas canvas, KitSceneFrame frame) {
    final p = frame.palette;
    final t = frame.entrance;
    StatesParts.wash(canvas, frame);
    // Drawn a size up around the middle, so the plug and socket carry the
    // scene like the other drawings' main shapes.
    canvas.save();
    canvas.translate(60, 60);
    canvas.scale(1.2);
    canvas.translate(-60, -60);

    final cablePen = KitDraw.pen(p.muted);
    KitDraw.partialPath(
      canvas,
      _leftCable,
      KitDraw.interval(t, 0, .4),
      cablePen,
    );
    KitDraw.partialPath(
      canvas,
      _rightCable,
      KitDraw.interval(t, .05, .45),
      cablePen,
    );

    // The socket, fixed; its two holes.
    StatesParts.outlined(
      canvas,
      _socket,
      KitDraw.interval(t, .25, .6),
      fill: p.surface,
      pen: KitDraw.pen(p.muted),
    );
    final holes = KitDraw.interval(t, .5, .65);
    if (holes > 0) {
      for (final y in [53.0, 63.0]) {
        canvas.drawLine(
          Offset(80, y),
          Offset(80 + 6 * holes, y),
          KitDraw.pen(p.line, 4),
        );
      }
    }

    // The plug eases back from the socket with a small give.
    final pull = KitDraw.interval(t, .35, .85, KitMotion.land);
    canvas.save();
    canvas.translate(10 * (1 - pull), 0);
    StatesParts.outlined(
      canvas,
      _plug,
      KitDraw.interval(t, .2, .55),
      fill: p.surface,
      pen: KitDraw.pen(p.muted),
    );
    final prongs = KitDraw.interval(t, .45, .6);
    if (prongs > 0) {
      for (final y in [56.0, 68.0]) {
        canvas.drawLine(
          Offset(44, y),
          Offset(44 + 8 * prongs, y),
          KitDraw.pen(p.muted, 4),
        );
      }
    }
    canvas.restore();

    // The gap: a small spark and a few short strokes.
    final gap = KitDraw.interval(t, .75, 1, KitMotion.land);
    StatesParts.ticks(
      canvas,
      const Offset(63, 61),
      const [-118, -90, -62],
      11,
      18,
      gap.clamp(0, 1),
      KitDraw.pen(p.accent, 4),
    );
    canvas.restore();
  }
}
