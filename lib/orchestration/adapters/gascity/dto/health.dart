import 'json_read.dart';

/// `GET /health` → `{status, version, city, uptime_sec}`.
class GcHealth {
  const GcHealth({
    this.status,
    this.version,
    this.city,
    this.uptimeSec,
    this.raw = const {},
  });

  factory GcHealth.fromJson(Map<String, Object?> json) => GcHealth(
    status: readText(json, 'status'),
    version: readText(json, 'version'),
    city: readText(json, 'city'),
    uptimeSec: readInt(json, 'uptime_sec'),
    raw: json,
  );

  final String? status;
  final String? version;
  final String? city;
  final int? uptimeSec;
  final Map<String, Object?> raw;

  /// True when the host reports itself healthy (`status: ok`).
  bool get isOk => status?.toLowerCase() == 'ok';
}

/// `agents` counts inside `/status`.
class GcStatusAgentCounts {
  const GcStatusAgentCounts({
    this.total,
    this.running,
    this.suspended,
    this.quarantined,
  });

  factory GcStatusAgentCounts.fromJson(Map<String, Object?> json) =>
      GcStatusAgentCounts(
        total: readInt(json, 'total'),
        running: readInt(json, 'running'),
        suspended: readInt(json, 'suspended'),
        quarantined: readInt(json, 'quarantined'),
      );

  final int? total;
  final int? running;
  final int? suspended;
  final int? quarantined;
}

/// `work` counts inside `/status`: `{in_progress, ready, open}`.
class GcStatusWorkCounts {
  const GcStatusWorkCounts({this.inProgress, this.ready, this.open});

  factory GcStatusWorkCounts.fromJson(Map<String, Object?> json) =>
      GcStatusWorkCounts(
        inProgress: readInt(json, 'in_progress'),
        ready: readInt(json, 'ready'),
        open: readInt(json, 'open'),
      );

  final int? inProgress;
  final int? ready;
  final int? open;
}

/// One entry of `/status` `agent_details[]`.
class GcStatusAgentDetail {
  const GcStatusAgentDetail({
    required this.name,
    this.qualifiedName,
    this.scope,
    this.running = false,
    this.suspended = false,
    this.draining = false,
    this.sessionName,
    this.groupName,
    this.scaleLabel,
    this.raw = const {},
  });

  factory GcStatusAgentDetail.fromJson(Map<String, Object?> json) =>
      GcStatusAgentDetail(
        name: readText(json, 'name') ?? readText(json, 'qualified_name') ?? '',
        qualifiedName: readText(json, 'qualified_name'),
        scope: readText(json, 'scope'),
        running: readBool(json, 'running') ?? false,
        suspended: readBool(json, 'suspended') ?? false,
        draining: readBool(json, 'draining') ?? false,
        sessionName: readText(json, 'session_name'),
        groupName: readText(json, 'group_name'),
        scaleLabel: readText(json, 'scale_label'),
        raw: json,
      );

  final String name;
  final String? qualifiedName;
  final String? scope;
  final bool running;
  final bool suspended;
  final bool draining;
  final String? sessionName;
  final String? groupName;
  final String? scaleLabel;
  final Map<String, Object?> raw;
}

/// One entry of `/status` `rig_details[]`.
class GcStatusRigDetail {
  const GcStatusRigDetail({
    required this.name,
    this.path,
    this.suspended = false,
    this.raw = const {},
  });

  factory GcStatusRigDetail.fromJson(Map<String, Object?> json) =>
      GcStatusRigDetail(
        name: readText(json, 'name') ?? '',
        path: readText(json, 'path'),
        suspended: readBool(json, 'suspended') ?? false,
        raw: json,
      );

  final String name;
  final String? path;
  final bool suspended;
  final Map<String, Object?> raw;
}

/// `GET /status` (`StatusBody`): city name, path, version, counts and the
/// per-agent and per-rig detail lists. Only the fields the product uses are
/// typed; everything else stays in [raw].
class GcStatus {
  const GcStatus({
    this.name,
    this.path,
    this.version,
    this.uptimeSec,
    this.suspended = false,
    this.agentCount,
    this.rigCount,
    this.running,
    this.agents = const GcStatusAgentCounts(),
    this.work = const GcStatusWorkCounts(),
    this.agentDetails = const [],
    this.rigDetails = const [],
    this.partial = false,
    this.partialErrors = const [],
    this.raw = const {},
  });

  factory GcStatus.fromJson(Map<String, Object?> json) => GcStatus(
    name: readText(json, 'name'),
    path: readText(json, 'path'),
    version: readText(json, 'version'),
    uptimeSec: readInt(json, 'uptime_sec'),
    suspended: readBool(json, 'suspended') ?? false,
    agentCount: readInt(json, 'agent_count'),
    rigCount: readInt(json, 'rig_count'),
    running: readInt(json, 'running'),
    agents: GcStatusAgentCounts.fromJson(readMapField(json, 'agents')),
    work: GcStatusWorkCounts.fromJson(readMapField(json, 'work')),
    agentDetails: readList(json, 'agent_details', GcStatusAgentDetail.fromJson),
    rigDetails: readList(json, 'rig_details', GcStatusRigDetail.fromJson),
    partial: readBool(json, 'partial') ?? false,
    partialErrors: readStringList(json, 'partial_errors'),
    raw: json,
  );

  final String? name;
  final String? path;
  final String? version;
  final int? uptimeSec;
  final bool suspended;
  final int? agentCount;
  final int? rigCount;

  /// Running agent count (top-level `running`).
  final int? running;
  final GcStatusAgentCounts agents;
  final GcStatusWorkCounts work;
  final List<GcStatusAgentDetail> agentDetails;
  final List<GcStatusRigDetail> rigDetails;
  final bool partial;
  final List<String> partialErrors;
  final Map<String, Object?> raw;
}

/// One entry of `/readiness` `items{}`: a provider or tool and whether it
/// is configured.
class GcReadinessItem {
  const GcReadinessItem({
    required this.name,
    this.kind,
    this.displayName,
    this.status,
    this.detail,
    this.raw = const {},
  });

  factory GcReadinessItem.fromJson(Map<String, Object?> json, {String? key}) =>
      GcReadinessItem(
        name: readText(json, 'name') ?? key ?? '',
        kind: readText(json, 'kind'),
        displayName: readText(json, 'display_name'),
        status: readText(json, 'status'),
        detail: readText(json, 'detail'),
        raw: json,
      );

  final String name;
  final String? kind;
  final String? displayName;
  final String? status;
  final String? detail;
  final Map<String, Object?> raw;

  bool get isConfigured => status?.toLowerCase() == 'configured';
}

/// `GET /readiness` → `{items: {name: ReadinessItem}}`. The recording keys
/// items by name; a list form is tolerated too.
class GcReadiness {
  const GcReadiness({this.items = const [], this.raw = const {}});

  factory GcReadiness.fromJson(Map<String, Object?> json) {
    final value = json['items'];
    final items = <GcReadinessItem>[];
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.value is Map) {
          items.add(
            GcReadinessItem.fromJson(
              readMap(entry.value),
              key: entry.key.toString(),
            ),
          );
        }
      }
    } else if (value is List) {
      items.addAll(readList(json, 'items', GcReadinessItem.fromJson));
    }
    return GcReadiness(items: items, raw: json);
  }

  final List<GcReadinessItem> items;
  final Map<String, Object?> raw;
}
