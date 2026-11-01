import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import 'kit_motion.dart';
import 'kit_text.dart';
import 'kit_tokens.dart';

/// Where one step of a list stands. Paused is not a fifth value: see
/// [KitStatusMark.paused] (KitStatusMark.md "Why paused is a flag").
enum KitMarkState { waiting, working, done, failed }

/// A row's leading state mark (design standard §6: "a leading icon or status
/// dot"): a hollow ring waiting, a small spinner working (a still dot under
/// reduced motion), a check done, the neutral error glyph failed, or
/// [AppIconography.pause] when [paused]. Sized to sit in [KitRow]'s leading
/// slot. It is a state, not the screen's progress: the one bar (§4) says how
/// far the whole thing is.
///
/// Every mark carries its word (slice-P9.5: no state shown by colour alone):
/// in semantics always, and beside the mark as visible text when
/// [showLabel].
///
/// A change of state cross-fades the glyph on [KitMotion.quick] and swaps
/// it at once under reduced motion. The glyph grows with text up to
/// [KitTokens.maxIconScale], snapped to whole physical pixels.
///
/// States: waiting, working, done, failed, paused (a waiting or working
/// modifier, never its own value — KitStatusMark.md).
class KitStatusMark extends StatelessWidget {
  const KitStatusMark({
    super.key,
    required this.state,
    this.paused = false,
    this.label,
    this.showLabel = false,
  });

  final KitMarkState state;

  /// A heat pause, or a force stop the app can resume. Only meaningful with
  /// [KitMarkState.waiting] or [KitMarkState.working]; asserted with
  /// [KitMarkState.done] or [KitMarkState.failed] — a finished step cannot
  /// be paused (STATE-11).
  final bool paused;

  /// The word this mark announces and, with [showLabel], shows. Null takes
  /// [wordFor].
  final String? label;

  /// Also draws the word as visible text after the mark, for a place that
  /// does not already show it (outside a [KitRow], whose own supporting
  /// line already carries the word).
  final bool showLabel;

  /// The default word for a state, the same word a [KitRow]'s supporting
  /// line starts with: Waiting · Working · Done · Failed · Paused.
  static String wordFor(
    BuildContext context,
    KitMarkState state, {
    bool paused = false,
  }) {
    assert(
      !paused || state == KitMarkState.waiting || state == KitMarkState.working,
      'KitStatusMark.wordFor: paused only applies to waiting or working',
    );
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    if (paused) return l10n.kitMarkPaused;
    return switch (state) {
      KitMarkState.waiting => l10n.kitMarkWaiting,
      KitMarkState.working => l10n.kitMarkWorking,
      KitMarkState.done => l10n.kitMarkDone,
      KitMarkState.failed => l10n.kitMarkFailed,
    };
  }

  /// LOOK-8: a glyph's floor on `ground` and `surface1`–`surface3`.
  static const double _glyphContrastFloor = 3;

  /// The waiting ring's colour: `text3`, or `text2` in a pack where `text3`
  /// misses [_glyphContrastFloor] on the ground or any surface
  /// (KitStatusMark.md, Accessibility; LOOK-8).
  static Color _ringColor(ThemeRoles roles) {
    final grounds = [
      roles.ground,
      roles.surface1,
      roles.surface2,
      roles.surface3,
    ];
    return grounds.every(
          (g) => contrastRatio(roles.text3, g) >= _glyphContrastFloor,
        )
        ? roles.text3
        : roles.text2;
  }

  @override
  Widget build(BuildContext context) {
    assert(
      !paused || state == KitMarkState.waiting || state == KitMarkState.working,
      'KitStatusMark: paused only applies to waiting or working — a '
      'finished step cannot be paused (G37, STATE-11)',
    );
    final theme = Theme.of(context);
    final roles = AppTheme.rolesOf(theme);
    final tokens = KitTokens.of(context);
    // The system setting and Animations: Off in Settings (KitEffects).
    final reduceMotion = KitMotion.reduced(context);
    final word = label ?? wordFor(context, state, paused: paused);
    // The 20 dp glyph, grown with text up to maxIconScale and snapped to
    // whole physical pixels (LOOK-33).
    final glyphSize = _glyphSize(context, tokens);
    // Done, working and failed take the kit's one status map
    // (KitTokens.glyphFor / toneFor), so a mark and a KitIcon.status of the
    // same state always agree. Waiting's hollow ring is the neutral glyph's
    // shape drawn as a hairline (LOOK-8's ring colour).
    final working = KitTokens.toneColor(roles, AppStatusTone.progress);
    final Widget glyph = paused
        ? Icon(AppIconography.pause, size: glyphSize, color: roles.text2)
        : switch (state) {
            KitMarkState.done => Icon(
              KitTokens.glyphFor(AppStatusTone.ok),
              size: glyphSize,
              color: KitTokens.toneColor(roles, AppStatusTone.ok),
            ),
            KitMarkState.working =>
              reduceMotion
                  ? Icon(
                      AppIconography.statusDot,
                      size: KitTokens.markDotSize,
                      color: working,
                    )
                  // The spec's "small indeterminate ring": the glyph's own
                  // size, and the kit's one spinner stroke.
                  : SizedBox.square(
                      dimension: glyphSize,
                      child: CircularProgressIndicator(
                        strokeWidth: KitTokens.spinnerStroke,
                        color: working,
                      ),
                    ),
            KitMarkState.failed => Icon(
              KitTokens.glyphFor(AppStatusTone.failure),
              size: glyphSize,
              color: KitTokens.toneColor(roles, AppStatusTone.failure),
            ),
            KitMarkState.waiting => Container(
              width: KitTokens.markRingSize,
              height: KitTokens.markRingSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: _ringColor(roles),
                  width: KitTokens.hairlineWidth(context),
                ),
              ),
            ),
          };
    final mark = SizedBox.square(
      dimension: KitTokens.markSlotSize,
      child: Center(
        child: _crossFade(
          context,
          KeyedSubtree(key: ValueKey((state, paused)), child: glyph),
        ),
      ),
    );
    // The word is the one semantics node (STATE-9). With [showLabel] it
    // sits on the visible word alone, so the node's bounds are the text
    // the person reads and the glyph beside it stays decoration.
    if (!showLabel) {
      return Semantics(label: word, excludeSemantics: true, child: mark);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(child: mark),
        SizedBox(width: tokens.labelGap),
        Flexible(
          child: Semantics(
            label: word,
            excludeSemantics: true,
            child: KitText(word, role: KitTextRole.secondary),
          ),
        ),
      ],
    );
  }
}

/// [KitTokens.smallIconSize] grown with the person's text up to
/// [KitTokens.maxIconScale], rounded to whole physical pixels so the glyph
/// never lands between pixels (KitStatusMark.md, Adaptive; LOOK-33).
double _glyphSize(BuildContext context, KitTokens tokens) {
  final scaled = tokens.iconSize(context, tokens.smallIconSize);
  final dpr = MediaQuery.devicePixelRatioOf(context);
  return dpr > 0 ? (scaled * dpr).roundToDouble() / dpr : scaled;
}

/// A state change cross-fades the glyph on [KitMotion.quick], and swaps it
/// at once under reduced motion (KitStatusMark.md, Motion; MOT-7).
Widget _crossFade(BuildContext context, Widget child) => AnimatedSwitcher(
  duration: KitMotion.reduced(context) ? Duration.zero : KitMotion.quick,
  switchInCurve: KitMotion.enter,
  switchOutCurve: KitMotion.exit,
  child: child,
);
