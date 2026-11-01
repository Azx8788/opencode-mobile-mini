import "package:flutter/widgets.dart";

import 'kit_motion.dart';

/// A part that comes and goes without a jump: it fades while its slot opens along the row, and leaves the same way
/// ([KitMotion.quick], [KitMotion.enter], no bounce). Once gone it builds
/// nothing at all, so a hidden part is not in the tree, not focusable and
/// not read out.
///
/// A [KitPresence] first built with `show: true` is simply there; only a
/// change of [show] plays. Keep the same widget (or key) in place across
/// the change so the state survives. Under reduced motion
/// ([KitMotion.reduced]) the change is instant.
///
/// States: none — it only shows or hides its child.
class KitPresence extends StatefulWidget {
  const KitPresence({
    super.key,
    required this.show,
    required this.child,
    this.axis = Axis.horizontal,
  });

  final bool show;
  final Widget child;

  /// The direction the slot opens along: horizontal in a row of buttons.
  final Axis axis;

  @override
  State<KitPresence> createState() => _KitPresenceState();
}

class _KitPresenceState extends State<KitPresence> {
  /// The child to keep drawing while the part leaves (the caller may have
  /// already replaced it with something else).
  late Widget _last = widget.child;

  @override
  Widget build(BuildContext context) {
    if (widget.show) _last = widget.child;
    final reduced = KitMotion.reduced(context);
    final horizontal = widget.axis == Axis.horizontal;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: widget.show ? 1 : 0),
      duration: reduced ? Duration.zero : KitMotion.quick,
      curve: KitMotion.enter,
      builder: (context, t, child) {
        if (t == 0 && !widget.show) return const SizedBox.shrink();
        final body = Align(
          widthFactor: horizontal ? t : 1,
          heightFactor: horizontal ? 1 : t,
          child: Opacity(opacity: t, child: child),
        );
        // Clipped only while the slot is opening; at rest nothing is cut.
        return t == 1 ? body : ClipRect(child: body);
      },
      child: _last,
    );
  }
}
