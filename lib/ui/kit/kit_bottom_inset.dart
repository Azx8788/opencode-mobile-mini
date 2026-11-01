import 'package:flutter/widgets.dart';

/// What a floating part must stay clear of, in logical dp measured from the
/// window's edges (docs/ux-system/kit-api/KitBottomInset.md; K2 §2.12,
/// LAY-6): the dock, a pinned primary, the composer, the keyboard, the
/// system gesture inset, and the navigation rail at the start.
@immutable
class KitClearance {
  const KitClearance({this.bottom = 0, this.start = 0});

  /// From the window's bottom edge: system gesture inset, keyboard, dock,
  /// pinned primary, composer — whatever is published below this point.
  final double bottom;

  /// From the window's start edge: the navigation rail or sidebar.
  final double start;

  KitClearance copyWith({double? bottom, double? start}) =>
      KitClearance(bottom: bottom ?? this.bottom, start: start ?? this.start);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is KitClearance && other.bottom == bottom && other.start == start);

  @override
  int get hashCode => Object.hash(bottom, start);

  @override
  String toString() => 'KitClearance(bottom: $bottom, start: $start)';
}

/// The one answer to "how much of the bottom (and start) of this subtree is
/// covered by something pinned or floating" (KitBottomInset.md; K2 §1.17,
/// §2.12; LAY-6). Floating parts ([KitUndo] and, later, `KitJumpPill`) and
/// `KitScreen.endPadding` read this instead of measuring the dock, a pinned
/// primary or the composer by hand.
///
/// Publishers are kit parts only: `KitNav` (the dock height and the rail or
/// sidebar width), `KitScreen` (its pinned bottom block and the keyboard)
/// and the chat composer (`kit/chat`, `KitComposer`); none of those have
/// merged when kit-KitUndo builds, so there is no publisher in the tree
/// today outside this unit's own tests.
///
/// States: none — it draws nothing (KIT-12 does not apply; exempt from the
/// gallery manifest, reason "draws nothing").
class KitBottomInset extends InheritedWidget {
  const KitBottomInset({super.key, required this.insets, required super.child});

  final KitClearance insets;

  /// Publishes the inherited [insets] plus [extraBottom] (a pinned block the
  /// caller measured itself) and, when given, a new [start]; never double
  /// counts, since [extraBottom] is only what the caller pins on top of
  /// whatever already reaches this point.
  ///
  /// This is the seam that also keeps the invariant "while a publisher is in
  /// the tree, `MediaQuery.padding.bottom` seen by its subtree equals its
  /// published bottom minus the keyboard" (so an unmigrated scroll view that
  /// still reads `MediaQuery` padding by hand keeps clearing the dock, the
  /// way `Scaffold(extendBody: true)` does today).
  static Widget add({
    Key? key,
    required double extraBottom,
    double? start,
    required Widget child,
  }) => _KitBottomInsetAdd(
    key: key,
    extraBottom: extraBottom,
    start: start,
    child: child,
  );

  /// The nearest published insets; registers a dependency so the caller
  /// rebuilds when it changes. With no publisher above: `bottom` =
  /// `MediaQuery.paddingOf(context).bottom + MediaQuery.viewInsetsOf(context).bottom`,
  /// `start` = 0.
  static KitClearance of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<KitBottomInset>()?.insets ??
      _fallback(context);

  /// The same as [of] without registering a dependency: a one-time read at
  /// show time (`showKitUndo`).
  static KitClearance read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<KitBottomInset>()?.insets ??
      _fallback(context);

  /// Null when nothing above publishes (tests and assertions only).
  static KitBottomInset? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<KitBottomInset>();

  static KitClearance _fallback(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    if (media == null) return const KitClearance();
    return KitClearance(
      bottom: _roundToPhysicalPixel(
        context,
        media.padding.bottom + media.viewInsets.bottom,
      ),
    );
  }

  @override
  bool updateShouldNotify(KitBottomInset oldWidget) =>
      insets != oldWidget.insets;
}

/// Rounds [value] to whole physical pixels at the current device pixel
/// ratio (the invariant every publisher and [KitBottomInset.add] honours;
/// VL §7).
double _roundToPhysicalPixel(BuildContext context, double value) {
  final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
  if (dpr <= 0) return value;
  return (value * dpr).roundToDouble() / dpr;
}

/// The widget behind [KitBottomInset.add]: reads the ambient insets and
/// `MediaQuery`, publishes the combined [KitClearance], and rewrites the
/// subtree's `MediaQuery.padding.bottom` so legacy code that has not moved
/// to [KitBottomInset.of] still clears the dock.
class _KitBottomInsetAdd extends StatelessWidget {
  const _KitBottomInsetAdd({
    super.key,
    required this.extraBottom,
    required this.start,
    required this.child,
  });

  final double extraBottom;
  final double? start;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final parent = KitBottomInset.of(context);
    final media = MediaQuery.of(context);
    final bottom = _roundToPhysicalPixel(context, parent.bottom + extraBottom);
    final legacyBottom = (bottom - media.viewInsets.bottom).clamp(
      0.0,
      double.infinity,
    );
    return KitBottomInset(
      insets: KitClearance(bottom: bottom, start: start ?? parent.start),
      child: MediaQuery(
        data: media.copyWith(
          padding: media.padding.copyWith(bottom: legacyBottom),
        ),
        child: child,
      ),
    );
  }
}
