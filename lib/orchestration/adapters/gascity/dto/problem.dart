import 'json_read.dart';

/// RFC 9457 problem+json error (`ErrorModel`): `{type, title, status,
/// detail, code, instance, errors[]}`. Gas City types look like
/// `urn:gascity:error:convoy-not-found` with the same slug in `code`.
class GcProblem {
  const GcProblem({
    this.type,
    this.title,
    this.status,
    this.detail,
    this.code,
    this.instance,
    this.errors = const [],
    this.raw = const {},
  });

  factory GcProblem.fromJson(Map<String, Object?> json) => GcProblem(
    type: readText(json, 'type'),
    title: readText(json, 'title'),
    status: readInt(json, 'status'),
    detail: readText(json, 'detail'),
    code: readText(json, 'code'),
    instance: readText(json, 'instance'),
    errors: [
      for (final e in readMapList(json, 'errors'))
        readText(e, 'message') ?? readText(e, 'location') ?? e.toString(),
    ],
    raw: json,
  );

  /// True when [json] looks like a problem document rather than a
  /// resource: it has a `type` URN or a numeric `status` with a `title`.
  static bool looksLikeProblem(Map<String, Object?> json) {
    final type = readText(json, 'type');
    if (type != null && type.startsWith('urn:')) return true;
    return json['status'] is num && readText(json, 'title') != null;
  }

  final String? type;
  final String? title;
  final int? status;
  final String? detail;

  /// Error slug (`convoy-not-found`, `invalid-request`); derived from the
  /// URN's last segment when `code` is absent.
  final String? code;
  final String? instance;
  final List<String> errors;
  final Map<String, Object?> raw;

  /// [code], else the last segment of [type], else null.
  String? get slug {
    if (code != null) return code;
    final t = type;
    if (t == null) return null;
    final i = t.lastIndexOf(':');
    return i < 0 ? t : t.substring(i + 1);
  }

  bool get isNotFound =>
      status == 404 || (slug?.endsWith('not-found') ?? false);

  /// Short human line: detail, else title, else the slug.
  String get message => detail ?? title ?? slug ?? 'Request failed';
}
