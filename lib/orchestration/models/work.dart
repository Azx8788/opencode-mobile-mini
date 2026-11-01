/// Product state of one work item (Gas City bead). Total: every provider
/// string lands on a member, unrecognised ones on [unknown].
enum WorkState {
  queued,
  ready,
  working,
  waiting,
  blocked,
  needsInput,
  review,
  failed,
  completed,
  cancelled,
  unknown;

  /// Maps a bare provider status string to a product state without throwing.
  ///
  /// Gas City bead `status` values: `open` → [queued] (a bead is only
  /// [ready] when the provider reports it in the ready set, which is a
  /// separate flag and not derivable from the status string alone);
  /// `in_progress` → [working]; `closed` → [completed]. Richer inputs
  /// (blocked flag, waiting session, labels, errors, closed reason) go
  /// through [derive], which is what the Gas City mapper uses.
  static WorkState fromProvider(String? value) {
    switch (_normalize(value)) {
      case 'queued':
      case 'open':
      case 'pending':
      case 'todo':
        return queued;
      case 'ready':
        return ready;
      case 'working':
      case 'in_progress':
      case 'active':
      case 'running':
        return working;
      case 'waiting':
        return waiting;
      case 'blocked':
        return blocked;
      case 'needs_input':
      case 'needsinput':
      case 'input':
        return needsInput;
      case 'review':
      case 'needs_review':
      case 'in_review':
        return review;
      case 'failed':
      case 'error':
        return failed;
      case 'completed':
      case 'complete':
      case 'closed':
      case 'done':
        return completed;
      case 'cancelled':
      case 'canceled':
        return cancelled;
      default:
        return unknown;
    }
  }

  /// The 04 §4 state table: bead `status` × `is_blocked` × session
  /// `waiting` × `needs-review` label × run-step `last_error` ×
  /// `closed_reason=cancelled`. Precedence, highest first: cancelled,
  /// failed, blocked, needs input, waiting, review, then the bare status
  /// (with `open` promoted to [ready] when [isReady]).
  static WorkState derive({
    required String? status,
    bool isBlocked = false,
    bool isReady = false,
    bool sessionWaiting = false,
    bool needsInput = false,
    bool needsReview = false,
    String? lastError,
    String? closedReason,
  }) {
    final base = fromProvider(status);
    if (base == completed && _normalize(closedReason) == 'cancelled') {
      return cancelled;
    }
    if (base == cancelled || base == completed) return base;
    if (lastError != null && lastError.trim().isNotEmpty) return failed;
    if (isBlocked) return blocked;
    if (needsInput) return WorkState.needsInput;
    if (sessionWaiting) return waiting;
    if (needsReview) return review;
    if (base == queued && isReady) return ready;
    return base;
  }
}

/// One work item (Gas City bead). [rawState] keeps the provider status
/// string that [state] was derived from.
class WorkItem {
  const WorkItem({
    required this.id,
    required this.title,
    required this.state,
    this.rawState,
    this.projectId,
    this.runId,
    this.parentId,
    this.assignee,
    this.sessionId,
    this.isBlocked = false,
    this.labels = const [],
    this.dependsOn = const [],
    this.closedReason,
    this.createdAt,
    this.updatedAt,
    this.raw = const {},
  });

  final String id;
  final String title;
  final WorkState state;

  /// Provider status string exactly as received; null when absent.
  final String? rawState;
  final String? projectId;
  final String? runId;

  /// Parent work item (epic / convoy) when the provider reports one.
  final String? parentId;

  /// Agent or session the item is routed to (`gc.routed_to`).
  final String? assignee;

  /// Live session working the item (`gc.session_id`).
  final String? sessionId;
  final bool isBlocked;
  final List<String> labels;

  /// Ids this item depends on (blocking edges of the work graph).
  final List<String> dependsOn;
  final String? closedReason;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Untouched provider payload, including the `metadata` map.
  final Map<String, Object?> raw;

  @override
  String toString() => 'WorkItem($id, $state)';
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
