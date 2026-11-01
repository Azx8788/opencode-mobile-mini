// The one scrollbar (docs/ux-system/kit-api/KitScrollbar.md; kit-v2.md
// §8.3, KIT-6). Moved from lib/ui/desktop/desktop_interaction.dart with its
// rule unchanged: always visible and draggable on a desktop where the
// scrollable owns a controller, the platform's fading thumb elsewhere, never
// on a horizontal strip of chips, and never a second thumb over one the
// behaviour already draws. The old names there forward to these.
import 'package:flutter/material.dart';

import '../desktop/desktop_interaction.dart' show desktopInteractions;
import 'kit_layout.dart';

/// App-wide scroll behaviour (moved from `AppScrollBehavior`, unchanged
/// rule): on a desktop, a vertical scrollable that owns a controller gets an
/// always-visible, draggable thumb; everything else keeps the platform's
/// fading one; horizontal strips get none.
///
/// The mouse is deliberately not a drag device: drag-to-scroll with a mouse
/// would take the gesture desktop users select text with. Wheel and trackpad
/// scrolling arrive as pointer signals and pan/zoom events, not drags.
///
/// States: none — a decorative scroll control, not a data part (it looks
/// idle, hovered or dragged).
class KitScrollBehavior extends MaterialScrollBehavior {
  const KitScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (!desktopInteractions ||
        axisDirectionToAxis(details.direction) != Axis.vertical) {
      return super.buildScrollbar(context, child, details);
    }
    return Scrollbar(
      controller: details.controller,
      // RawScrollbar asserts on a visible thumb with no attached position, so
      // only a controller-owning scrollable gets the pinned treatment.
      thumbVisibility: details.controller != null,
      child: child,
    );
  }
}

/// Gives a long scrollable its controller on a desktop, so
/// [KitScrollBehavior] can pin a draggable thumb (moved from
/// `DesktopScrollbarArea`). [builder] gets null off desktop, where the
/// scrollable is built exactly as before, so touch scrolling is unchanged.
///
/// No scrollbar is added here on purpose: the behaviour already builds one
/// around every Scrollable, and a second would draw a second thumb.
///
/// States: none — a decorative scroll control, not a data part (it looks
/// idle, hovered or dragged).
class KitScrollArea extends StatefulWidget {
  const KitScrollArea({super.key, required this.builder});

  final Widget Function(ScrollController? controller) builder;

  @override
  State<KitScrollArea> createState() => _KitScrollAreaState();
}

class _KitScrollAreaState extends State<KitScrollArea> {
  ScrollController? _controller;

  @override
  void initState() {
    super.initState();
    if (desktopInteractions) _controller = ScrollController();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_controller);
}

/// An explicit scrollbar for a box that scrolls inside a page (a code
/// block's sideways scroller, a table): visible and draggable on a fine
/// pointer, the platform's thumb on touch. Wraps its child in
/// [KitOwnScrollbar] so the behaviour does not add a second thumb.
///
/// States: none — a decorative scroll control, not a data part (it looks
/// idle, hovered or dragged).
class KitScrollbar extends StatelessWidget {
  const KitScrollbar({
    super.key,
    required this.controller,
    required this.child,
    this.axis = Axis.vertical,
  });

  /// The box's own controller, also given to its scrollable.
  final ScrollController controller;
  final Widget child;

  /// horizontal: the sideways scroller of a code block, log or table.
  final Axis axis;

  @override
  Widget build(BuildContext context) => Scrollbar(
    controller: controller,
    thumbVisibility: KitLayout.finePointer(context),
    scrollbarOrientation: axis == Axis.horizontal
        ? ScrollbarOrientation.bottom
        : null,
    child: KitOwnScrollbar(child: child),
  );
}

/// Stops [KitScrollBehavior] adding a second thumb inside a subtree that
/// builds its own [KitScrollbar] (moved from `OwnScrollbar`).
///
/// States: none — configuration only, it draws nothing itself.
class KitOwnScrollbar extends StatelessWidget {
  const KitOwnScrollbar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ScrollConfiguration(
    behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
    child: child,
  );
}
