/// Product state of a run (formula run or batch/convoy). Total: every
/// provider string lands on a member, unrecognised ones on [unknown].
enum RunState {
  planning,
  working,
  waiting,
  blocked,
  failed,
  completed,
  cancelled,
  unknown;

  /// Maps a provider run status to a product state without throwing.
  ///
  /// Gas City: `pending`/`queued` → [planning]; `running`/`active`/
  /// `in_progress` → [working]; `done`/`closed` → [completed];
  /// `error` → [failed]; `canceled` → [cancelled]. Product names are
  /// accepted verbatim so a round trip through [name] is stable.
  static RunState fromProvider(String? value) {
    switch (_normalize(value)) {
      case 'planning':
      case 'pending':
      case 'queued':
      case 'plan':
        return planning;
      case 'working':
      case 'running':
      case 'active':
      case 'in_progress':
        return working;
      case 'waiting':
        return waiting;
      case 'blocked':
        return blocked;
      case 'failed':
      case 'error':
        return failed;
      case 'completed':
      case 'complete':
      case 'done':
      case 'closed':
      case 'succeeded':
        return completed;
      case 'cancelled':
      case 'canceled':
        return cancelled;
      default:
        return unknown;
    }
  }
}

/// Whether a run is a formula run or a batch (Gas City convoy).
enum RunKind {
  formula,
  batch,
  unknown;

  /// Maps a provider kind string; `convoy` is a [batch].
  static RunKind fromProvider(String? value) {
    switch (_normalize(value)) {
      case 'formula':
      case 'formula_run':
      case 'run':
        return formula;
      case 'batch':
      case 'convoy':
        return batch;
      default:
        return unknown;
    }
  }
}

/// One orchestrated run. [rawState] keeps the provider status string that
/// [state] was derived from.
class OrchestrationRun {
  const OrchestrationRun({
    required this.id,
    required this.title,
    required this.state,
    this.rawState,
    this.kind = RunKind.unknown,
    this.projectId,
    this.formula,
    this.stepCount,
    this.completedSteps,
    this.lastError,
    this.startedAt,
    this.updatedAt,
    this.finishedAt,
    this.merged = false,
    this.isUpkeep = false,
    this.raw = const {},
  });

  final String id;
  final String title;
  final RunState state;

  /// True for the host's own housekeeping (Gas City pack patrols, the
  /// shutdown dance, digests, `order:`/`nudge:` chores and scope-less
  /// workflow wisps): derived by the mapper, hidden by default in the
  /// product and never counted as work of the person's.
  final bool isUpkeep;

  /// Provider status string exactly as received; null when absent.
  final String? rawState;
  final RunKind kind;
  final String? projectId;

  /// Formula name for formula runs.
  final String? formula;
  final int? stepCount;
  final int? completedSteps;

  /// Last step error, surfaced when [state] is [RunState.failed].
  final String? lastError;
  final DateTime? startedAt;
  final DateTime? updatedAt;

  /// When the run finished (completed or cancelled); null while it is
  /// open, or when the host did not say.
  final DateTime? finishedAt;

  /// The run's work landed on its target branch: every item it tracked
  /// reports a merge. False while open and for work that was not merged.
  final bool merged;

  /// Untouched provider payload.
  final Map<String, Object?> raw;

  @override
  String toString() => 'OrchestrationRun($id, $state)';
}

/// Lower snake_case of a provider string: trims, splits camelCase, and
/// folds spaces and dashes to underscores, so `needsInput`, `needs-input`
/// and `Needs Input` all compare equal.
String _normalize(String? value) => value == null
    ? ''
    : value
          .trim()
          .replaceAllMapped(
            RegExp(r'([a-z0-9])([A-Z])'),
            (m) => '${m[1]}_${m[2]}',
          )
          .toLowerCase()
          .replaceAll(RegExp(r'[\s-]+'), '_');
