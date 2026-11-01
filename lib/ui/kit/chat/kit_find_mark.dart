// KitFindMark (chat-2, new part; coordinator contract pending): the one look
// a find-in-conversation hit has, in prose, in the pinned excerpt and in
// code — the accent at a low alpha behind the letters, stronger for the
// active hit (the same wash KitCodeBlock.fill draws for its marks).
//
// It paints only a background: the letters keep their role colour, opaque
// (LOOK-14), so a hit never costs contrast. Hosts (transcript_highlight.dart)
// own the search engine and the match counting; the kit owns the look.
//
// States: passive (every hit), active (the hit the find bar is on).
import 'package:flutter/widgets.dart';

import '../kit_tokens.dart';

/// The find-in-conversation mark as a span style (KitMarkdown's
/// `highlighter`, the transcript excerpt): only a background wash, never a
/// text colour, weight or size, so it merges into whatever role the span
/// already has.
abstract final class KitFindMark {
  /// The wash behind every hit.
  static const double passiveAlpha = .18;

  /// The wash behind the hit the find bar is on.
  static const double activeAlpha = .38;

  /// The span style for a hit here; [active] for the current one.
  static TextStyle style(BuildContext context, {bool active = false}) {
    final roles = KitTokens.of(context).roles;
    return TextStyle(
      backgroundColor: roles.accent.withValues(
        alpha: active ? activeAlpha : passiveAlpha,
      ),
    );
  }
}
