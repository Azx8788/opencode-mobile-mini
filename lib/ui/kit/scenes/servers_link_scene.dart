import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../kit_illustration.dart';
import 'servers_cast.dart';
import '../kit_motion.dart';

/// Where a server connection stands, as the link drawing shows it.
enum ServersLinkState {
  /// Nothing tried yet: the phone and the computer, a dotted gap between.
  idle,

  /// Pairing or checking the connection: the link draws itself across and,
  /// while waiting, a dot travels from the phone to the computer.
  linking,

  /// The computer answered: the link is solid and a spark lands on it.
  linked,

  /// Nothing answered: the link is broken in the middle.
  failed,
}

/// This phone and a computer linking up (Add server, design standard §10):
/// the pairing and connection-check moment. The phone is on the left, the
/// laptop on the right with the portal on its screen, and the link between
/// them says the [state].
///
/// Each state has its own entrance ([KitIllustration] is keyed by state):
/// [ServersLinkState.idle] draws the two devices in; the others keep the
/// devices and draw only the link, so a check that starts or finishes never
/// redraws the whole picture. Ambient (only while [ServersLinkState.linking])
/// a dot travels the link.
class ServersLinkScene extends KitScene {
  const ServersLinkScene(this.state, {this.intro = true});

  final ServersLinkState state;

  /// The idle drawing's entrance draws the two devices in. False once the
  /// link has moved (a check was cancelled by an edit): the devices stay,
  /// only the dotted gap comes back.
  final bool intro;

  @override
  Size get box => const Size(200, 84);

  /// The phone-to-computer link shows progress along a line (LAY-8): it
  /// mirrors under RTL so the link still runs from the start edge.
  @override
  bool get mirrorsInRtl => true;

  @override
  bool differs(covariant ServersLinkScene old) =>
      super.differs(old) || old.state != state || old.intro != intro;

  static final _phone = ServersPhone(const Rect.fromLTRB(26, 18, 54, 66));
  static final _laptop = ServersLaptop(const Rect.fromLTRB(112, 16, 168, 56));
  static const _portal = Offset(140, 36);

  static const _from = Offset(62, 42);
  static const _to = Offset(104, 38);
  static final Path _link = Path()
    ..moveTo(_from.dx, _from.dy)
    ..quadraticBezierTo(83, 20, _to.dx, _to.dy);
  static final ui.PathMetric _metric = _link.computeMetrics().first;

  /// The link's two halves with a gap in the middle (the failed state).
  static final Path _left = _metric.extractPath(0, _metric.length * .4);
  static final Path _right = _metric.extractPath(
    _metric.length * .6,
    _metric.length,
  );
  static final Offset _middle = _metric
      .getTangentForOffset(_metric.length / 2)!
      .position;
  static final Offset _leftEnd = _metric
      .getTangentForOffset(_metric.length * .4)!
      .position;
  static final Offset _rightEnd = _metric
      .getTangentForOffset(_metric.length * .6)!
      .position;

  /// The idle gap: dots along the link, precomputed.
  static final List<Offset> _dots = [
    for (var d = 0.0; d <= _metric.length; d += 7)
      _metric.getTangentForOffset(d)!.position,
  ];

  @override
  void paint(Canvas canvas, KitSceneFrame frame) {
    final palette = frame.palette;
    final t = frame.entrance;
    final first = state == ServersLinkState.idle && intro;

    // The devices: drawn in on the idle entrance, already there after.
    _phone.paint(
      canvas,
      palette,
      first ? KitDraw.interval(t, 0, .55) : 1,
      screen: state == ServersLinkState.linked ? palette.accent : null,
    );
    _laptop.paint(canvas, palette, first ? KitDraw.interval(t, .12, .65) : 1);
    if (state == ServersLinkState.linked) {
      // The computer lights up as the link lands.
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          _laptop.screen.deflate(4),
          const Radius.circular(3),
        ),
        KitDraw.fill(
          KitDraw.fade(palette.accentSoft, KitDraw.interval(t, .3, .8)),
        ),
      );
    }
    ServersPortal.paint(
      canvas,
      _portal,
      22,
      state == ServersLinkState.failed ? palette.muted : palette.accent,
      first ? KitDraw.interval(t, .45, .9) : 1,
    );

    switch (state) {
      case ServersLinkState.idle:
        final show = KitDraw.interval(t, intro ? .7 : 0, 1);
        final dot = KitDraw.fill(KitDraw.fade(palette.line, show));
        for (final p in _dots) {
          canvas.drawCircle(p, 1.6, dot);
        }
      case ServersLinkState.linking:
        // A wash under the link, then the link itself drawing across.
        final draw = KitDraw.interval(t, 0, .8);
        KitDraw.partialPath(
          canvas,
          _link,
          draw,
          KitDraw.pen(palette.accentSoft, 9),
        );
        KitDraw.partialPath(
          canvas,
          _link,
          draw,
          KitDraw.pen(palette.accent, KitDraw.hairline),
        );
        if (frame.looping) {
          // A dot travelling phone → computer, fading at both ends.
          final along = frame.loop;
          final at = _metric.getTangentForOffset(_metric.length * along)!;
          final fade = along < .15
              ? along / .15
              : along > .85
              ? (1 - along) / .15
              : 1.0;
          canvas.drawCircle(
            at.position,
            4,
            KitDraw.fill(KitDraw.fade(palette.accent, fade)),
          );
        } else {
          // Still frame (tests, reduced motion): the dot rests midway.
          final land = KitDraw.interval(t, .6, 1);
          if (land > 0) {
            canvas.drawCircle(_middle, 4 * land, KitDraw.fill(palette.accent));
          }
        }
      case ServersLinkState.linked:
        KitDraw.partialPath(
          canvas,
          _link,
          KitDraw.interval(t, 0, .35),
          KitDraw.pen(palette.accent, 4),
        );
        final land = KitDraw.interval(t, .25, .7, KitMotion.land);
        if (land > 0) {
          canvas.drawCircle(_middle, 6.5 * land, KitDraw.fill(palette.accent));
          canvas.drawCircle(
            _middle,
            11 * land,
            KitDraw.pen(palette.accentSoft, 3),
          );
        }
        // The spark: rays thrown out once, settling as short ticks that stay
        // in the finished frame.
        final throw_ = KitDraw.interval(t, .35, 1, KitMotion.land);
        if (throw_ > 0) {
          final pen = KitDraw.pen(
            KitDraw.fade(palette.accent, .85),
            KitDraw.hairline,
          );
          for (var i = 0; i < 5; i++) {
            // A fan above the link: -150° .. -30°.
            final a = -math.pi * (5 / 6) + i * math.pi * (1 / 6);
            final d = Offset(math.cos(a), math.sin(a));
            final start = 13 + 3 * throw_;
            canvas.drawLine(
              _middle + d * start,
              _middle + d * (start + 5 * throw_),
              pen,
            );
          }
        }
      case ServersLinkState.failed:
        final draw = KitDraw.interval(t, 0, .5);
        final apart = KitDraw.interval(t, .35, 1) * 2.5;
        final pen = KitDraw.pen(palette.muted, KitDraw.hairline + .5);
        canvas.save();
        canvas.translate(-apart, apart * .4);
        KitDraw.partialPath(canvas, _left, draw, pen);
        canvas.restore();
        canvas.save();
        canvas.translate(apart, apart * .4);
        KitDraw.partialPath(canvas, _right, draw, pen);
        canvas.restore();
        final ends = KitDraw.interval(t, .45, 1);
        if (ends > 0) {
          final end = KitDraw.fill(KitDraw.fade(palette.failure, ends));
          canvas.drawCircle(_leftEnd.translate(-apart, apart * .4), 3.2, end);
          canvas.drawCircle(_rightEnd.translate(apart, apart * .4), 3.2, end);
        }
    }
  }
}
