import 'package:flutter/widgets.dart';

/// Keeps technical values (paths, commands, code, URLs, ids) whole inside
/// right-to-left copy. The value is wrapped in a Unicode directional
/// isolate, so an Arabic sentence around it never reorders its slashes,
/// dots or dashes, and the value never reorders the sentence.
abstract final class KitBidi {
  /// LEFT-TO-RIGHT ISOLATE.
  static const String lri = '\u2066';

  /// FIRST STRONG ISOLATE: the direction follows the value's first strong
  /// character.
  static const String fsi = '\u2068';

  /// POP DIRECTIONAL ISOLATE: closes [lri] or [fsi].
  static const String pdi = '\u2069';

  /// [s] isolated as left-to-right: paths, commands, code, URLs, hashes.
  static String ltr(String s) {
    if (s.isEmpty || _isolated(s)) return s;
    return '$lri$s$pdi';
  }

  /// [s] isolated with its direction taken from its own first strong
  /// character: names or titles that may be either Arabic or Latin.
  static String auto(String s) {
    if (s.isEmpty || _isolated(s)) return s;
    return '$fsi$s$pdi';
  }

  static bool _isolated(String s) =>
      (s.startsWith(lri) || s.startsWith(fsi)) && s.endsWith(pdi);

  /// A [Text] showing [value] isolated as left-to-right. The paragraph
  /// keeps the ambient direction, so it still aligns with the screen.
  static Widget ltrText(
    String value, {
    Key? key,
    TextStyle? style,
    int? maxLines,
    TextOverflow? overflow,
    bool? softWrap,
    String? semanticsLabel,
  }) => Text(
    ltr(value),
    key: key,
    style: style,
    maxLines: maxLines,
    overflow: overflow,
    softWrap: softWrap,
    semanticsLabel: semanticsLabel,
  );
}
