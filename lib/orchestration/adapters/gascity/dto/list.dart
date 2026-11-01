import 'json_read.dart';

/// The Gas City list envelope (`ListBody*`): `{items, total, next_cursor,
/// partial, partial_errors}`. [partial] is true when a backend failed and
/// the list is incomplete; the mapper surfaces it instead of throwing.
class GcList<T> {
  const GcList({
    this.items = const [],
    this.total,
    this.nextCursor,
    this.partial = false,
    this.partialErrors = const [],
    this.raw = const {},
  });

  /// Decodes `items[]` through [decode]; malformed entries are dropped. The
  /// list key defaults to `items` and can be overridden for envelopes such
  /// as `/runs` (`runs[]`) and `/waits` (`waits[]`).
  factory GcList.fromJson(
    Map<String, Object?> json,
    T Function(Map<String, Object?> json) decode, {
    String itemsKey = 'items',
  }) => GcList(
    items: readList(json, itemsKey, decode),
    total: readInt(json, 'total'),
    nextCursor: readText(json, 'next_cursor'),
    partial: readBool(json, 'partial') ?? false,
    partialErrors: readStringList(json, 'partial_errors'),
    raw: json,
  );

  final List<T> items;
  final int? total;
  final String? nextCursor;
  final bool partial;
  final List<String> partialErrors;
  final Map<String, Object?> raw;

  bool get isEmpty => items.isEmpty;
}
