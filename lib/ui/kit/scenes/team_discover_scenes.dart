import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../kit_illustration.dart';
import '../kit_motion.dart';
import 'team_scenes.dart';

/// The AI Team's two discovery drawings (design standard §10), in the
/// team's line-drawn cast ([TeamCast]):
///
/// - [TeamDiscoverTeaserScene]: the Work tab's small entry while the team is
///   off — three agents, the one in front holding up a task card.
/// - [TeamDiscoverRelayScene]: the intro's hero — a task card travels from
///   the planner through the worker to the reviewer and lands with a check:
///   plan, work, check, merge, in one line.
///
/// Both are resting drawings: the entrance plays once, nothing loops.

/// Three agents, the one in front (accent) holding up a task card. Small:
/// it leads a row on the Work tab.
class TeamDiscoverTeaserScene extends KitScene {
  const TeamDiscoverTeaserScene();

  @override
  Size get box => const Size(90, 60);

  static const _lead = Offset(45, 58);
  static const _left = Offset(19, 58);
  static const _right = Offset(71, 58);

  @override
  void paint(Canvas canvas, KitSceneFrame frame) {
    final p = frame.palette;
    final t = frame.entrance;

    // The two teammates first, then the one in front.
    for (final (base, begin, look) in [
      (_left, 0.0, const Offset(.8, -.7)),
      (_right, .12, const Offset(-.8, -.7)),
    ]) {
      final rise = KitDraw.interval(t, begin, begin + .45, KitMotion.land);
      TeamCast.agent(
        canvas,
        p,
        TeamAgentPose(
          base: base + Offset(0, 10 * (1 - rise)),
          scale: .8,
          show: KitDraw.interval(t, begin, begin + .3),
          eyes: KitDraw.interval(t, .6, .85),
          look: look,
        ),
      );
    }

    final lift = KitDraw.interval(t, .45, .85, KitMotion.land);
    final rise = KitDraw.interval(t, .2, .6, KitMotion.land);
    final base = _lead + Offset(0, 10 * (1 - rise));
    TeamCast.agent(
      canvas,
      p,
      TeamAgentPose(
        base: base,
        scale: .9,
        show: KitDraw.interval(t, .2, .45),
        eyes: KitDraw.interval(t, .7, .95),
        look: const Offset(0, -1),
        lead: true,
        leftHand: lift > 0 ? base + Offset(-8, -20 - 14 * lift) : null,
        rightHand: lift > 0 ? base + Offset(8, -20 - 14 * lift) : null,
      ),
    );
    // The task it holds up: the one thing that matters.
    TeamCast.card(
      canvas,
      p,
      centre: Offset(_lead.dx, 11 + 8 * (1 - lift)),
      width: 22,
      height: 15,
      scale: lift,
      opacity: KitDraw.interval(t, .45, .6),
    );
  }
}

/// The intro's hero: a task card goes from the planner (left) through the
/// worker (middle) to the reviewer (right) along a dotted route, lighting
/// each stop as it passes, and lands with a check and a few sparks. The
/// finished frame keeps the route, the lit stops and the checked card, so
/// it reads still.
class TeamDiscoverRelayScene extends KitScene {
  const TeamDiscoverRelayScene();

  @override
  Size get box => const Size(200, 112);

  /// The relay shows progress along a line (LAY-8): it mirrors under RTL
  /// so the card still travels from the start edge.
  @override
  bool get mirrorsInRtl => true;

  static const _ground = 110.0;
  static const _agents = [
    Offset(40, _ground),
    Offset(100, _ground),
    Offset(160, _ground),
  ];

  /// Where the card rests above each agent: the three stops.
  static const _stops = [Offset(40, 48), Offset(100, 30), Offset(160, 48)];

  static final Path _route = Path()
    ..moveTo(_stops[0].dx, _stops[0].dy)
    ..quadraticBezierTo(70, 20, _stops[1].dx, _stops[1].dy)
    ..quadraticBezierTo(130, 20, _stops[2].dx, _stops[2].dy);

  static final ui.PathMetric _metric = _route.computeMetrics().first;

  /// The dots of the route, measured once.
  static final List<Offset> _dots = [
    for (var d = 9.0; d < _metric.length - 6; d += 9)
      _metric.getTangentForOffset(d)!.position,
  ];

  /// Where each stop sits along the route (0..1).
  static const _stopAt = [0.0, .5, 1.0];

  static final Path _check = Path()
    ..moveTo(-5, 0)
    ..lineTo(-1.5, 3.5)
    ..lineTo(5.5, -4);

  @override
  void paint(Canvas canvas, KitSceneFrame frame) {
    final p = frame.palette;
    final t = frame.entrance;

    // The route draws itself in, dot by dot.
    final route = KitDraw.interval(t, .1, .45, KitMotion.steady);
    if (route > 0) {
      final dot = KitDraw.fill(p.line);
      final shown = (_dots.length * route).ceil();
      for (final at in _dots.take(shown)) {
        canvas.drawCircle(at, 1.6, dot);
      }
    }

    // The card travels the route; each stop lights as it arrives.
    final travel = KitDraw.interval(t, .45, .85, KitMotion.emphasized);
    for (final (i, stop) in _stops.indexed) {
      final lit = travel >= _stopAt[i] && t >= .45;
      final appear = KitDraw.interval(t, .1 + i * .1, .3 + i * .1);
      if (appear <= 0) continue;
      canvas.drawCircle(
        stop,
        3.6,
        lit
            ? KitDraw.fill(KitDraw.fade(p.accent, appear))
            : KitDraw.pen(KitDraw.fade(p.line, appear), KitDraw.hairline),
      );
    }

    final arrive = KitDraw.interval(t, .3, .45, KitMotion.land);
    final at = _metric.getTangentForOffset(_metric.length * travel)!.position;
    final done = KitDraw.interval(t, .82, 1);
    TeamCast.card(
      canvas,
      p,
      centre: at,
      width: 30,
      height: 21,
      lines: done > 0 ? 1 : 2,
      scale: arrive,
      opacity: KitDraw.interval(t, .3, .4),
    );
    if (done > 0) {
      canvas.save();
      canvas.translate(at.dx + 6, at.dy + 2);
      KitDraw.partialPath(
        canvas,
        _check,
        done,
        KitDraw.pen(p.success, KitDraw.stroke * .7),
      );
      canvas.restore();
      final burst = KitDraw.interval(t, .88, 1, KitMotion.land);
      for (var i = 0; i < 5; i++) {
        final angle = -math.pi / 2 + (i - 2) * .55;
        TeamCast.spark(
          canvas,
          KitDraw.fade(i.isEven ? p.accent : p.success, burst.clamp(0, 1)),
          centre: at,
          angle: angle,
          radius: 16 + 6 * burst,
          length: i.isEven ? 5 : 3.5,
        );
      }
    }

    // The team, arriving one by one and watching the card go by.
    for (final (i, base) in _agents.indexed) {
      final begin = i * .1;
      final rise = KitDraw.interval(t, begin, begin + .4, KitMotion.land);
      final dx = (at.dx - base.dx) / 60;
      final holding = i == 0 && travel <= 0;
      TeamCast.agent(
        canvas,
        p,
        TeamAgentPose(
          base: base + Offset(0, 14 * (1 - rise)),
          show: KitDraw.interval(t, begin, begin + .3),
          eyes: KitDraw.interval(t, .3 + begin, .5 + begin),
          look: Offset(dx.clamp(-1, 1), -.9),
          // The middle one works: the accent, the thing that matters.
          lead: i == 1,
          joy: i == 2 && done >= .6,
          rightHand: holding && arrive > 0
              ? TeamCast.hand(base, 1, 1, arrive)
              : null,
          leftHand: i == 2 && done > 0
              ? TeamCast.hand(base, 1, -1, done)
              : null,
        ),
      );
    }
  }
}
