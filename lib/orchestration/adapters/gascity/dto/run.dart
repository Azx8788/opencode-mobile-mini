import 'json_read.dart';
import 'list.dart';

/// `last_error` of a run (`RunLastError`): `{code, message}`.
class GcRunLastError {
  const GcRunLastError({this.code, this.message, this.raw = const {}});

  factory GcRunLastError.fromJson(Map<String, Object?> json) => GcRunLastError(
    code: readText(json, 'code'),
    message: readText(json, 'message'),
    raw: json,
  );

  final String? code;
  final String? message;
  final Map<String, Object?> raw;

  /// Message, else code, else null.
  String? get text => message ?? code;
}

/// One formula run (`Run`): `{run_id, title, status, formula, scope,
/// target, last_error, started_at, updated_at}`. Spec `status` values:
/// pending, active, waiting, canceling, completed, failed, canceled,
/// skipped.
class GcRun {
  const GcRun({
    required this.runId,
    required this.title,
    this.status,
    this.formula,
    this.scopeKind,
    this.scopeRef,
    this.target,
    this.lastError,
    this.startedAt,
    this.updatedAt,
    this.raw = const {},
  });

  factory GcRun.fromJson(Map<String, Object?> json) {
    final scope = readMapField(json, 'scope');
    final lastError = json['last_error'];
    return GcRun(
      runId: readText(json, 'run_id') ?? readText(json, 'id') ?? '',
      title: readString(json, 'title') ?? '',
      status: readText(json, 'status'),
      formula: readText(json, 'formula'),
      scopeKind: readText(scope, 'kind'),
      scopeRef: readText(scope, 'ref'),
      target: readText(json, 'target'),
      lastError: lastError is Map
          ? GcRunLastError.fromJson(readMap(lastError))
          : lastError is String && lastError.trim().isNotEmpty
          ? GcRunLastError(message: lastError)
          : null,
      startedAt: readDateTime(json, 'started_at'),
      updatedAt: readDateTime(json, 'updated_at'),
      raw: json,
    );
  }

  final String runId;
  final String title;
  final String? status;
  final String? formula;

  /// `scope.kind` (`rig`, `city`) and `scope.ref`.
  final String? scopeKind;
  final String? scopeRef;
  final String? target;
  final GcRunLastError? lastError;
  final DateTime? startedAt;
  final DateTime? updatedAt;
  final Map<String, Object?> raw;
}

/// One step of a run (`RunStep`): `{id, title, status, kind, assignee}`.
class GcRunStep {
  const GcRunStep({
    required this.id,
    required this.title,
    this.status,
    this.kind,
    this.assignee,
    this.raw = const {},
  });

  factory GcRunStep.fromJson(Map<String, Object?> json) => GcRunStep(
    id: readText(json, 'id') ?? '',
    title: readString(json, 'title') ?? '',
    status: readText(json, 'status'),
    kind: readText(json, 'kind'),
    assignee: readText(json, 'assignee'),
    raw: json,
  );

  final String id;
  final String title;
  final String? status;
  final String? kind;
  final String? assignee;
  final Map<String, Object?> raw;
}

/// `GET /runs` (`RunsListOutputBody`): `{runs[], status_counts, partial,
/// partial_errors}`. The spike saw `partial: true` with
/// `"run projection is warming"` throughout; [GcList.partial] carries it.
class GcRunsList extends GcList<GcRun> {
  const GcRunsList({
    super.items,
    super.partial,
    super.partialErrors,
    this.statusCounts = const {},
    super.raw,
  });

  factory GcRunsList.fromJson(Map<String, Object?> json) {
    final list = GcList<GcRun>.fromJson(json, GcRun.fromJson, itemsKey: 'runs');
    final counts = <String, int>{};
    for (final entry in readMapField(json, 'status_counts').entries) {
      final n = toInt(entry.value);
      if (n != null) counts[entry.key] = n;
    }
    return GcRunsList(
      items: list.items,
      partial: list.partial,
      partialErrors: list.partialErrors,
      statusCounts: counts,
      raw: json,
    );
  }

  /// Runs by raw status (`pending`, `active`, `failed`, ...).
  final Map<String, int> statusCounts;

  List<GcRun> get runs => items;
}
