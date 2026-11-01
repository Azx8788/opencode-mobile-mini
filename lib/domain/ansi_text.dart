/// Plain text from terminal output: colour and cursor codes removed, line
/// endings made `\n`, other control characters dropped. Pure Dart.
library;

final _osc = RegExp(r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)?');
final _csi = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
final _other = RegExp(r'\x1B[@-Z\\-_()#][0-9A-Za-z]?');
final _control = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1A\x1C-\x1F\x7F]');

/// [input] without escape sequences. A lone carriage return (a progress bar
/// redrawing itself) becomes a new line so each state stays readable.
String withoutTerminalCodes(String input) {
  if (input.isEmpty) return input;
  return input
      .replaceAll(_osc, '')
      .replaceAll(_csi, '')
      .replaceAll(_other, '')
      .replaceAll('\x1B', '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(_control, '');
}
