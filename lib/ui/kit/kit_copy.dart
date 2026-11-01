import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
import 'kit_redact.dart';
import 'motion/kit_haptics.dart';

/// The one way the app copies text: confirmed by a light tick and
/// a single screen-reader announcement. Never a SnackBar — the control that
/// copied shows its own brief "copied" state if it wants one.
abstract final class KitCopy {
  /// Copies [text] to the clipboard, masking secrets with [KitRedact.text]
  /// when [redact] is true, then announces [announcement] (default: "Copied")
  /// once.
  ///
  /// [redact] defaults to true for technical values, logs, diagnostics and
  /// report previews. Code blocks and message text should pass false to copy
  /// verbatim, preserving their original content (including registered secrets).
  /// Register loaded provider keys and server passwords with
  /// [KitRedact.registerKnownSecret] so default copies also mask opaque values.
  /// Tests that register values must call [KitRedact.clearKnownSecrets].
  static Future<void> copy(
    BuildContext context,
    String text, {
    String? announcement,
    bool redact = true,
  }) async {
    final safe = redact ? KitRedact.text(text) : text;
    final message =
        announcement ??
        lookupAppLocalizations(Localizations.localeOf(context)).kitCopied;
    final view = View.of(context);
    final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
    KitHaptics.send(context);
    await Clipboard.setData(ClipboardData(text: safe));
    await SemanticsService.sendAnnouncement(view, message, direction);
  }
}
