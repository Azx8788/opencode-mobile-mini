import 'json_read.dart';

/// One edge of the work graph (`Dep`): `{issue_id, depends_on_id, type}`.
/// Convoys use `type: tracks`; blocking edges use `blocks`.
class GcDependency {
  const GcDependency({
    required this.issueId,
    required this.dependsOnId,
    this.type,
    this.raw = const {},
  });

  factory GcDependency.fromJson(Map<String, Object?> json) => GcDependency(
    issueId: readText(json, 'issue_id') ?? '',
    dependsOnId: readText(json, 'depends_on_id') ?? '',
    type: readText(json, 'type'),
    raw: json,
  );

  final String issueId;
  final String dependsOnId;
  final String? type;
  final Map<String, Object?> raw;

  bool get isTracks => type == 'tracks';
  bool get isBlocks => type == 'blocks';
}

/// `GET /bead/{id}`, `GET /beads` item, the `bead` inside `bead.*` event
/// payloads, and convoys (`Bead`, `issue_type: convoy`).
///
/// Routing state lives in the string [metadata] map; the typed accessors
/// ([routedTo], [sessionId], [branch], ...) read the keys the spike found
/// populated. Absent keys and empty strings both read as null.
class GcBead {
  const GcBead({
    required this.id,
    required this.title,
    this.status,
    this.issueType,
    this.priority,
    this.description,
    this.assignee,
    this.parent,
    this.ref,
    this.from,
    this.isBlocked = false,
    this.ephemeral = false,
    this.labels = const [],
    this.dependencies = const [],
    this.needs = const [],
    this.metadata = const {},
    this.createdAt,
    this.updatedAt,
    this.deferUntil,
    this.raw = const {},
  });

  factory GcBead.fromJson(Map<String, Object?> json) => GcBead(
    id: readText(json, 'id') ?? '',
    title: readString(json, 'title') ?? '',
    status: readText(json, 'status'),
    issueType: readText(json, 'issue_type'),
    priority: readInt(json, 'priority'),
    description: readText(json, 'description'),
    assignee: readText(json, 'assignee'),
    parent: readText(json, 'parent'),
    ref: readText(json, 'ref'),
    from: readText(json, 'from'),
    isBlocked: readBool(json, 'is_blocked') ?? false,
    ephemeral: readBool(json, 'ephemeral') ?? false,
    labels: readStringList(json, 'labels'),
    dependencies: readList(json, 'dependencies', GcDependency.fromJson),
    needs: readStringList(json, 'needs'),
    metadata: readStringMap(json, 'metadata'),
    createdAt: readDateTime(json, 'created_at'),
    updatedAt: readDateTime(json, 'updated_at'),
    deferUntil: readDateTime(json, 'defer_until'),
    raw: json,
  );

  final String id;
  final String title;

  /// Raw status: `open`, `in_progress`, `closed`.
  final String? status;

  /// `task`, `convoy`, `session`, `chore`, `message`, `molecule`, ...
  final String? issueType;
  final int? priority;
  final String? description;

  /// Agent identity currently assigned (`ocproof/gastown.refinery`).
  final String? assignee;
  final String? parent;
  final String? ref;
  final String? from;
  final bool isBlocked;
  final bool ephemeral;
  final List<String> labels;
  final List<GcDependency> dependencies;
  final List<String> needs;

  /// Provider metadata; every value is a string.
  final Map<String, String> metadata;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deferUntil;
  final Map<String, Object?> raw;

  /// A metadata value, with empty strings folded to null.
  String? meta(String key) {
    final value = metadata[key];
    if (value == null || value.trim().isEmpty) return null;
    return value;
  }

  /// `gc.routed_to`: pool or agent the bead was slung at.
  String? get routedTo => meta('gc.routed_to');

  /// `gc.session_id`: live session working the bead.
  String? get sessionId => meta('gc.session_id');

  /// `gc.session_name`: named session working the bead.
  String? get sessionName => meta('gc.session_name');

  /// `gc.work_dir` (falls back to plain `work_dir`).
  String? get workDir => meta('gc.work_dir') ?? meta('work_dir');

  /// `gc.work_branch`: branch the worktree started from.
  String? get workBranch => meta('gc.work_branch');

  /// `branch`: the polecat branch carrying the change.
  String? get branch => meta('branch');
  String? get mergeStrategy => meta('merge_strategy');

  /// `target`: merge target branch.
  String? get target => meta('target');

  /// `closed_reason` (spec) or `close_reason` (what the host writes).
  String? get closedReason => meta('closed_reason') ?? meta('close_reason');

  /// `last_error`: non-empty when the last delivery or step failed.
  String? get lastError => meta('last_error');

  /// `gc.kind`: `wisp`, `gate`, ... when the host tags the bead kind.
  String? get gcKind => meta('gc.kind');
  String? get formulaName => meta('gc.formula_name');

  bool get isConvoy => issueType == 'convoy';
  bool get isSessionBead => issueType == 'session' || hasLabel('gc:session');
  bool get isClosed => status?.toLowerCase() == 'closed';

  /// True when the bead asks the person for a decision (a gate bead).
  bool get isGate =>
      issueType == 'gate' ||
      gcKind == 'gate' ||
      hasLabel('gate') ||
      hasLabel('gc:gate');

  /// True when the `needs-review` label is present.
  bool get needsReview => hasLabel('needs-review');

  bool hasLabel(String label) => labels.contains(label);

  /// Ids this bead is tracked by or depends on: every dependency edge
  /// whose `issue_id` is this bead (or is unspecified).
  List<String> get dependsOn => [
    for (final dep in dependencies)
      if ((dep.issueId.isEmpty || dep.issueId == id) &&
          dep.dependsOnId.isNotEmpty)
        dep.dependsOnId,
  ];
}

/// A convoy: a bead with `issue_type: convoy` whose `tracks` dependencies
/// list the beads it batches. `GET /convoys` items are plain beads; the
/// `GET /convoy/{id}` shape wraps one under `convoy` with `children` and
/// `progress`, which [GcConvoy.fromJson] also accepts.
class GcConvoy {
  const GcConvoy({
    required this.bead,
    this.children = const [],
    this.progressClosed,
    this.progressTotal,
  });

  factory GcConvoy.fromJson(Map<String, Object?> json) {
    if (hasMap(json, 'convoy')) {
      final progress = readMapField(json, 'progress');
      return GcConvoy(
        bead: GcBead.fromJson(readMapField(json, 'convoy')),
        children: readList(json, 'children', GcBead.fromJson),
        progressClosed: readInt(progress, 'closed'),
        progressTotal: readInt(progress, 'total'),
      );
    }
    return GcConvoy(bead: GcBead.fromJson(json));
  }

  final GcBead bead;

  /// Child beads when the host embedded them; empty for list items.
  final List<GcBead> children;
  final int? progressClosed;
  final int? progressTotal;

  String get id => bead.id;
  String get title => bead.title;
  Map<String, Object?> get raw => bead.raw;

  /// Ids of the beads this convoy tracks.
  List<String> get trackedIds => [
    for (final dep in bead.dependencies)
      if (dep.isTracks || dep.type == null)
        if (dep.dependsOnId.isNotEmpty) dep.dependsOnId,
  ];
}

/// `GET /beads/{id}/graph` → `{root, beads[], deps[]}`.
class GcBeadGraph {
  const GcBeadGraph({
    this.root,
    this.beads = const [],
    this.deps = const [],
    this.raw = const {},
  });

  factory GcBeadGraph.fromJson(Map<String, Object?> json) => GcBeadGraph(
    root: hasMap(json, 'root')
        ? GcBead.fromJson(readMapField(json, 'root'))
        : null,
    beads: readList(json, 'beads', GcBead.fromJson),
    deps: readList(json, 'deps', GcDependency.fromJson),
    raw: json,
  );

  final GcBead? root;
  final List<GcBead> beads;
  final List<GcDependency> deps;
  final Map<String, Object?> raw;
}
