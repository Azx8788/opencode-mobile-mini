import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'kit_motion.dart';
import 'kit_text.dart';
import 'kit_tokens.dart';

/// How big the home-screen widget is drawn: about 1x1, 2x2 or 4x2 launcher
/// cells (the three layouts the launcher picks from its size).
enum KitWidgetPreviewSize { compact, card, list }

/// How the widget's ground is drawn.
enum KitWidgetPreviewBackground { solid, tinted, transparent }

/// A small picture of a home-screen widget in the style being chosen: the
/// ground (solid, tinted or see-through, over a sample wallpaper), the accent
/// colour and the layout. It shows sample conversations in plain words, never
/// the person's own, so it is safe on any screen.
///
/// It is a drawing in the app's own parts, not the launcher's render. A
/// change of ground, accent or size eases over [KitMotion.standard]; under
/// reduced motion it changes at once.
///
/// States: none — it draws a fixed sample and never waits.
class KitWidgetPreview extends StatelessWidget {
  const KitWidgetPreview({
    super.key,
    required this.size,
    required this.background,
    required this.accent,
  });

  final KitWidgetPreviewSize size;
  final KitWidgetPreviewBackground background;

  /// The accent the widget's buttons and progress take.
  final Color accent;

  static Size _extent(KitWidgetPreviewSize size, double maxWidth) =>
      switch (size) {
        KitWidgetPreviewSize.compact => const Size(112, 112),
        KitWidgetPreviewSize.card => const Size(212, 168),
        KitWidgetPreviewSize.list => Size(maxWidth.clamp(0, 320), 132),
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final roles = tokens.roles;
    final reduced = KitMotion.reduced(context);
    final duration = reduced ? Duration.zero : KitMotion.standard;
    return Semantics(
      label: l10n.widgetV2PreviewLabel,
      container: true,
      child: ExcludeSemantics(
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.2,
          child: LayoutBuilder(
            builder: (context, box) {
              final extent = _extent(size, box.maxWidth);
              return Center(
                child: AnimatedContainer(
                  duration: duration,
                  curve: KitMotion.enter,
                  width: extent.width,
                  height: extent.height + tokens.space6,
                  padding: EdgeInsets.all(tokens.space3),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(tokens.sheetRadius),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [roles.surface3, roles.surface1],
                    ),
                  ),
                  child: TweenAnimationBuilder<Color?>(
                    tween: ColorTween(end: accent),
                    duration: duration,
                    curve: KitMotion.enter,
                    builder: (context, value, _) => _WidgetBody(
                      size: size,
                      background: background,
                      accent: value ?? accent,
                      duration: duration,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _WidgetBody extends StatelessWidget {
  const _WidgetBody({
    required this.size,
    required this.background,
    required this.accent,
    required this.duration,
  });

  final KitWidgetPreviewSize size;
  final KitWidgetPreviewBackground background;
  final Color accent;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final roles = tokens.roles;
    final fill = switch (background) {
      KitWidgetPreviewBackground.solid => roles.surface1,
      KitWidgetPreviewBackground.tinted => Color.lerp(
        roles.surface1,
        accent,
        .16,
      )!,
      KitWidgetPreviewBackground.transparent => roles.surface1.withValues(
        alpha: 0,
      ),
    };
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: KitMotion.enter,
      switchOutCurve: KitMotion.exit,
      child: AnimatedContainer(
        key: ValueKey(size),
        duration: duration,
        curve: KitMotion.enter,
        padding: EdgeInsets.all(tokens.space3),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(tokens.cardRadius),
        ),
        child: switch (size) {
          KitWidgetPreviewSize.compact => _Compact(accent: accent),
          KitWidgetPreviewSize.card => _Card(accent: accent),
          KitWidgetPreviewSize.list => _ListRows(accent: accent),
        },
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot(this.color);
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: SizedBox.square(dimension: KitTokens.of(context).space3),
  );
}

class _Compact extends StatelessWidget {
  const _Compact({required this.accent});
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final roles = KitTokens.of(context).roles;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _Dot(roles.success),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            KitText(
              '2',
              role: KitTextRole.title,
              tone: KitTextTone.primary,
              tabular: true,
            ),
            KitText(
              l10n.widgetV2PreviewWorking,
              role: KitTextRole.caption,
              tone: KitTextTone.secondary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.color, required this.fraction});
  final Color color;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final roles = KitTokens.of(context).roles;
    return ClipRRect(
      borderRadius: BorderRadius.circular(KitTokens.of(context).markRadius),
      child: SizedBox(
        height: KitTokens.loadingBarHeight + 1,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: roles.hairline),
            FractionallySizedBox(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: fraction,
              child: ColoredBox(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.accent});
  final String label;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: accent.withValues(alpha: .2),
        borderRadius: BorderRadius.circular(tokens.buttonRadius),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.space3,
          vertical: tokens.space1,
        ),
        child: KitText(
          label,
          role: KitTextRole.caption,
          tone: KitTextTone.primary,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.accent});
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final roles = tokens.roles;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            _Dot(roles.success),
            SizedBox(width: tokens.space2),
            Expanded(
              child: KitText(
                l10n.widgetV2PreviewTitle,
                role: KitTextRole.label,
                tone: KitTextTone.primary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        KitText(
          l10n.widgetV2PreviewStep,
          role: KitTextRole.caption,
          tone: KitTextTone.secondary,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        _Bar(color: accent, fraction: .6),
        Row(
          children: [
            Flexible(
              child: _Chip(label: l10n.widgetV2PreviewStop, accent: accent),
            ),
            SizedBox(width: tokens.space2),
            Flexible(
              child: _Chip(label: l10n.widgetV2PreviewSteer, accent: accent),
            ),
          ],
        ),
      ],
    );
  }
}

class _ListRows extends StatelessWidget {
  const _ListRows({required this.accent});
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final roles = tokens.roles;
    Widget row(Color mark, String title, String action) => Row(
      children: [
        _Dot(mark),
        SizedBox(width: tokens.space2),
        Expanded(
          child: KitText(
            title,
            role: KitTextRole.caption,
            tone: KitTextTone.primary,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        SizedBox(width: tokens.space2),
        _Chip(label: action, accent: accent),
      ],
    );
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row(roles.success, l10n.widgetV2PreviewTitle, l10n.widgetV2PreviewStop),
        row(
          roles.attention,
          l10n.widgetV2PreviewSecond,
          l10n.widgetV2PreviewAllow,
        ),
      ],
    );
  }
}
