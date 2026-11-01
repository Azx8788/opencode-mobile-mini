import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'kit_chip.dart';
import 'kit_motion.dart';
import 'motion/kit_reveal.dart';
import 'kit_tokens.dart';

/// The agent's task list as one small chip in the line above the field,
/// beside the approval and model chips (owner decision 14 Oct: no level of
/// its own above the input). It shows a progress ring and "5/6", never a
/// task's words, so it cannot crowd the model chip. A tap opens the list
/// (the host shows [showKitTaskSheet]).
///
/// It is there while the list has unfinished tasks. When a task completes it
/// pops for [popFor]: an accent tint, a slight scale bump, the ring moving
/// to the new share, and "✓ 5/6" before it settles back to "5/6". A task
/// added to the list does the same with "+ 5/7". When the last task
/// completes it reads "✓ 6/6" for [allDoneFor], then fades and shrinks
/// away; a new list with unfinished tasks brings it back. A list that is
/// already finished when the chip first appears shows nothing.
///
/// Reduced motion: no scale and no tint, only the text changes.
/// Semantics: "Tasks, 5 of 6 done, now" and the task in progress, announced
/// politely when it changes.
///
/// States: none — its four looks (resting, popped for a task done or added,
/// all done, hidden) follow the task counts it is given.
class KitTaskChip extends StatefulWidget {
  const KitTaskChip({
    super.key,
    required this.done,
    required this.total,
    required this.onPressed,
    this.current,
    this.popFor = defaultPopFor,
    this.allDoneFor = defaultAllDoneFor,
  });

  /// Tasks finished, out of [total] tracked (cancelled ones are not).
  final int done;
  final int total;

  /// The task in progress, for the screen reader only.
  final String? current;

  /// Opens the list.
  final VoidCallback onPressed;

  /// How long a change shows before the chip settles.
  static const defaultPopFor = Duration(milliseconds: 1500);

  /// How long "✓ 6/6" stays once everything is done.
  static const defaultAllDoneFor = Duration(seconds: 3);

  /// The two times above; only the catalog gives others (to hold a state
  /// still for a screenshot).
  final Duration popFor;
  final Duration allDoneFor;

  @override
  State<KitTaskChip> createState() => _KitTaskChipState();
}

enum _Pop { done, added }

class _KitTaskChipState extends State<KitTaskChip> {
  late bool _visible;
  _Pop? _pop;
  Timer? _popTimer;
  Timer? _doneTimer;

  bool _finished(int done, int total) => total > 0 && done >= total;

  @override
  void initState() {
    super.initState();
    // A list already finished when we first see it is not news.
    _visible = widget.total > 0 && !_finished(widget.done, widget.total);
  }

  @override
  void didUpdateWidget(KitTaskChip old) {
    super.didUpdateWidget(old);
    if (old.done == widget.done && old.total == widget.total) return;
    final total = widget.total;
    if (total <= 0) {
      _clear();
      _visible = false;
      return;
    }
    final finished = _finished(widget.done, total);
    final wasFinished = _finished(old.done, old.total);
    _Pop? pop;
    if (old.total > 0 && total > old.total) {
      pop = _Pop.added;
    } else if (old.total > 0 && widget.done > old.done) {
      pop = _Pop.done;
    }
    _doneTimer?.cancel();
    if (!finished) {
      _visible = true;
    } else if (!wasFinished) {
      _visible = true;
      _doneTimer = Timer(widget.allDoneFor, () {
        if (mounted) setState(() => _visible = false);
      });
    }
    _popTimer?.cancel();
    _pop = pop;
    if (pop != null) {
      _popTimer = Timer(widget.popFor, () {
        if (mounted) setState(() => _pop = null);
      });
    }
  }

  void _clear() {
    _popTimer?.cancel();
    _doneTimer?.cancel();
    _pop = null;
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final reduced = KitMotion.reduced(context);
    final duration = reduced ? Duration.zero : KitMotion.standard;
    final done = widget.done;
    final total = widget.total;
    final allDone = _finished(done, total);
    final text = allDone
        ? l10n.kitTaskChipDone(done, total)
        : switch (_pop) {
            _Pop.done => l10n.kitTaskChipDone(done, total),
            _Pop.added => l10n.kitTaskChipAdded(done, total),
            null => l10n.kitTaskChipCount(done, total),
          };
    final current = widget.current?.trim();
    final spoken = current == null || current.isEmpty || allDone
        ? l10n.kitTaskChipSpoken(done, total)
        : l10n.kitTaskChipSpokenNow(done, total, current);
    final lit = !reduced && (_pop != null || allDone);
    final fraction = total <= 0 ? 0.0 : (done / total).clamp(0.0, 1.0);

    final chip = AnimatedScale(
      scale: lit && _pop != null ? 1.06 : 1,
      duration: reduced ? Duration.zero : KitMotion.quick,
      curve: KitMotion.enter,
      child: KitChip.action(
        key: const Key('task-chip'),
        label: text,
        spoken: spoken,
        liveRegion: true,
        tone: lit ? KitChipTone.active : KitChipTone.neutral,
        glyph: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: fraction),
          duration: duration,
          curve: KitMotion.enter,
          builder: (context, value, _) => CustomPaint(
            painter: _RingPainter(
              fraction: value,
              color: KitTokens.of(context).roles.accent,
              stroke: 2,
            ),
          ),
        ),
        onPressed: widget.onPressed,
      ),
    );

    // It folds away (and back) as one part: fade and fold, instant under
    // reduced motion. The first build shows what is there, so a chip that
    // opens with the conversation does not animate in.
    return KitReveal(child: _visible ? chip : null);
  }
}

/// A ring: a muted track and an arc from 12 o'clock, clockwise.
class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.fraction,
    required this.color,
    required this.stroke,
  });

  final double fraction;
  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height) - stroke * 2;
    final rect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: side,
      height: side,
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      paint..color = color.withValues(alpha: .25),
    );
    if (fraction > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2 * fraction,
        false,
        paint..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction || old.color != color || old.stroke != stroke;
}
