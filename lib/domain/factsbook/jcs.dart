import 'dart:convert';

/// RFC 8785 JSON Canonicalization Scheme, for the bytes an owner signature
/// covers. Objects sort their keys by UTF-16 code units, strings escape only
/// what JSON requires, and numbers must be integers (the contract uses no
/// others).
abstract final class Jcs {
  /// The canonical UTF-8 bytes of [value].
  static List<int> bytes(Object? value) => utf8.encode(string(value));

  static String string(Object? value) {
    final out = StringBuffer();
    _write(out, value);
    return out.toString();
  }

  static void _write(StringBuffer out, Object? value) {
    switch (value) {
      case null:
        out.write('null');
      case bool():
        out.write(value ? 'true' : 'false');
      case int():
        out.write(value);
      case double():
        if (value.isFinite && value == value.truncateToDouble()) {
          out.write(value.toInt());
        } else {
          throw ArgumentError('JCS here carries integers only: $value');
        }
      case String():
        _string(out, value);
      case List():
        out.write('[');
        for (var i = 0; i < value.length; i++) {
          if (i > 0) out.write(',');
          _write(out, value[i]);
        }
        out.write(']');
      case Map():
        final keys = [for (final k in value.keys) k as String]..sort();
        out.write('{');
        for (var i = 0; i < keys.length; i++) {
          if (i > 0) out.write(',');
          _string(out, keys[i]);
          out.write(':');
          _write(out, value[keys[i]]);
        }
        out.write('}');
      default:
        throw ArgumentError('Not a JSON value: ${value.runtimeType}');
    }
  }

  static void _string(StringBuffer out, String text) {
    out.write('"');
    for (final unit in text.codeUnits) {
      switch (unit) {
        case 0x22:
          out.write(r'\"');
        case 0x5c:
          out.write(r'\\');
        case 0x08:
          out.write(r'\b');
        case 0x09:
          out.write(r'\t');
        case 0x0a:
          out.write(r'\n');
        case 0x0c:
          out.write(r'\f');
        case 0x0d:
          out.write(r'\r');
        default:
          if (unit < 0x20) {
            out.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
          } else {
            out.writeCharCode(unit);
          }
      }
    }
    out.write('"');
  }
}
