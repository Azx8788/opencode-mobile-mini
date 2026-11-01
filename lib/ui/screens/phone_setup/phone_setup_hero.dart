import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../kit/kit.dart';

/// A setup screen with room for a drawing (design standard §10, "a hero on
/// the few screens with room"): the drawing at the top, then the state's
/// slots in [KitStateView]'s order — title, one line, progress, what it is
/// made of, the actions in the one hierarchy, and the less common ways.
///
/// Unlike a page [KitStateView] it is anchored to the top, so the first
/// thing on the screen is the drawing and never an empty band (design
/// regressions ledger rows 1–2). It scrolls as one, so it fits at 320 dp and
/// at large text. Built from kit parts only (KIT-1): [KitText] roles, the
/// [KitTokens] spacing and [KitLayout.stateMaxWidth] as the column's cap.
class PhoneSetupHero extends StatelessWidget {
  const PhoneSetupHero({
    super.key,
    required this.scene,
    required this.title,
    this.ambient = false,
    this.entranceDuration = KitMotion.entrance,
    this.titleKey,
    this.body,
    this.bodyKey,
    this.bodyTone,
    this.progress,
    this.content,
    this.primary,
    this.secondary,
    this.tertiary = const [],
    this.footer,
    this.liveRegion = true,
  });

  final KitScene scene;

  /// Keep the drawing moving after its entrance: only while the person
  /// waits (setup running, OpenCode starting).
  final bool ambient;

  /// How long the drawing takes to draw itself in: [KitMotion.celebration]
  /// for a finished moment (setup ready), [KitMotion.entrance] otherwise.
  final Duration entranceDuration;

  final String title;
  final Key? titleKey;
  final String? body;
  final Key? bodyKey;

  /// The line's status. A problem is said in words, in the status's own
  /// text tone ([KitTokens.toneFor]: never red, LOOK-5); muted otherwise.
  final AppStatusTone? bodyTone;
  final KitProgress? progress;
  final Widget? content;
  final KitAction? primary;
  final KitAction? secondary;
  final List<KitAction> tertiary;
  final Widget? footer;
  final bool liveRegion;

  /// The drawing's widest size; smaller screens scale it down.
  static const heroWidth = 248.0;

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final actions = KitActionBlock(
      primary: primary,
      secondary: secondary,
      tertiary: tertiary,
    );
    final tone = bodyTone;
    final body = this.body;
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsetsDirectional.fromSTEB(
          tokens.gutter,
          tokens.space2,
          tokens.gutter,
          tokens.space6 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: KitLayout.stateMaxWidth,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: KitIllustration(
                      key: const ValueKey('phone-setup-hero-drawing'),
                      scene: scene,
                      width: math.min(
                        heroWidth,
                        constraints.maxWidth - 2 * tokens.gutter,
                      ),
                      ambient: ambient,
                      entranceDuration: entranceDuration,
                    ),
                  ),
                  SizedBox(height: tokens.space5),
                  Semantics(
                    container: true,
                    liveRegion: liveRegion,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        KitText(title, key: titleKey, role: KitTextRole.title),
                        if (body != null) ...[
                          SizedBox(height: tokens.space2),
                          KitText(
                            body,
                            key: bodyKey,
                            tone: tone == null
                                ? KitTextTone.secondary
                                : KitTokens.toneFor(tone),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (progress case final progress?) ...[
                    SizedBox(height: tokens.space5),
                    KitProgressView(progress: progress),
                  ],
                  if (content case final content?) ...[
                    SizedBox(height: tokens.space4),
                    content,
                  ],
                  if (!actions.isEmpty) ...[
                    SizedBox(height: tokens.space6),
                    actions,
                  ],
                  if (footer case final footer?) ...[
                    SizedBox(height: tokens.space4),
                    footer,
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
