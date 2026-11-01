import 'package:flutter/foundation.dart';

// The fold that shows these values. Re-exported here so the kit_sheet.dart
// library (its kit_confirm_sheet.dart part), which already imports this
// file, reaches the public fold without an edit to kit_sheet.dart
// (KitDetailsFold.md "File").
export 'kit_details_fold.dart' show KitDetailsFold, showKitTechnicalDetails;

// The same seam for the one bidi helper: the confirm part isolates its
// typed name with KitBidi.ltr (KitConfirmSheet.md row 5, COPY-30).
export 'kit_bidi.dart' show KitBidi;

/// One technical value a person may need but never reads first: an
/// address, a path, a branch, an id (docs/ux-system/kit-v2.md §1.8, §4.10).
/// Kit parts show it last, folded under Details ([KitDetailsFold]), in mono,
/// isolated left to right so a path inside Arabic text never reorders, and
/// copyable.
///
/// Never a secret (SEC-4): the fold refuses one.
@immutable
class KitTechnicalValue {
  const KitTechnicalValue(
    this.label,
    this.value, {
    this.copyable = true,
    this.key,
    this.spoken,
  });

  /// What it is, in the person's words: "Address", "Branch", "Interaction
  /// id".
  final String label;

  /// The value exactly as it is. Shown mono, left to right, wrapping
  /// anywhere, selectable. Copied as is (after redaction).
  final String value;
  final bool copyable;

  /// On the value's text (tests find the value by it).
  final Key? key;

  /// How a screen reader says it: "100.64.0.3, port 4096". Null reads
  /// [value].
  final String? spoken;
}
