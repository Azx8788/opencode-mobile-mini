import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../kit_illustration.dart';
import '../kit_motion.dart';

/// The AI Team's drawings (design standard §10, motion spec slice D): a
/// small cast of line-drawn agents — a rounded body, a round head, two dot
/// eyes and nothing more — in the brand's stroke, the family of
/// [KitPortalScene].
///
/// - [TeamBoardScene]: the team gathered at an empty board (no tasks yet).
/// - [TeamPlanningScene]: two agents passing a card while the planner
///   plans (ambient).
/// - [TeamWakingScene]: the team waking up while it starts (ambient).
/// - [TeamMergedScene]: a task merged; the card lands with a check and the
///   agents cheer (a one-time celebration).
/// - [TeamNudgeScene]: an agent peeks over the "Needs you" block and waves
///   once.
/// - [TeamRestScene]: one agent dozing (no agents running).
/// - [TeamIdleScene]: two agents at ease (the Work tab's "Nothing running").

/// How one agent stands in a frame.
@immutable
class TeamAgentPose {
  const TeamAgentPose({
    required this.base,
    this.scale = 1,
    this.draw = 1,
    this.show = 1,
    this.eyes = 1,
    this.look = Offset.zero,
    this.leftHand,
    this.rightHand,
    this.lead = false,
    this.joy = false,
  });

  /// The bottom centre of the body, in scene units.
  final Offset base;
  final double scale;

  /// How much of the outline has drawn itself in (0..1).
  final double draw;

  /// Overall opacity (0..1), for a figure arriving.
  final double show;

  /// 0 closed (a line), 1 open (dots).
  final double eyes;

  /// Where the eyes look, each axis -1..1.
  final Offset look;

  /// Hands in scene units; an arm is drawn from the nearer shoulder. Null
  /// keeps the arm down at the body's side (not drawn).
  final Offset? leftHand;
  final Offset? rightHand;

  /// The agent that matters in the scene: the accent outline and wash.
  final bool lead;

  /// Happy closed eyes (a small arch each) instead of dots.
  final bool joy;
}

/// Draws the cast; every team scene uses it, so the agents are one family.
abstract final class TeamCast {
  static const bodyWidth = 28.0;
  static const bodyHeight = 20.0;
  static const headRadius = 9.0;
  static const _neck = 2.0;

  /// The head's centre above the base, at scale 1.
  static const headLift = bodyHeight + _neck + headRadius;

  /// Where a hand hangs at rest, relative to the base (scale 1).
  static const restHand = Offset(bodyWidth / 2 + 1, -4);

  /// Where a raised hand is, relative to the base (scale 1).
  static const raisedHand = Offset(bodyWidth / 2 + 7, -bodyHeight - 12);

  /// The body: a dome on a flat base, bottom centre at the origin.
  static final Path _body = () {
    const w = bodyWidth / 2, h = bodyHeight, r = 11.0;
    return Path()
      ..moveTo(-w, 0)
      ..lineTo(-w, -h + r)
      ..arcToPoint(const Offset(-w + r, -h), radius: const Radius.circular(r))
      ..lineTo(w - r, -h)
      ..arcToPoint(const Offset(w, -h + r), radius: const Radius.circular(r))
      ..lineTo(w, 0)
      ..close();
  }();

  static final Path _head = Path()
    ..addOval(
      Rect.fromCircle(center: const Offset(0, -headLift), radius: headRadius),
    );

  /// One agent in [pose].
  static void agent(Canvas canvas, KitPalette palette, TeamAgentPose pose) {
    if (pose.show <= 0) return;
    final s = pose.scale;
    final outline = KitDraw.fade(
      pose.lead ? palette.accent : palette.muted,
      pose.show,
    );
    final pen = KitDraw.pen(outline, KitDraw.stroke * .8 / s);
    final hairPen = KitDraw.pen(outline, KitDraw.stroke * .8);

    // Arms first: the body covers where they join the shoulders.
    for (final (hand, side) in [(pose.leftHand, -1.0), (pose.rightHand, 1.0)]) {
      if (hand == null) continue;
      final shoulder =
          pose.base + Offset(side * (bodyWidth / 2 - 4), -bodyHeight + 7) * s;
      canvas.drawLine(shoulder, hand, hairPen);
    }

    canvas.save();
    canvas.translate(pose.base.dx, pose.base.dy);
    canvas.scale(s);
    final fill = KitDraw.fade(palette.surface, pose.show * pose.draw);
    canvas.drawPath(_body, KitDraw.fill(fill));
    canvas.drawPath(_head, KitDraw.fill(fill));
    if (pose.lead) {
      final wash = KitDraw.fill(
        KitDraw.fade(palette.accentSoft, pose.show * pose.draw),
      );
      canvas.drawPath(_body, wash);
      canvas.drawPath(_head, wash);
    }
    KitDraw.partialPath(canvas, _body, pose.draw, pen);
    KitDraw.partialPath(canvas, _head, pose.draw, pen);

    if (pose.draw >= .6) {
      final eyeColor = KitDraw.fade(outline, (pose.draw - .6) / .4);
      final look = Offset(
        pose.look.dx.clamp(-1, 1) * 2.2,
        pose.look.dy.clamp(-1, 1) * 1.6,
      );
      final centre = const Offset(0, -headLift + .5) + look;
      for (final side in const [-1.0, 1.0]) {
        final eye = centre + Offset(side * 3.6, 0);
        if (pose.joy) {
          canvas.drawArc(
            Rect.fromCircle(center: eye + const Offset(0, 1.2), radius: 2.2),
            math.pi * 1.1,
            math.pi * .8,
            false,
            KitDraw.pen(eyeColor, 1.6),
          );
        } else {
          final open = pose.eyes.clamp(0.0, 1.0);
          canvas.drawOval(
            Rect.fromCenter(center: eye, width: 3.6, height: .9 + 2.7 * open),
            KitDraw.fill(eyeColor),
          );
        }
      }
    }
    canvas.restore();
  }

  /// The hand between rest and raised on [side] (-1 left, 1 right).
  static Offset hand(Offset base, double scale, double side, double raise) {
    final rest = Offset(side * restHand.dx, restHand.dy);
    final up = Offset(side * raisedHand.dx, raisedHand.dy);
    return base + Offset.lerp(rest, up, raise)! * scale;
  }

  /// A small card (a task) centred at the origin: [width] × [height].
  static void card(
    Canvas canvas,
    KitPalette palette, {
    required Offset centre,
    double width = 18,
    double height = 13,
    double angle = 0,
    double scale = 1,
    double opacity = 1,
    int lines = 2,
  }) {
    if (opacity <= 0 || scale <= 0) return;
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.rotate(angle);
    canvas.scale(scale);
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: width, height: height),
      const Radius.circular(3.5),
    );
    canvas.drawRRect(
      rect,
      KitDraw.fill(KitDraw.fade(palette.surface, opacity)),
    );
    canvas.drawRRect(
      rect,
      KitDraw.fill(KitDraw.fade(palette.accentSoft, opacity)),
    );
    canvas.drawRRect(
      rect,
      KitDraw.pen(KitDraw.fade(palette.accent, opacity), KitDraw.hairline),
    );
    final linePen = KitDraw.pen(
      KitDraw.fade(palette.accent, opacity * .8),
      KitDraw.hairline * .8,
    );
    final gap = height / (lines + 1);
    for (var i = 1; i <= lines; i++) {
      final y = -height / 2 + gap * i;
      final end = i == lines ? width * .1 : width * .28;
      canvas.drawLine(Offset(-width / 2 + 4.5, y), Offset(end, y), linePen);
    }
    canvas.restore();
  }

  /// A short spark stroke pointing away from [centre] at [angle].
  static void spark(
    Canvas canvas,
    Color color, {
    required Offset centre,
    required double angle,
    required double radius,
    double length = 5,
    double width = KitDraw.hairline,
  }) {
    final dir = Offset(math.cos(angle), math.sin(angle));
    canvas.drawLine(
      centre + dir * radius,
      centre + dir * (radius + length),
      KitDraw.pen(color, width),
    );
  }
}

/// No tasks yet: the team gathered at an empty board whose one accent
/// slot waits for a task. Still once drawn (a resting screen).
class TeamBoardScene extends KitScene {
  const TeamBoardScene();

  static final RRect _board = RRect.fromLTRBR(
    18,
    12,
    102,
    74,
    const Radius.circular(10),
  );
  static final Path _boardPath = Path()..addRRect(_board);

  @override
  void paint(Canvas canvas, KitSceneFrame frame) {
    final p = frame.palette;
    final t = frame.entrance;

    KitDraw.partialPath(
      canvas,
      _boardPath,
      KitDraw.interval(t, 0, .45),
      KitDraw.pen(p.muted, KitDraw.stroke * .8),
    );
    // Three columns: their heads and the hairlines between them.
    final columns = KitDraw.interval(t, .25, .6);
    if (columns > 0) {
      final line = KitDraw.pen(KitDraw.fade(p.line, columns), KitDraw.hairline);
      for (final x in const [46.0, 74.0]) {
        canvas.drawLine(Offset(x, 26), Offset(x, 26 + 38 * columns), line);
      }
      final head = KitDraw.pen(
        KitDraw.fade(p.muted, columns),
        KitDraw.hairline,
      );
      for (final x in const [25.0, 53.0, 81.0]) {
        canvas.drawLine(Offset(x, 21), Offset(x + 14 * columns, 21), head);
      }
    }
    // The empty slot a task will fill: the one accent.
    final slot = KitDraw.interval(t, .7, 1, KitMotion.land);
    if (slot > 0) {
      canvas.save();
      canvas.translate(32, 36);
      canvas.scale(slot);
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset.zero, width: 17, height: 13),
        const Radius.circular(3.5),
      );
      canvas.drawRRect(rect, KitDraw.fill(p.accentSoft));
      canvas.drawRRect(rect, KitDraw.pen(p.accent, KitDraw.hairline));
      final plus = KitDraw.pen(p.accent, KitDraw.hairline);
      canvas.drawLine(const Offset(-3, 0), const Offset(3, 0), plus);
      canvas.drawLine(const Offset(0, -3), const Offset(0, 3), plus);
      canvas.restore();
    }

    // The team arrives in front of it, one by one.
    TeamAgentPose pose(
      Offset base,
      double begin,
      double scale,
      Offset look, {
      Offset? rightHand,
    }) {
      final arrive = KitDraw.interval(t, begin, begin + .4);
      final rise = KitDraw.interval(t, begin, begin + .4, KitMotion.land);
      return TeamAgentPose(
        base: base + Offset(0, 14 * (1 - rise)),
        scale: scale,
        show: arrive,
        eyes: KitDraw.interval(t, .8, 1),
        look: look,
        rightHand: rightHand,
      );
    }

    final wave = KitDraw.interval(t, .7, 1, KitMotion.land);
    TeamCast.agent(
      canvas,
      p,
      pose(const Offset(30, 114), .3, 1, const Offset(.7, -.8)),
    );
    TeamCast.agent(
      canvas,
      p,
      pose(
        const Offset(90, 114),
        .5,
        1,
        const Offset(-.8, -.6),
        rightHand: wave > 0
            ? TeamCast.hand(const Offset(90, 114), 1, 1, wave)
            : null,
      ),
    );
    TeamCast.agent(
      canvas,
      p,
      pose(const Offset(60, 118), .4, .9, const Offset(0, -1)),
    );
  }
}

/// The planner planning ("Planning the steps…"): the planner (accent) and
/// a teammate pass a card between them; while waiting it travels from one
/// to the other and back, their eyes following it.
class TeamPlanningScene extends KitScene {
  const TeamPlanningScene();

  @override
  Size get box => const Size(120, 84);

  static const _left = Offset(30, 82);
  static const _right = Offset(90, 82);

  @override
  void paint(Canvas canvas, KitSceneFrame frame) {
    final p = frame.palette;
    final t = frame.entrance;
    // Where the card is between the two (0 left, 1 right); at rest it is
    // held up between them. The loop starts from that same place.
    final pass = frame.looping ? KitDraw.wave(frame.loop, .25) : .5;
    final card = Offset(50 + 20 * pass, 42 - 12 * math.sin(math.pi * pass));

    Offset reach(Offset base, double side, double amount) {
      final shoulder =
          base +
          Offset(side * (TeamCast.bodyWidth / 2 - 4), -TeamCast.bodyHeight + 7);
      final toward = card - shoulder;
      final length = toward.distance;
      final arm = math.min(length - 9, 10 + 8 * amount);
      return shoulder + toward / length * arm;
    }

    Offset look(Offset base) {
      final head = base + const Offset(0, -TeamCast.headLift);
      final d = card - head;
      return d / d.distance;
    }

    final arms = KitDraw.interval(t, .45, .85);
    for (final (base, side, begin, lead, amount) in [
      (_left, 1.0, 0.0, true, 1 - pass),
      (_right, -1.0, .15, false, pass),
    ]) {
      final arrive = KitDraw.interval(t, begin, begin + .45);
      final rise = KitDraw.interval(t, begin, begin + .45, KitMotion.land);
      final hand = arms > 0 ? reach(base, side, amount * arms) : null;
      TeamCast.agent(
        canvas,
        p,
        TeamAgentPose(
          base: base + Offset(0, 12 * (1 - rise)),
          show: arrive,
          lead: lead,
          eyes: KitDraw.interval(t, .5, .8),
          look: look(base),
          leftHand: side < 0 ? hand : null,
          rightHand: side > 0 ? hand : null,
        ),
      );
    }

    final pop = KitDraw.interval(t, .55, 1, KitMotion.land);
    TeamCast.card(
      canvas,
      p,
      centre: card,
      width: 24,
      height: 17,
      angle: (pass - .5) * .5,
      scale: pop,
      opacity: KitDraw.interval(t, .55, .8),
    );
  }
}

/// The team starting: three agents wake (their eyes open) under a spark
/// that powers on; while it starts they breathe in turn and blink.
class TeamWakingScene extends KitScene {
  const TeamWakingScene();

  @override
  Size get box => const Size(140, 92);

  static const _ground = 86.0;
  static const _spark = Offset(70, 14);

  @override
  void paint(Canvas canvas, KitSceneFrame frame) {
    final p = frame.palette;
    final t = frame.entrance;

    final ground = KitDraw.interval(t, 0, .35);
    if (ground > 0) {
      canvas.drawLine(
        Offset(70 - 56 * ground, _ground),
        Offset(70 + 56 * ground, _ground),
        KitDraw.pen(p.line, KitDraw.hairline),
      );
    }

    for (final (i, x, scale) in [
      (0, 36.0, .88),
      (1, 70.0, 1.0),
      (2, 104.0, .88),
    ]) {
      final begin = .1 + .1 * i;
      final bob = frame.looping ? 2.5 * KitDraw.wave(frame.loop, i / 3) : 0.0;
      // A blink each, at its own moment of the breath.
      var eyes = KitDraw.interval(t, .7 + .08 * i, .86 + .08 * i);
      if (frame.looping) {
        final since = (frame.loop - (.2 + i * .3)) % 1;
        if (since < .05) eyes = (since - .025).abs() / .025;
      }
      TeamCast.agent(
        canvas,
        p,
        TeamAgentPose(
          base: Offset(x, _ground - 2.5 - bob),
          scale: scale,
          draw: KitDraw.interval(t, begin, begin + .5),
          eyes: eyes,
          look: Offset(0, -.6 * eyes),
          lead: i == 1,
        ),
      );
    }

    // The spark that wakes them: lands, then its rays breathe.
    final land = KitDraw.interval(t, .65, 1, KitMotion.land);
    if (land > 0) {
      canvas.drawCircle(_spark, 4.5 * land, KitDraw.fill(p.accent));
      final breath = frame.looping ? KitDraw.wave(frame.loop) : 0.0;
      final rays = KitDraw.interval(t, .8, 1);
      for (var i = 0; i < 6; i++) {
        TeamCast.spark(
          canvas,
          KitDraw.fade(p.accent, rays * (.9 - .35 * breath)),
          centre: _spark,
          angle: i * math.pi / 3 - math.pi / 2,
          radius: 7.5 + 1.5 * breath,
          length: 3.5 * rays + 1.5 * breath,
        );
      }
    }
  }
}

/// A task merged: its card drops into place with a check, sparks fly out,
/// and the two agents beside it throw their arms up. Played once; its
/// finished frame keeps the sparks, so it reads as a celebration still.
class TeamMergedScene extends KitScene {
  const TeamMergedScene();

  @override
  Size get box => const Size(160, 100);

  static const _card = Offset(80, 44);
  static const _left = Offset(30, 96);
  static const _right = Offset(130, 96);
  static final Path _check = Path()
    ..moveTo(_card.dx + 3, _card.dy + 1)
    ..lineTo(_card.dx + 7.5, _card.dy + 5.5)
    ..lineTo(_card.dx + 15, _card.dy - 3.5);

  @override
  void paint(Canvas canvas, KitSceneFrame frame) {
    final p = frame.palette;
    final t = frame.entrance;

    // Sparks: thrown out from the card, settling as a ring of short
    // strokes (accent and the success colour alternating).
    final burst = KitDraw.interval(t, .5, 1, KitMotion.land);
    if (burst > 0) {
      for (var i = 0; i < 10; i++) {
        final angle = i * math.pi / 5 - math.pi / 2 + .31;
        final far = i.isEven ? 34.0 : 29.0;
        TeamCast.spark(
          canvas,
          KitDraw.fade(i.isEven ? p.accent : p.success, burst.clamp(0, 1)),
          centre: _card,
          angle: angle,
          radius: 16 + (far - 16) * burst,
          length: i.isEven ? 6 : 4,
        );
      }
    }

    // The card lands with a small overshoot.
    final land = KitDraw.interval(t, .1, .55, KitMotion.land);
    if (land > 0) {
      TeamCast.card(
        canvas,
        p,
        centre: Offset(_card.dx, -20 + (_card.dy + 20) * land),
        width: 40,
        height: 28,
        lines: 3,
        opacity: KitDraw.interval(t, .1, .3),
      );
    }
    KitDraw.partialPath(
      canvas,
      _check,
      KitDraw.interval(t, .5, .75),
      KitDraw.pen(p.success, KitDraw.stroke * .8),
    );

    final cheer = KitDraw.interval(t, .55, .95, KitMotion.land);
    for (final (base, begin, look) in [
      (_left, 0.0, const Offset(.8, -.5)),
      (_right, .12, const Offset(-.8, -.5)),
    ]) {
      final arrive = KitDraw.interval(t, begin, begin + .4);
      final rise = KitDraw.interval(t, begin, begin + .4, KitMotion.land);
      TeamCast.agent(
        canvas,
        p,
        TeamAgentPose(
          base: base + Offset(0, 14 * (1 - rise)),
          show: arrive,
          eyes: KitDraw.interval(t, .35, .6),
          joy: cheer >= .6,
          look: cheer >= .6 ? Offset.zero : look,
          leftHand: cheer > 0 ? TeamCast.hand(base, 1, -1, cheer) : null,
          rightHand: cheer > 0 ? TeamCast.hand(base, 1, 1, cheer) : null,
        ),
      );
    }
  }
}

/// Needs you: an agent (accent) rises over the edge of the block below
/// and waves once. Its bottom edge is the block's top: it peeks over it.
class TeamNudgeScene extends KitScene {
  const TeamNudgeScene();

  @override
  Size get box => const Size(56, 40);

  static const _base = Offset(22, 50);

  @override
  void paint(Canvas canvas, KitSceneFrame frame) {
    final p = frame.palette;
    final t = frame.entrance;
    final rise = KitDraw.interval(t, 0, .45, KitMotion.land);
    final base = _base + Offset(0, 30 * (1 - rise));
    final raise = KitDraw.interval(t, .35, .65, KitMotion.land);
    // One wave: the hand swings twice about its raised place, dying away.
    final waving = KitDraw.interval(t, .55, 1, KitMotion.steady);
    final swing = waving <= 0 || waving >= 1
        ? 0.0
        : .45 * math.sin(waving * 4 * math.pi) * (1 - waving);
    final shoulder =
        base +
        const Offset(TeamCast.bodyWidth / 2 - 4, -TeamCast.bodyHeight + 7);
    final hand = raise > 0
        ? shoulder +
              Offset.fromDirection(
                -math.pi / 2 + .45 - .45 * (1 - raise) * 2 + swing,
                8 + 10 * raise,
              )
        : null;
    TeamCast.agent(
      canvas,
      p,
      TeamAgentPose(
        base: base,
        show: KitDraw.interval(t, 0, .2),
        lead: true,
        eyes: KitDraw.interval(t, .3, .5),
        look: const Offset(.5, -.2),
        rightHand: hand,
      ),
    );
    // Two short marks by the hand: "over here".
    final marks = KitDraw.interval(t, .7, 1);
    if (marks > 0 && hand != null) {
      for (final (angle, length) in [(-1.2, 4.0), (-.45, 3.5)]) {
        TeamCast.spark(
          canvas,
          KitDraw.fade(p.accent, marks),
          centre: hand,
          angle: angle,
          radius: 4.5,
          length: length * marks,
        );
      }
    }
  }
}

/// No agents running: one agent dozing on the ground, with its z's.
class TeamRestScene extends KitScene {
  const TeamRestScene();

  @override
  Size get box => const Size(120, 100);

  static final Path _zs = () {
    Path z(double x, double y, double s) => Path()
      ..moveTo(x, y)
      ..lineTo(x + s, y)
      ..lineTo(x, y + s)
      ..lineTo(x + s, y + s);
    return Path()
      ..addPath(z(70, 44, 7), Offset.zero)
      ..addPath(z(82, 28, 10), Offset.zero);
  }();

  @override
  void paint(Canvas canvas, KitSceneFrame frame) {
    final p = frame.palette;
    final t = frame.entrance;
    final ground = KitDraw.interval(t, 0, .35);
    if (ground > 0) {
      canvas.drawLine(
        Offset(54 - 38 * ground, 92),
        Offset(54 + 38 * ground, 92),
        KitDraw.pen(p.line, KitDraw.hairline),
      );
    }
    TeamCast.agent(
      canvas,
      p,
      TeamAgentPose(
        base: const Offset(50, 89.5),
        draw: KitDraw.interval(t, .1, .7),
        eyes: 0,
        look: const Offset(0, .4),
      ),
    );
    KitDraw.partialPath(
      canvas,
      _zs,
      KitDraw.interval(t, .6, 1),
      KitDraw.pen(p.muted, KitDraw.hairline),
    );
  }
}

/// Nothing running: two agents at ease, turned to each other.
class TeamIdleScene extends KitScene {
  const TeamIdleScene();

  @override
  Size get box => const Size(64, 44);

  @override
  void paint(Canvas canvas, KitSceneFrame frame) {
    final p = frame.palette;
    final t = frame.entrance;
    for (final (x, look, begin) in [
      (18.0, const Offset(.8, 0), 0.0),
      (46.0, const Offset(-.8, 0), .15),
    ]) {
      TeamCast.agent(
        canvas,
        p,
        TeamAgentPose(
          base: Offset(x, 43),
          scale: .95,
          draw: KitDraw.interval(t, begin, begin + .6),
          eyes: KitDraw.interval(t, .6, .9),
          look: look,
        ),
      );
    }
  }
}
