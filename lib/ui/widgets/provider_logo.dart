import 'package:flutter/widgets.dart';

import '../../domain/provider_logo_store.dart';
import '../../domain/provider_presentation.dart';
import '../app_theme.dart';
import '../kit/kit_image.dart';

/// A provider's identity mark: a [KitAvatar] (KitImage.md, "Replaces").
///
/// The mark is the provider's monochrome models.dev logo, tinted with the
/// theme's primary text colour by the kit (`KitImageSource.vectorLogo`). It
/// is fetched once and kept on disk by [ProviderLogoStore] (refreshed at
/// most weekly); the URL is built there from a validated provider slug and
/// never comes from a server. While it loads, when the provider has no logo,
/// and when it cannot load, the avatar shows the initials of the provider's
/// presented name. OpenCode's own providers show the terminal glyph.
///
/// Decorative: the row that shows the logo already names the provider, so
/// the mark is excluded from the semantics tree.
class ProviderLogo extends StatelessWidget {
  const ProviderLogo(this.providerID, {super.key, this.size});

  final String providerID;

  /// Null: the avatar at its own tile size ([KitAvatarSize.tile], 30 dp),
  /// which lines up with every other row's leading tile. A number scales
  /// the whole mark to that square, for a logo set inline with text (the
  /// model picker's 18 and 24 dp marks).
  final double? size;

  /// Test seam. When set, every logo asks this for its SVG text instead of
  /// the [ProviderLogoStore]; returning null (or a null future) renders the
  /// initials, so widget tests never touch the network or the disk.
  static Future<String?>? Function(String providerID)? logoLoaderOverride;

  /// Retired: [KitAvatar] decodes at its own laid-out size times the device
  /// pixel ratio (KitImage.md, "Decode size"). Kept for callers.
  static const int cacheWidth = 128;

  /// Retired: the loaded cross-fade is [KitImage]'s own, on
  /// `KitMotion.quick`. Kept for callers.
  static const Duration fadeIn = Duration(milliseconds: 150);

  @override
  Widget build(BuildContext context) {
    // The presented name's words ("fireworks-ai" -> "fireworks ai"), so
    // KitAvatar's initials take one letter from each of the first two.
    final words = presentProvider(providerID).name
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .where((word) => word.isNotEmpty)
        .join(' ');
    final name = words.isEmpty ? providerID : words;
    final Widget avatar;
    if (isOpenCodeProvider(providerID)) {
      avatar = KitAvatar(
        key: const ValueKey('provider-logo-prompt-glyph'),
        name: name,
        icon: AppIconography.terminal,
        decorative: true,
      );
    } else {
      final override = logoLoaderOverride;
      avatar = KitAvatar(
        name: name,
        image: KitImageSource.vectorLogo(
          id: providerID,
          load: () => override == null
              ? ProviderLogoStore.shared.svgFor(providerID)
              : override(providerID) ?? Future<String?>.value(null),
        ),
        decorative: true,
        // The logo catalog lacks many providers; initials are enough.
        optionalImage: true,
      );
    }
    final dimension = size;
    if (dimension == null) return avatar;
    return SizedBox.square(
      dimension: dimension,
      child: FittedBox(child: avatar),
    );
  }
}
