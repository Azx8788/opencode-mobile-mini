import 'json_read.dart';

/// The `session` object embedded in an agent (`SessionInfo`):
/// `{name, last_activity, attached}`.
class GcAgentSession {
  const GcAgentSession({
    required this.name,
    this.lastActivity,
    this.attached = false,
    this.raw = const {},
  });

  factory GcAgentSession.fromJson(Map<String, Object?> json) => GcAgentSession(
    name: readText(json, 'name') ?? '',
    lastActivity: readDateTime(json, 'last_activity'),
    attached: readBool(json, 'attached') ?? false,
    raw: json,
  );

  /// Session (tmux-style) name, e.g. `gastown__boot`.
  final String name;
  final DateTime? lastActivity;
  final bool attached;
  final Map<String, Object?> raw;
}

/// `GET /agents` item and `GET /agent/{name}` (`AgentResponse`).
///
/// [state] is the raw Gas City agent state (`idle`, `stopped`, ...); the
/// mapper folds it with [running], [suspended] and the session into the
/// product [AgentState]. Pool templates (`ocproof/gastown.polecat`) appear
/// once with [pool] set; instances are sessions.
class GcAgent {
  const GcAgent({
    required this.name,
    this.state,
    this.running = false,
    this.suspended = false,
    this.available = true,
    this.unavailableReason,
    this.description,
    this.displayName,
    this.provider,
    this.model,
    this.pack,
    this.packDerived = false,
    this.pool,
    this.rig,
    this.session,
    this.activeBead,
    this.activity,
    this.lastOutput,
    this.contextPct,
    this.raw = const {},
  });

  factory GcAgent.fromJson(Map<String, Object?> json) => GcAgent(
    name: readText(json, 'name') ?? '',
    state: readText(json, 'state'),
    running: readBool(json, 'running') ?? false,
    suspended: readBool(json, 'suspended') ?? false,
    available: readBool(json, 'available') ?? true,
    unavailableReason: readText(json, 'unavailable_reason'),
    description: readText(json, 'description'),
    displayName: readText(json, 'display_name'),
    provider: readText(json, 'provider'),
    model: readText(json, 'model'),
    pack: readText(json, 'pack'),
    packDerived: readBool(json, 'pack_derived') ?? false,
    pool: readText(json, 'pool'),
    rig: readText(json, 'rig'),
    session: hasMap(json, 'session')
        ? GcAgentSession.fromJson(readMapField(json, 'session'))
        : null,
    activeBead: readText(json, 'active_bead'),
    activity: readText(json, 'activity'),
    lastOutput: readText(json, 'last_output'),
    contextPct: readInt(json, 'context_pct'),
    raw: json,
  );

  /// Qualified agent name (`gastown.mayor`, `ocproof/gastown.furiosa`).
  final String name;
  final String? state;
  final bool running;
  final bool suspended;
  final bool available;
  final String? unavailableReason;
  final String? description;

  /// Provider display name (`OpenCode`), not the agent's own label.
  final String? displayName;
  final String? provider;
  final String? model;
  final String? pack;
  final bool packDerived;

  /// Pool template this instance was spawned from, when it is a pool member.
  final String? pool;
  final String? rig;
  final GcAgentSession? session;
  final String? activeBead;
  final String? activity;
  final String? lastOutput;
  final int? contextPct;
  final Map<String, Object?> raw;
}
