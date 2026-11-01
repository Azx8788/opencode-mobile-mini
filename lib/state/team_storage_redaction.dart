import '../ui/kit/kit_redact.dart';

/// Redacts strings before encoding a team cache or mutation receipt. Walking
/// the structure preserves JSON quoting and numeric usage values. This affects
/// stored copies only; the live request sent to the host is unchanged.
Object? redactTeamStoredValue(Object? value) => switch (value) {
  String text => KitRedact.text(text),
  List values => values.map(redactTeamStoredValue).toList(),
  Map values => values.map((key, child) {
    final name = key.toString();
    // Include field names so {password: arbitraryText} is also masked.
    final probe = '$name="redaction-probe"';
    final secretField = KitRedact.text(probe) != probe;
    return MapEntry(
      KitRedact.text(name),
      secretField && child != null
          ? KitRedact.mask
          : redactTeamStoredValue(child),
    );
  }),
  _ => value,
};
