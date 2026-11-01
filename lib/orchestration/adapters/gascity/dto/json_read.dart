/// Tolerant JSON readers shared by the Gas City DTOs.
///
/// Every reader accepts any JSON value, never throws, and falls back to a
/// default (null, empty, false) when the field is missing, null or of the
/// wrong type. Numbers arrive as `int` or `double` and strings that look
/// numeric are accepted for integer fields, because the recordings show the
/// bead `metadata` map carrying numbers as strings (`"churn_count": "0"`).
library;

/// The map itself when [value] is a JSON object, else an empty map.
Map<String, Object?> readMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return value.map((k, v) => MapEntry(k.toString(), v));
  }
  return const {};
}

/// The nested object at [key], or an empty map. Distinguishes "absent" from
/// "present but empty" through [hasMap].
Map<String, Object?> readMapField(Map<String, Object?> json, String key) =>
    readMap(json[key]);

/// True when [key] holds a JSON object.
bool hasMap(Map<String, Object?> json, String key) => json[key] is Map;

/// The string at [key]; numbers and booleans are stringified, anything else
/// yields null. Empty strings are kept (callers decide about emptiness).
String? readString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  return null;
}

/// [readString] with empty and whitespace-only strings folded to null.
String? readText(Map<String, Object?> json, String key) {
  final value = readString(json, key);
  if (value == null || value.trim().isEmpty) return null;
  return value;
}

/// The integer at [key]; doubles are truncated and numeric strings parsed.
int? readInt(Map<String, Object?> json, String key) => toInt(json[key]);

/// [readInt] over a bare value.
int? toInt(Object? value) {
  if (value is int) return value;
  if (value is double) return value.isFinite ? value.toInt() : null;
  if (value is String) return int.tryParse(value.trim());
  return null;
}

/// The double at [key]; ints are widened and numeric strings parsed.
double? readDouble(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

/// The boolean at [key]; `"true"`/`"false"` strings and 0/1 are accepted.
bool? readBool(Map<String, Object?> json, String key) => toBool(json[key]);

/// [readBool] over a bare value.
bool? toBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    switch (value.trim().toLowerCase()) {
      case 'true':
      case 'yes':
      case '1':
        return true;
      case 'false':
      case 'no':
      case '0':
      case '':
        return false;
    }
  }
  return null;
}

/// The RFC 3339 timestamp at [key], or null when absent or unparsable.
DateTime? readDateTime(Map<String, Object?> json, String key) =>
    toDateTime(json[key]);

/// [readDateTime] over a bare value. Gas City stamps nanosecond precision
/// (`2026-09-10T22:42:15.828269075+04:00`), which `DateTime.tryParse`
/// accepts (extra digits are truncated to microseconds).
DateTime? toDateTime(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value.trim());
}

/// The list of strings at [key]; non-string entries are stringified when
/// scalar and dropped otherwise. Null and non-list values yield an empty
/// list (the spec marks every list as `array | null`).
List<String> readStringList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (item is String)
        item
      else if (item is num || item is bool)
        item.toString(),
  ];
}

/// The list of JSON objects at [key]; non-object entries are dropped.
List<Map<String, Object?>> readMapList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (item is Map) readMap(item),
  ];
}

/// The list at [key] decoded through [decode]; entries that are not objects
/// are dropped, and a decoder that throws on one entry drops only that one.
List<T> readList<T>(
  Map<String, Object?> json,
  String key,
  T Function(Map<String, Object?> json) decode,
) {
  final out = <T>[];
  for (final item in readMapList(json, key)) {
    try {
      out.add(decode(item));
    } on Object {
      // A single malformed entry never sinks the whole list.
    }
  }
  return out;
}

/// A `map<string, string>` such as the bead `metadata`, with every value
/// stringified. Nested objects are kept as their JSON text so nothing is
/// lost; nulls are dropped.
Map<String, String> readStringMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) return const {};
  final out = <String, String>{};
  for (final entry in value.entries) {
    final v = entry.value;
    if (v == null) continue;
    out[entry.key.toString()] = v is String ? v : v.toString();
  }
  return out;
}
