import 'json_read.dart';

/// `GET /sessions` item and `GET /session/{id}` (`SessionResponse`).
class GcSession {
  const GcSession({
    required this.id,
    this.kind,
    this.template,
    this.state,
    this.title,
    this.alias,
    this.provider,
    this.displayName,
    this.model,
    this.sessionName,
    this.workDir,
    this.createdAt,
    this.lastActive,
    this.attached = false,
    this.rig,
    this.pool,
    this.agentKind,
    this.running = false,
    this.reason,
    this.activeBead,
    this.activity,
    this.lastOutput,
    this.contextPct,
    this.configuredNamedSession = false,
    this.metadata = const {},
    this.raw = const {},
  });

  factory GcSession.fromJson(Map<String, Object?> json) => GcSession(
    id: readText(json, 'id') ?? '',
    kind: readText(json, 'kind'),
    template: readText(json, 'template'),
    state: readText(json, 'state'),
    title: readText(json, 'title'),
    alias: readText(json, 'alias'),
    provider: readText(json, 'provider'),
    displayName: readText(json, 'display_name'),
    model: readText(json, 'model'),
    sessionName: readText(json, 'session_name'),
    workDir: readText(json, 'work_dir'),
    createdAt: readDateTime(json, 'created_at'),
    lastActive: readDateTime(json, 'last_active'),
    attached: readBool(json, 'attached') ?? false,
    rig: readText(json, 'rig'),
    pool: readText(json, 'pool'),
    agentKind: readText(json, 'agent_kind'),
    running: readBool(json, 'running') ?? false,
    reason: readText(json, 'reason'),
    activeBead: readText(json, 'active_bead'),
    activity: readText(json, 'activity'),
    lastOutput: readText(json, 'last_output'),
    contextPct: readInt(json, 'context_pct'),
    configuredNamedSession: readBool(json, 'configured_named_session') ?? false,
    metadata: readStringMap(json, 'metadata'),
    raw: json,
  );

  /// Session bead id (`bl-wisp-qqpj`, `gc-58`).
  final String id;
  final String? kind;

  /// Agent template the session runs (`ocproof/gastown.polecat`).
  final String? template;

  /// Raw session state (`active`, ...).
  final String? state;
  final String? title;

  /// Agent identity alias (`ocproof/gastown.furiosa`).
  final String? alias;
  final String? provider;
  final String? displayName;
  final String? model;

  /// Named session (`gastown__polecat-gc-58`).
  final String? sessionName;
  final String? workDir;
  final DateTime? createdAt;
  final DateTime? lastActive;
  final bool attached;
  final String? rig;

  /// Pool short name (`polecat`) for pool instances.
  final String? pool;

  /// `role` for named agents, `pool` for pool instances.
  final String? agentKind;
  final bool running;
  final String? reason;
  final String? activeBead;
  final String? activity;
  final String? lastOutput;
  final int? contextPct;
  final bool configuredNamedSession;
  final Map<String, String> metadata;
  final Map<String, Object?> raw;

  /// True for pool instances (polecats, dogs).
  bool get isPoolInstance => agentKind == 'pool' || pool != null;
}

/// One entry of a session stream `turn` payload (`OutputTurn`):
/// `{role, text, timestamp}`.
class GcTurn {
  const GcTurn({
    required this.role,
    required this.text,
    this.timestamp,
    this.raw = const {},
  });

  factory GcTurn.fromJson(Map<String, Object?> json) => GcTurn(
    role: readText(json, 'role') ?? 'unknown',
    text: readString(json, 'text') ?? '',
    timestamp: readDateTime(json, 'timestamp'),
    raw: json,
  );

  /// `output`, `user`, ... as reported by the provider.
  final String role;
  final String text;
  final DateTime? timestamp;
  final Map<String, Object?> raw;
}

/// `GET /session/{id}/stream` `event: turn` payload and
/// `GET /session/{id}/transcript` (`SessionStreamMessageEvent`): the whole
/// transcript so far as `turns[]`.
class GcSessionTurn {
  const GcSessionTurn({
    required this.id,
    this.template,
    this.provider,
    this.format,
    this.turns = const [],
    this.raw = const {},
  });

  factory GcSessionTurn.fromJson(Map<String, Object?> json) => GcSessionTurn(
    id: readText(json, 'id') ?? '',
    template: readText(json, 'template'),
    provider: readText(json, 'provider'),
    format: readText(json, 'format'),
    turns: readList(json, 'turns', GcTurn.fromJson),
    raw: json,
  );

  final String id;
  final String? template;
  final String? provider;

  /// `text` in every recording; structured formats stay in [raw].
  final String? format;
  final List<GcTurn> turns;
  final Map<String, Object?> raw;

  /// The most recent turn's text, or null when the transcript is empty.
  String? get latestText => turns.isEmpty ? null : turns.last.text;
}
