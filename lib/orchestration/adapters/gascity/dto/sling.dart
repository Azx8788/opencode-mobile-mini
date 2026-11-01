import 'json_read.dart';

/// `POST /sling` body (`SlingInputBody`): route a bead or formula at a
/// target pool or agent. Only [target] is required.
class GcSlingRequest {
  const GcSlingRequest({
    required this.target,
    this.bead,
    this.formula,
    this.title,
    this.rig,
    this.merge,
    this.force = false,
    this.noConvoy = false,
    this.noFormula = false,
    this.owned = false,
    this.reassign = false,
    this.scopeKind,
    this.scopeRef,
    this.attachedBeadId,
    this.vars = const {},
  });

  factory GcSlingRequest.fromJson(Map<String, Object?> json) => GcSlingRequest(
    target: readText(json, 'target') ?? '',
    bead: readText(json, 'bead'),
    formula: readText(json, 'formula'),
    title: readText(json, 'title'),
    rig: readText(json, 'rig'),
    merge: readText(json, 'merge'),
    force: readBool(json, 'force') ?? false,
    noConvoy: readBool(json, 'no_convoy') ?? false,
    noFormula: readBool(json, 'no_formula') ?? false,
    owned: readBool(json, 'owned') ?? false,
    reassign: readBool(json, 'reassign') ?? false,
    scopeKind: readText(json, 'scope_kind'),
    scopeRef: readText(json, 'scope_ref'),
    attachedBeadId: readText(json, 'attached_bead_id'),
    vars: readStringMap(json, 'vars'),
  );

  final String target;
  final String? bead;
  final String? formula;
  final String? title;
  final String? rig;
  final String? merge;
  final bool force;
  final bool noConvoy;
  final bool noFormula;
  final bool owned;
  final bool reassign;
  final String? scopeKind;
  final String? scopeRef;
  final String? attachedBeadId;
  final Map<String, String> vars;

  /// Wire form; false flags and null fields are omitted.
  Map<String, Object?> toJson() => {
    'target': target,
    if (bead != null) 'bead': bead,
    if (formula != null) 'formula': formula,
    if (title != null) 'title': title,
    if (rig != null) 'rig': rig,
    if (merge != null) 'merge': merge,
    if (force) 'force': true,
    if (noConvoy) 'no_convoy': true,
    if (noFormula) 'no_formula': true,
    if (owned) 'owned': true,
    if (reassign) 'reassign': true,
    if (scopeKind != null) 'scope_kind': scopeKind,
    if (scopeRef != null) 'scope_ref': scopeRef,
    if (attachedBeadId != null) 'attached_bead_id': attachedBeadId,
    if (vars.isNotEmpty) 'vars': vars,
  };
}

/// `POST /sling` response (`SlingResponse`): `{status: "slung", target,
/// bead, mode: "direct", dashboard_url, formula, run{run_id,kind,status},
/// warnings[]}`. The `gc sling --json` CLI shape (`bead_id`, `convoy_id`,
/// `ok`) is folded in so both recordings decode.
class GcSlingResponse {
  const GcSlingResponse({
    this.status,
    this.target,
    this.bead,
    this.mode,
    this.formula,
    this.dashboardUrl,
    this.rootBeadId,
    this.attachedBeadId,
    this.workflowId,
    this.convoyId,
    this.runId,
    this.runKind,
    this.runStatus,
    this.warnings = const [],
    this.raw = const {},
  });

  factory GcSlingResponse.fromJson(Map<String, Object?> json) {
    final run = readMapField(json, 'run');
    final ok = readBool(json, 'ok') ?? readBool(json, 'success');
    return GcSlingResponse(
      status:
          readText(json, 'status') ??
          (ok == null
              ? null
              : ok
              ? 'slung'
              : 'failed'),
      target: readText(json, 'target'),
      bead: readText(json, 'bead') ?? readText(json, 'bead_id'),
      mode: readText(json, 'mode') ?? readText(json, 'method'),
      formula: readText(json, 'formula'),
      dashboardUrl: readText(json, 'dashboard_url'),
      rootBeadId: readText(json, 'root_bead_id'),
      attachedBeadId: readText(json, 'attached_bead_id'),
      workflowId: readText(json, 'workflow_id'),
      convoyId: readText(json, 'convoy_id'),
      runId: readText(run, 'run_id'),
      runKind: readText(run, 'kind'),
      runStatus: readText(run, 'status'),
      warnings: readStringList(json, 'warnings'),
      raw: json,
    );
  }

  final String? status;
  final String? target;
  final String? bead;
  final String? mode;
  final String? formula;
  final String? dashboardUrl;
  final String? rootBeadId;
  final String? attachedBeadId;
  final String? workflowId;
  final String? convoyId;
  final String? runId;
  final String? runKind;
  final String? runStatus;
  final List<String> warnings;
  final Map<String, Object?> raw;

  /// True when the host accepted the sling.
  bool get isSlung => status == 'slung' || status == 'queued';
}
