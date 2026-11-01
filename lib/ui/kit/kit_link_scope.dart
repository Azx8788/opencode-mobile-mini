import 'package:flutter/widgets.dart';

import '../widgets/external_link.dart';

/// Lets a screen take a tapped link before it goes out to the browser.
///
/// A conversation wraps its transcript in a [KitLinkScope] whose [claim]
/// answers "is this link mine?". Local dev-server links (`localhost:5173`)
/// are the only thing claimed today: they open the in-app preview. Anything
/// not claimed goes through [openExternalLink] exactly as before (SEC-1), so
/// the scope can only add a safer, narrower way to open a link, never skip
/// the gate for an address that is not the phone's own or the server's.
class KitLinkScope extends InheritedWidget {
  const KitLinkScope({super.key, required this.claim, required super.child});

  /// Returns true when it handled [url] (opened its own view); false to let
  /// the link continue to [openExternalLink].
  final bool Function(BuildContext context, String url) claim;

  static KitLinkScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<KitLinkScope>();

  @override
  bool updateShouldNotify(KitLinkScope oldWidget) => claim != oldWidget.claim;

  /// What a tapped link does: the nearest scope may claim it, otherwise it
  /// is opened through [openExternalLink].
  static Future<void> open(BuildContext context, String url) async {
    final scope = maybeOf(context);
    if (scope != null && scope.claim(context, url)) return;
    await openExternalLink(context, url);
  }
}
