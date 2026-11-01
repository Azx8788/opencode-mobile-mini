// KitIcon (docs/ux-system/kit-api/KitIcon.md, wave 1, tier 1a): the one way
// to draw a glyph. It replaces every `Icon(` and `AppGlyph(` outside the
// kit, so there is one icon vocabulary (AppIconography, AppIcons) and one
// size scale (VL §7: 20/22/24, s/m/l).
//
// `AppGlyph` and `AppBrandMark` moved here unchanged (R12: moved, not
// duplicated; KIT-43) from `lib/ui/app_iconography.dart`, which now
// re-exports them so every existing import keeps compiling.
//
// [KitIcon.status] draws a status in its own glyph and tone from the kit's
// one status map, [KitTokens.glyphFor] and [KitTokens.toneFor] (README.md
// decision D12), the same map KitStatusMark reads.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../domain/mark_catalog.dart';
import '../app_theme.dart';
import 'kit_text.dart';
import 'kit_tokens.dart';

/// The three designed sizes (VL §7, LOOK-33; s/m/l per cut review C02).
enum KitIconSize {
  /// 20: inline beside secondary text, a row's tile, a fold chevron.
  small,

  /// 22: a confirmation's mark, a card header.
  medium,

  /// 24: an icon-only control, navigation ([AppIconography.actionSize]).
  large;

  /// The size in logical pixels: 20, 22 or 24. No other value exists
  /// (LOOK-33; "No sizes other than 20, 22 and 24").
  double get logical => switch (this) {
    KitIconSize.small => 20,
    KitIconSize.medium => 22,
    KitIconSize.large => 24,
  };
}

/// The duotone navigation glyphs' quiet background layer, keyed by the
/// selected glyph's code point. Moved unchanged from `app_iconography.dart`
/// (KIT-43); [AppGlyph] below still reads it directly, and [KitIcon] reads
/// it through [_backgroundOf].
const _duotoneBackgrounds = <int, IconData>{
  0xe17f: IconData(
    0xe17e,
    fontFamily: 'AppPhosphorDuotone',
    matchTextDirection: false,
  ),
  0xe25b: IconData(
    0xe25a,
    fontFamily: 'AppPhosphorDuotone',
    matchTextDirection: false,
  ),
  0xe0d1: IconData(
    0xe0d0,
    fontFamily: 'AppPhosphorDuotone',
    matchTextDirection: false,
  ),
};

IconData? _backgroundOf(IconData icon) =>
    icon.fontFamily == 'AppPhosphorDuotone'
    ? _duotoneBackgrounds[icon.codePoint]
    : null;

/// KitIcon is the one way to draw a glyph (kit-v2.md §9, KitIcon.md).
///
/// It takes a glyph from the app's named Phosphor set ([AppIconography],
/// with verbs in [AppIcons]) and draws it at one of three designed sizes
/// ([KitIconSize]), in an opaque colour role, aligned to whole physical
/// pixels, decorative by default.
///
/// States: none — loading, empty, error and working belong to the host.
///
/// A disabled icon is the host passing `tone: KitTextTone.tertiary` (no
/// opacity, LOOK-14); [KitIcon.status] covers neutral, progress, ok,
/// attention and failure; a duotone glyph (the navigation `…Selected`
/// glyphs) is selected, drawn automatically when [icon] has a registered
/// background layer.
///
/// Motion and haptics: none (LOOK-33, R23; a rotating chevron is
/// `KitSpin.chevron`, a glyph swap is `KitSwap`).
class KitIcon extends StatelessWidget {
  /// [icon] must come from the app's set: an [AppIconography] glyph or an
  /// [AppIcons] verb. A debug assert rejects any other font family, for
  /// example Material's `Icons.*`.
  const KitIcon(
    IconData this._icon, {
    super.key,
    this.size = KitIconSize.large,
    this.tone,
    this.growsWithText = false,
    this.semanticsLabel,
  }) : _status = null,
       _mark = null;

  /// A bundled brand mark (an agent's or provider's logo,
  /// `assets/marks/<slug>.svg`) in one flat colour, in the place of a glyph:
  /// the same designed [size], tone and pixel snapping as any [KitIcon]. The
  /// artwork fills its 24-unit box edge to edge, so it is inset 8% to weigh
  /// like the Phosphor glyphs beside it. Decorative: the row or chip that
  /// shows it already names the agent.
  const KitIcon.mark(
    String slug, {
    super.key,
    this.size = KitIconSize.small,
    this.tone,
    this.growsWithText = false,
  }) : _icon = null,
       _status = null,
       _mark = slug,
       semanticsLabel = null;

  /// An icon that says a status: [KitTokens.glyphFor] in
  /// [KitTokens.toneFor] (README.md decision D12), so each status has its
  /// own shape as well as its tone. [icon] replaces the glyph only where a
  /// condition has its own (a status line's "offline" cloud); the tone
  /// still comes from [status].
  const KitIcon.status(
    AppStatusTone status, {
    super.key,
    IconData? icon,
    this.size = KitIconSize.small,
    this.growsWithText = true,
    this.semanticsLabel,
  }) : _icon = icon,
       tone = null,
       _mark = null,
       _status = status;

  /// Must come from [AppIconography] or [AppIcons] (a debug assert checks
  /// the font family). On [KitIcon.status] without an explicit glyph, the
  /// status's own ([KitTokens.glyphFor]).
  IconData get icon => _icon ?? KitTokens.glyphFor(_status!);

  final IconData? _icon;

  /// The bundled mark's slug on [KitIcon.mark]; null for a glyph.
  final String? _mark;

  final KitIconSize size;

  /// Null: the ambient icon colour the enclosing kit part set
  /// ([IconTheme.of]), else `text1`. Always null on [KitIcon.status], which
  /// sets its own tone from the status.
  final KitTextTone? tone;

  final AppStatusTone? _status;

  /// Leading and state icons only (LOOK-33, B16 interim): with this true,
  /// the icon grows with the person's text size up to `KitTokens.maxIconScale`
  /// (1.5), rounded to a whole physical pixel. Without it, the size is
  /// exactly 20, 22 or 24 whatever the text scale.
  final bool growsWithText;

  /// Null: decorative, excluded from semantics (A11Y-1: the control or row
  /// beside it carries the words). Use this only for a standalone
  /// informative glyph.
  final String? semanticsLabel;

  Color _resolveColor(BuildContext context, ThemeRoles roles) {
    final status = _status;
    if (status != null) return KitTokens.toneColor(roles, status);
    final explicit = tone;
    if (explicit != null) return KitText.toneColor(roles, explicit);
    // The ambient colour is made opaque: a translucent one (a Material
    // disabled IconTheme, for example) would draw the glyph at partial
    // opacity, which LOOK-14 forbids. A disabled icon is the host passing
    // `tone: KitTextTone.tertiary`.
    final ambient = IconTheme.of(context).color;
    return ambient?.withValues(alpha: 1) ??
        KitText.toneColor(roles, KitTextTone.primary);
  }

  double _resolveDimension(BuildContext context) {
    final logical = size.logical;
    if (!growsWithText) return logical;
    final grown = KitTokens.of(context).iconSize(context, logical);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return dpr > 0 ? (grown * dpr).round() / dpr : grown;
  }

  @override
  Widget build(BuildContext context) {
    final mark = _mark;
    if (mark != null) return _buildMark(context, mark);
    final icon = this.icon;
    assert(
      icon.fontFamily != null && icon.fontFamily!.startsWith('AppPhosphor'),
      'KitIcon: "$icon" is not from AppIconography/AppIcons (font family '
      '${icon.fontFamily}). Material glyphs (Icons.*) never reach KitIcon '
      '(KitIcon.md "Replaces"): map the glyph to an AppIconography verb.',
    );
    final roles = ThemeRoles.resolve(Theme.of(context));
    final color = _resolveColor(context, roles);
    final dimension = _resolveDimension(context);
    final background = _backgroundOf(icon);
    // A fresh IconTheme, not a merge: the framework Icon multiplies its
    // colour by the ambient `opacity` and inherits the ambient shadows,
    // fill, weight and text scaling. KitIcon pins them, so the glyph is
    // always opaque, unshadowed and exactly [dimension] (LOOK-14, VL §7).
    final glyph = ExcludeSemantics(
      child: IconTheme(
        data: IconThemeData(
          color: color,
          size: dimension,
          opacity: 1,
          shadows: const [],
          fill: 0,
          weight: 400,
          grade: 0,
          opticalSize: 48,
          applyTextScaling: false,
        ),
        child: background == null || MediaQuery.highContrastOf(context)
            ? Icon(icon, size: dimension, color: color)
            : Stack(
                alignment: Alignment.center,
                children: [
                  Opacity(
                    opacity: KitTokens.duotoneWash,
                    child: Icon(background, size: dimension, color: color),
                  ),
                  Icon(icon, size: dimension, color: color),
                ],
              ),
      ),
    );
    final label = semanticsLabel;
    return _KitPixelSnap(
      child: label == null
          ? glyph
          : Semantics(label: label, image: true, child: glyph),
    );
  }
}

extension on KitIcon {
  Widget _buildMark(BuildContext context, String slug) {
    final roles = ThemeRoles.resolve(Theme.of(context));
    final color = _resolveColor(context, roles);
    final dimension = _resolveDimension(context);
    return _KitPixelSnap(
      child: ExcludeSemantics(
        child: SizedBox.square(
          dimension: dimension,
          child: Center(
            child: SizedBox.square(
              dimension: dimension * 0.84,
              child: SvgPicture.asset(
                markAssetPath(slug),
                fit: BoxFit.contain,
                colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
                errorBuilder: (context, error, stack) =>
                    const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints [child] with its origin on a whole physical pixel (VL §7: icons
/// "aligned to whole pixels"; a half-pixel offset is a bug). Layout is
/// untouched, so a KitIcon never moves its neighbours: at paint time the
/// child is shifted by less than one physical pixel, from wherever the
/// layout put it to the nearest pixel corner. With a whole-pixel size (every
/// designed size at DPR 3, and every grown size), all four edges are then
/// whole pixels. The shift is part of the paint transform, so hit testing,
/// semantics and `localToGlobal` see the painted position.
class _KitPixelSnap extends SingleChildRenderObjectWidget {
  const _KitPixelSnap({required super.child});

  @override
  _RenderKitPixelSnap createRenderObject(BuildContext context) =>
      _RenderKitPixelSnap(MediaQuery.devicePixelRatioOf(context));

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderKitPixelSnap renderObject,
  ) {
    renderObject.devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
  }
}

class _RenderKitPixelSnap extends RenderProxyBox {
  _RenderKitPixelSnap(this._devicePixelRatio);

  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  /// The local shift that puts this box's origin on the nearest whole
  /// physical pixel of the view.
  Offset get _snap {
    final dpr = _devicePixelRatio;
    if (!attached || !hasSize || dpr <= 0) return Offset.zero;
    final toGlobal = getTransformTo(null);
    final origin = MatrixUtils.transformPoint(toGlobal, Offset.zero);
    final snapped = Offset(
      (origin.dx * dpr).roundToDouble() / dpr,
      (origin.dy * dpr).roundToDouble() / dpr,
    );
    if (snapped == origin) return Offset.zero;
    final toLocal = Matrix4.tryInvert(toGlobal);
    return toLocal == null
        ? Offset.zero
        : MatrixUtils.transformPoint(toLocal, snapped);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child != null) context.paintChild(child, offset + _snap);
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final snap = _snap;
    transform.translateByDouble(snap.dx, snap.dy, 0, 1);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintOffset(
      offset: _snap,
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }
}

/// The two sizes of [KitBrandMark] (KitIcon.md): the row leading tile, and
/// a standalone mark.
enum KitBrandMarkSize { tile, mark }

/// The open-portal mark (the retired [AppBrandMark]'s job). Decorative
/// unless labelled. It is drawn from `assets/branding/open-portal/mark.svg`
/// in the accent, with its origin on a whole physical pixel.
///
/// States: none — a static decorative mark.
class KitBrandMark extends StatelessWidget {
  const KitBrandMark({
    super.key,
    this.size = KitBrandMarkSize.tile,
    this.semanticsLabel,
  });

  final KitBrandMarkSize size;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final dimension = size == KitBrandMarkSize.tile
        ? tokens.iconTileSize
        : tokens.markSize;
    final mark = SvgPicture.asset(
      'assets/branding/open-portal/mark.svg',
      width: dimension,
      height: dimension,
      colorFilter: ColorFilter.mode(tokens.roles.accent, BlendMode.srcIn),
      excludeFromSemantics: true,
    );
    final label = semanticsLabel;
    return _KitPixelSnap(
      child: label == null
          ? mark
          : Semantics(label: label, image: true, child: mark),
    );
  }
}

/// Retired by kit-KitIcon: use [KitIcon].
///
/// Renders regular and duotone glyphs with one optional accessibility label.
///
/// This is decoration, not a tap target: place it inside an IconButton or other
/// accessible control. Let that control's tooltip or visible text name the
/// action; use [semanticLabel] only for a standalone informative glyph.
class AppGlyph extends StatelessWidget {
  const AppGlyph(
    this.icon, {
    super.key,
    this.size,
    this.color,
    this.semanticLabel,
    this.textDirection,
  });

  final IconData icon;
  final double? size;
  final Color? color;
  final String? semanticLabel;

  /// Pass an explicit direction for technical marks that must not mirror.
  /// Navigation arrows follow the surrounding direction by default; technical
  /// glyph data preserves its orientation.
  final TextDirection? textDirection;

  @override
  Widget build(BuildContext context) {
    final foreground = Icon(
      icon,
      size: size,
      color: color,
      textDirection: textDirection,
    );
    final secondary = _backgroundOf(icon);
    final glyph = ExcludeSemantics(
      child: secondary == null || MediaQuery.highContrastOf(context)
          ? foreground
          : Stack(
              alignment: Alignment.center,
              children: [
                Opacity(
                  opacity: .2,
                  child: Icon(
                    secondary,
                    size: size,
                    color: color,
                    textDirection: textDirection,
                  ),
                ),
                foreground,
              ],
            ),
    );
    final label = semanticLabel;
    return label == null
        ? glyph
        : Semantics(label: label, image: true, child: glyph);
  }
}

/// Retired by kit-KitIcon: use [KitBrandMark].
///
/// The open portal identity without a launcher background or shadow.
///
/// Decorative by default. A standalone mark may supply [semanticLabel]; a
/// neighboring app title already communicates the identity and needs no label.
class AppBrandMark extends StatelessWidget {
  const AppBrandMark({super.key, this.size = 32, this.semanticLabel});

  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final mark = SvgPicture.asset(
      'assets/branding/open-portal/mark.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(
        Theme.of(context).colorScheme.primary,
        BlendMode.srcIn,
      ),
      excludeFromSemantics: true,
    );
    final label = semanticLabel;
    return label == null
        ? mark
        : Semantics(label: label, image: true, child: mark);
  }
}
