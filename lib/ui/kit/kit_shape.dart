/// The kit's named shapes (docs/ux-system/kit-api/KitSurface.md, "Shared
/// enums"; README.md decision D13): a part names a shape, never a radius
/// number. [KitTokens.shapeOf] resolves each one to the kit radii.
///
/// A pre-wave seam (STANDARDS §0.5 step 2, `_new-tokens.md`). It is exported
/// from `kit_tokens.dart`, so a part that reads the tokens has it too.
enum KitShape {
  /// No rounding (0).
  square,

  /// A row's icon tile: `iconTileRadius` (9).
  tile,

  /// A code block: `codeRadius` (14).
  code,

  /// A button, a field: `buttonRadius` (14).
  button,

  /// A grouped panel: `panelCornerRadius` (18).
  panel,

  /// A needs-you or request card only: `cardRadius` (22).
  card,

  /// A centred dialog panel: `panelRadius` (24).
  dialog,

  /// A bottom sheet, top corners only: `sheetRadius` (30).
  sheet,

  /// A stadium: chips and pills (VL §4 "999", LOOK-19).
  pill,

  /// A circle: an icon button, an avatar.
  circle,
}

/// The surface steps a part sits on (KitSurface.md; KIT-42: exactly these).
/// [KitTokens.fillOf] resolves each one to its role colour.
enum KitSurfaceLevel { ground, surface1, surface2, surface3 }
