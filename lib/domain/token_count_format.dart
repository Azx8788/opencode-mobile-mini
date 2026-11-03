/// Token counts as a person reads them: a chip is a glance, not a ledger.
///
/// The full number stays available to screen readers and to the details
/// sheet; the chip says `12.4k`, not `12,431`. Rounding is deliberately
/// coarse — the difference between 12,431 and 12,449 tokens changes nothing
/// a person does, while a five-digit number pushes the model chip off the
/// status line.
library;

/// Compact form for a token count.
///
/// * below 1,000: the number itself (`987`);
/// * below 1,000,000: `k`, with one decimal below 10k (`8.4k`) and whole
///   thousands above (`12k`) — the decimal stops being information there;
/// * below 1,000,000,000: `M`, same rule (`1.2M`, `24M`).
///
/// Negative counts are not a thing the server sends; they are clamped to `0`
/// rather than printed as `-1` in a chip.
String formatTokenCount(int value) {
  if (value <= 0) return '0';
  if (value < 1000) return '$value';
  if (value < 1000000) return _scaled(value, 1000, 'k');
  if (value < 1000000000) return _scaled(value, 1000000, 'M');
  return _scaled(value, 1000000000, 'B');
}

String _scaled(int value, int unit, String suffix) {
  final whole = value ~/ unit;
  if (whole >= 10) return '$whole$suffix';
  final tenths = (value * 10 / unit).round();
  final text = (tenths / 10).toStringAsFixed(1);
  return text.endsWith('.0')
      ? '${text.substring(0, text.length - 2)}$suffix'
      : '$text$suffix';
}
