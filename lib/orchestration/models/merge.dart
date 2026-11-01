/// Merge readiness of one run (TEAM-205, 02-ux §8a): what the host front's
/// `/front/merge-readiness/{runId}` said. Every line is a check the front
/// derived on the host (work items, tests, build, review, conflicts,
/// acceptance criteria); the boundaries are the host's own rules
/// ("Never merge without approval"), shown rather than silently applied.
///
/// The model is provider-neutral and lenient: unknown keys are kept, a
/// missing field is its zero value, nothing here throws on odd JSON.
library;

/// One readiness line: `✓ Tests` or `✗ Tests · 2 failed`.
class MergeReadinessLine {
  const MergeReadinessLine({
    required this.key,
    required this.ok,
    this.detail,
    this.pending = false,
  });

  /// `work`, `tests`, `build`, `review`, `conflicts`, `acceptance` or a
  /// configured check key.
  final String key;
  final bool ok;

  /// The host's one-line explanation ("18/18 work items", "exit 1: …").
  final String? detail;

  /// The host is still computing this line (a check is running).
  final bool pending;

  static MergeReadinessLine? fromJson(Object? json) {
    if (json is! Map) return null;
    final key = _text(json['key']);
    if (key == null) return null;
    return MergeReadinessLine(
      key: key,
      ok: json['ok'] == true,
      detail: _text(json['detail']),
      pending: json['pending'] == true,
    );
  }

  Map<String, Object?> toJson() => {
    'key': key,
    'ok': ok,
    if (detail != null) 'detail': detail,
    if (pending) 'pending': true,
  };
}

/// A host boundary that applies to merging, with the text the host shows.
class MergeBoundary {
  const MergeBoundary({
    required this.key,
    required this.satisfied,
    required this.text,
  });

  /// `require_approval`, `require_tests`, `allowed_logins`, …
  final String key;
  final bool satisfied;

  /// The host's wording ("Never merge without approval").
  final String text;

  static MergeBoundary? fromJson(Object? json) {
    if (json is! Map) return null;
    final key = _text(json['key']);
    if (key == null) return null;
    return MergeBoundary(
      key: key,
      satisfied: json['satisfied'] == true,
      text: _text(json['text']) ?? key,
    );
  }

  Map<String, Object?> toJson() => {
    'key': key,
    'satisfied': satisfied,
    'text': text,
  };
}

/// One changed file with its line counts (`git diff --numstat`).
class MergeChange {
  const MergeChange({
    required this.path,
    this.additions = 0,
    this.deletions = 0,
  });

  final String path;
  final int additions;
  final int deletions;

  static MergeChange? fromJson(Object? json) {
    if (json is! Map) return null;
    final path = _text(json['path']);
    if (path == null) return null;
    return MergeChange(
      path: path,
      additions: _int(json['additions']),
      deletions: _int(json['deletions']),
    );
  }

  Map<String, Object?> toJson() => {
    'path': path,
    'additions': additions,
    'deletions': deletions,
  };
}

/// The merge request the run's Approve button acts on: a merge-request
/// bead when the pack made one, else the run (convoy) bead itself.
class MergeRequestInfo {
  const MergeRequestInfo({
    required this.id,
    this.title,
    this.approvedBy,
    this.approvedAt,
  });

  final String id;
  final String? title;

  /// The tailnet login recorded by the host on approval, when any.
  final String? approvedBy;
  final DateTime? approvedAt;

  bool get isApproved => approvedBy != null && approvedBy!.isNotEmpty;

  static MergeRequestInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _text(json['id']);
    if (id == null) return null;
    final at = _text(json['approvedAt']);
    return MergeRequestInfo(
      id: id,
      title: _text(json['title']),
      approvedBy: _text(json['approvedBy']),
      approvedAt: at == null ? null : DateTime.tryParse(at),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    if (title != null) 'title': title,
    if (approvedBy != null) 'approvedBy': approvedBy,
    if (approvedAt != null) 'approvedAt': approvedAt!.toIso8601String(),
  };
}

/// The front's readiness document for one run.
class MergeReadiness {
  const MergeReadiness({
    required this.runId,
    required this.ready,
    this.rig,
    this.targetBranch,
    this.lines = const [],
    this.files = 0,
    this.additions = 0,
    this.deletions = 0,
    this.changes = const [],
    this.boundaries = const [],
    this.mergeRequest,
    this.mergeCommit,
    this.branches = const [],
    this.raw = const {},
  });

  final String runId;

  /// Every line is ok: the host would accept a merge, boundaries aside.
  final bool ready;
  final String? rig;

  /// The branch a merge lands on (`main`).
  final String? targetBranch;
  final List<MergeReadinessLine> lines;

  /// Changed-file count and line totals against [targetBranch].
  final int files;
  final int additions;
  final int deletions;
  final List<MergeChange> changes;
  final List<MergeBoundary> boundaries;
  final MergeRequestInfo? mergeRequest;

  /// The commit already on [targetBranch] when nothing is left to merge,
  /// or the merge commit after a merge.
  final String? mergeCommit;

  /// Branches the merge would bring in.
  final List<String> branches;

  /// Untouched host payload.
  final Map<String, Object?> raw;

  /// Nothing is left to merge: every branch is already on the target.
  bool get alreadyMerged => ready && branches.isEmpty && mergeCommit != null;

  /// The first line that is not ok, or null when every line is.
  MergeReadinessLine? get firstMissing {
    for (final line in lines) {
      if (!line.ok) return line;
    }
    return null;
  }

  /// The first boundary the host would refuse on, or null.
  MergeBoundary? get firstBlocking {
    for (final boundary in boundaries) {
      if (!boundary.satisfied) return boundary;
    }
    return null;
  }

  /// Ready and every boundary satisfied: Merge is enabled.
  bool get canMerge => ready && firstBlocking == null;

  /// Decodes the front's document; null when [json] has no `lines` and
  /// no `ready` (not a readiness document).
  static MergeReadiness? fromJson(Object? json, {String? runId}) {
    if (json is! Map) return null;
    if (!json.containsKey('ready') && !json.containsKey('lines')) return null;
    final id = _text(json['runId']) ?? runId;
    if (id == null) return null;
    final rawLines = json['lines'];
    final rawBoundaries = json['boundaries'];
    final rawChanges = json['changes'];
    final rawBranches = json['branches'];
    return MergeReadiness(
      runId: id,
      ready: json['ready'] == true,
      rig: _text(json['rig']),
      targetBranch: _text(json['targetBranch']),
      lines: [
        if (rawLines is List)
          for (final line in rawLines) ?MergeReadinessLine.fromJson(line),
      ],
      files: _int(json['files']),
      additions: _int(json['additions']),
      deletions: _int(json['deletions']),
      changes: [
        if (rawChanges is List)
          for (final change in rawChanges) ?MergeChange.fromJson(change),
      ],
      boundaries: [
        if (rawBoundaries is List)
          for (final boundary in rawBoundaries)
            ?MergeBoundary.fromJson(boundary),
      ],
      mergeRequest: MergeRequestInfo.fromJson(json['mergeRequest']),
      mergeCommit: _text(json['mergeCommit']),
      branches: [
        if (rawBranches is List)
          for (final branch in rawBranches) ?_text(branch),
      ],
      raw: {for (final entry in json.entries) '${entry.key}': entry.value},
    );
  }

  Map<String, Object?> toJson() => {
    'runId': runId,
    'ready': ready,
    if (rig != null) 'rig': rig,
    if (targetBranch != null) 'targetBranch': targetBranch,
    'lines': [for (final line in lines) line.toJson()],
    'files': files,
    'additions': additions,
    'deletions': deletions,
    'changes': [for (final change in changes) change.toJson()],
    'boundaries': [for (final boundary in boundaries) boundary.toJson()],
    if (mergeRequest != null) 'mergeRequest': mergeRequest!.toJson(),
    if (mergeCommit != null) 'mergeCommit': mergeCommit,
    'branches': branches,
  };

  @override
  String toString() =>
      'MergeReadiness($runId, ready: $ready, ${lines.length} lines)';
}

String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}
