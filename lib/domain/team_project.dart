/// Immutable engine-neutral AI Team snapshots. All fixture values are simulated.
library;

class TeamServer {
  const TeamServer({
    this.id = '',
    this.name = '',
    this.phone = false,
    this.online = true,
    this.laneCap = 8,
    this.chatWaiting = false,
    this.reason = '',
    this.memoryMb,
  });
  final String id;
  final String name;
  final bool phone;
  final bool online;
  final int laneCap;
  final bool chatWaiting;
  final String reason;
  final double? memoryMb;
  TeamServer copyWith({
    String? id,
    String? name,
    bool? phone,
    bool? online,
    int? laneCap,
    bool? chatWaiting,
    String? reason,
    double? memoryMb,
  }) => TeamServer(
    id: id ?? this.id,
    name: name ?? this.name,
    phone: phone ?? this.phone,
    online: online ?? this.online,
    laneCap: laneCap ?? this.laneCap,
    chatWaiting: chatWaiting ?? this.chatWaiting,
    reason: reason ?? this.reason,
    memoryMb: memoryMb ?? this.memoryMb,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'phone': phone,
    'online': online,
    'laneCap': laneCap,
    'chatWaiting': chatWaiting,
    'reason': reason,
    'memoryMb': memoryMb,
  };
  factory TeamServer.fromJson(Map<String, dynamic> j) => TeamServer(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '',
    phone: j['phone'] as bool? ?? false,
    online: j['online'] as bool? ?? true,
    laneCap: j['laneCap'] as int? ?? 8,
    chatWaiting: j['chatWaiting'] as bool? ?? false,
    reason: j['reason'] as String? ?? '',
    memoryMb: (j['memoryMb'] as num?)?.toDouble(),
  );
}

class TeamProjectRole {
  const TeamProjectRole({
    this.id = '',
    this.name = '',
    this.instructions = '',
    this.model = '',
    this.fallbackModel = '',
    this.readOnly = false,
  });
  final String id;
  final String name;
  final String instructions;
  final String model;
  final String fallbackModel;
  final bool readOnly;
  TeamProjectRole copyWith({
    String? id,
    String? name,
    String? instructions,
    String? model,
    String? fallbackModel,
    bool? readOnly,
  }) => TeamProjectRole(
    id: id ?? this.id,
    name: name ?? this.name,
    instructions: instructions ?? this.instructions,
    model: model ?? this.model,
    fallbackModel: fallbackModel ?? this.fallbackModel,
    readOnly: readOnly ?? this.readOnly,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'instructions': instructions,
    'model': model,
    'fallbackModel': fallbackModel,
    'readOnly': readOnly,
  };
  factory TeamProjectRole.fromJson(Map<String, dynamic> j) => TeamProjectRole(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '',
    instructions: j['instructions'] as String? ?? '',
    model: j['model'] as String? ?? '',
    fallbackModel: j['fallbackModel'] as String? ?? '',
    readOnly: j['readOnly'] as bool? ?? false,
  );
}

class TeamBudget {
  const TeamBudget({
    this.chosen = false,
    this.unlimited = false,
    this.daily,
    this.total,
    this.taskTokens,
  });
  final bool chosen;
  final bool unlimited;
  final double? daily;
  final double? total;
  final int? taskTokens;
  TeamBudget copyWith({
    bool? chosen,
    bool? unlimited,
    double? daily,
    double? total,
    int? taskTokens,
  }) => TeamBudget(
    chosen: chosen ?? this.chosen,
    unlimited: unlimited ?? this.unlimited,
    daily: daily ?? this.daily,
    total: total ?? this.total,
    taskTokens: taskTokens ?? this.taskTokens,
  );
  Map<String, Object?> toJson() => {
    'chosen': chosen,
    'unlimited': unlimited,
    'daily': daily,
    'total': total,
    'taskTokens': taskTokens,
  };
  factory TeamBudget.fromJson(Map<String, dynamic> j) => TeamBudget(
    chosen: j['chosen'] as bool? ?? false,
    unlimited: j['unlimited'] as bool? ?? false,
    daily: (j['daily'] as num?)?.toDouble(),
    total: (j['total'] as num?)?.toDouble(),
    taskTokens: j['taskTokens'] as int?,
  );
}

class TeamProjectSettings {
  const TeamProjectSettings({
    this.keepWorkingScreenOff = false,
    this.mode = '',
    this.maxLanes = 1,
    this.reviewLevel = 'milestones',
    this.chargingOnly = false,
    this.autoFix = true,
    this.maxFixRounds = 2,
    this.budget = const TeamBudget(),
  });
  final bool keepWorkingScreenOff;
  final String mode;
  final int maxLanes;
  final String reviewLevel;
  final bool chargingOnly;
  final bool autoFix;
  final int maxFixRounds;
  final TeamBudget budget;
  TeamProjectSettings copyWith({
    bool? keepWorkingScreenOff,
    String? mode,
    int? maxLanes,
    String? reviewLevel,
    bool? chargingOnly,
    bool? autoFix,
    int? maxFixRounds,
    TeamBudget? budget,
  }) => TeamProjectSettings(
    keepWorkingScreenOff: keepWorkingScreenOff ?? this.keepWorkingScreenOff,
    mode: mode ?? this.mode,
    maxLanes: maxLanes ?? this.maxLanes,
    reviewLevel: reviewLevel ?? this.reviewLevel,
    chargingOnly: chargingOnly ?? this.chargingOnly,
    autoFix: autoFix ?? this.autoFix,
    maxFixRounds: maxFixRounds ?? this.maxFixRounds,
    budget: budget ?? this.budget,
  );
  Map<String, Object?> toJson() => {
    'keepWorkingScreenOff': keepWorkingScreenOff,
    'mode': mode,
    'maxLanes': maxLanes,
    'reviewLevel': reviewLevel,
    'chargingOnly': chargingOnly,
    'autoFix': autoFix,
    'maxFixRounds': maxFixRounds,
    'budget': budget.toJson(),
  };
  factory TeamProjectSettings.fromJson(Map<String, dynamic> j) =>
      TeamProjectSettings(
        keepWorkingScreenOff: j['keepWorkingScreenOff'] as bool? ?? false,
        mode: j['mode'] as String? ?? '',
        maxLanes: j['maxLanes'] as int? ?? 1,
        reviewLevel: j['reviewLevel'] as String? ?? 'milestones',
        chargingOnly: j['chargingOnly'] as bool? ?? false,
        autoFix: j['autoFix'] as bool? ?? true,
        maxFixRounds: j['maxFixRounds'] as int? ?? 2,
        budget: TeamBudget.fromJson(
          Map<String, dynamic>.from(j['budget'] as Map? ?? {}),
        ),
      );
}

class TeamRepo {
  const TeamRepo({
    this.id = '',
    this.name = '',
    this.serverId = '',
    this.path = '',
    this.devCommit = 'fixture-base',
    this.mainCommit = 'fixture-base',
    this.checkCommand = 'flutter test',
    this.sharedRemote = false,
  });
  final String id;
  final String name;
  final String serverId;
  final String path;
  final String devCommit;
  final String mainCommit;
  final String checkCommand;
  final bool sharedRemote;
  TeamRepo copyWith({
    String? id,
    String? name,
    String? serverId,
    String? path,
    String? devCommit,
    String? mainCommit,
    String? checkCommand,
    bool? sharedRemote,
  }) => TeamRepo(
    id: id ?? this.id,
    name: name ?? this.name,
    serverId: serverId ?? this.serverId,
    path: path ?? this.path,
    devCommit: devCommit ?? this.devCommit,
    mainCommit: mainCommit ?? this.mainCommit,
    checkCommand: checkCommand ?? this.checkCommand,
    sharedRemote: sharedRemote ?? this.sharedRemote,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'serverId': serverId,
    'path': path,
    'devCommit': devCommit,
    'mainCommit': mainCommit,
    'checkCommand': checkCommand,
    'sharedRemote': sharedRemote,
  };
  factory TeamRepo.fromJson(Map<String, dynamic> j) => TeamRepo(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '',
    serverId: j['serverId'] as String? ?? '',
    path: j['path'] as String? ?? '',
    devCommit: j['devCommit'] as String? ?? 'fixture-base',
    mainCommit: j['mainCommit'] as String? ?? 'fixture-base',
    checkCommand: j['checkCommand'] as String? ?? 'flutter test',
    sharedRemote: j['sharedRemote'] as bool? ?? false,
  );
}

class TeamMilestone {
  const TeamMilestone({
    this.id = '',
    this.title = '',
    this.criteria = const [],
    this.accepted = false,
  });
  final String id;
  final String title;
  final List<String> criteria;
  final bool accepted;
  TeamMilestone copyWith({
    String? id,
    String? title,
    List<String>? criteria,
    bool? accepted,
  }) => TeamMilestone(
    id: id ?? this.id,
    title: title ?? this.title,
    criteria: criteria ?? this.criteria,
    accepted: accepted ?? this.accepted,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'criteria': criteria,
    'accepted': accepted,
  };
  factory TeamMilestone.fromJson(Map<String, dynamic> j) => TeamMilestone(
    id: j['id'] as String? ?? '',
    title: j['title'] as String? ?? '',
    criteria: List.unmodifiable(
      (j['criteria'] as List? ?? []).map((v) => v as String),
    ),
    accepted: j['accepted'] as bool? ?? false,
  );
}

class TeamSpec {
  const TeamSpec({
    this.contextFiles = const [],
    this.version = 1,
    this.goal = '',
    this.constraints = '',
    this.decisions = '',
    this.outOfScope = '',
    this.milestones = const [],
    this.approvedBy = '',
    this.approvedAt = '',
  });
  final List<String> contextFiles;
  final int version;
  final String goal;
  final String constraints;
  final String decisions;
  final String outOfScope;
  final List<TeamMilestone> milestones;
  final String approvedBy;
  final String approvedAt;
  TeamSpec copyWith({
    List<String>? contextFiles,
    int? version,
    String? goal,
    String? constraints,
    String? decisions,
    String? outOfScope,
    List<TeamMilestone>? milestones,
    String? approvedBy,
    String? approvedAt,
  }) => TeamSpec(
    contextFiles: contextFiles ?? this.contextFiles,
    version: version ?? this.version,
    goal: goal ?? this.goal,
    constraints: constraints ?? this.constraints,
    decisions: decisions ?? this.decisions,
    outOfScope: outOfScope ?? this.outOfScope,
    milestones: milestones ?? this.milestones,
    approvedBy: approvedBy ?? this.approvedBy,
    approvedAt: approvedAt ?? this.approvedAt,
  );
  Map<String, Object?> toJson() => {
    'contextFiles': contextFiles,
    'version': version,
    'goal': goal,
    'constraints': constraints,
    'decisions': decisions,
    'outOfScope': outOfScope,
    'milestones': milestones.map((v) => v.toJson()).toList(),
    'approvedBy': approvedBy,
    'approvedAt': approvedAt,
  };
  factory TeamSpec.fromJson(Map<String, dynamic> j) => TeamSpec(
    contextFiles: List<String>.unmodifiable(j['contextFiles'] as List? ?? []),
    version: j['version'] as int? ?? 1,
    goal: j['goal'] as String? ?? '',
    constraints: j['constraints'] as String? ?? '',
    decisions: j['decisions'] as String? ?? '',
    outOfScope: j['outOfScope'] as String? ?? '',
    milestones: List.unmodifiable(
      (j['milestones'] as List? ?? []).map(
        (v) => TeamMilestone.fromJson(Map<String, dynamic>.from(v as Map)),
      ),
    ),
    approvedBy: j['approvedBy'] as String? ?? '',
    approvedAt: j['approvedAt'] as String? ?? '',
  );
}

class TeamPhase {
  const TeamPhase({
    this.id = '',
    this.milestoneId = '',
    this.title = '',
    this.risky = false,
    this.accepted = false,
  });
  final String id;
  final String milestoneId;
  final String title;
  final bool risky;
  final bool accepted;
  TeamPhase copyWith({
    String? id,
    String? milestoneId,
    String? title,
    bool? risky,
    bool? accepted,
  }) => TeamPhase(
    id: id ?? this.id,
    milestoneId: milestoneId ?? this.milestoneId,
    title: title ?? this.title,
    risky: risky ?? this.risky,
    accepted: accepted ?? this.accepted,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'milestoneId': milestoneId,
    'title': title,
    'risky': risky,
    'accepted': accepted,
  };
  factory TeamPhase.fromJson(Map<String, dynamic> j) => TeamPhase(
    id: j['id'] as String? ?? '',
    milestoneId: j['milestoneId'] as String? ?? '',
    title: j['title'] as String? ?? '',
    risky: j['risky'] as bool? ?? false,
    accepted: j['accepted'] as bool? ?? false,
  );
}

class TeamFinding {
  const TeamFinding({
    this.id = '',
    this.severity = 'major',
    this.criterion = '',
    this.location = '',
    this.text = '',
    this.status = 'open',
  });
  final String id;
  final String severity;
  final String criterion;
  final String location;
  final String text;
  final String status;
  TeamFinding copyWith({
    String? id,
    String? severity,
    String? criterion,
    String? location,
    String? text,
    String? status,
  }) => TeamFinding(
    id: id ?? this.id,
    severity: severity ?? this.severity,
    criterion: criterion ?? this.criterion,
    location: location ?? this.location,
    text: text ?? this.text,
    status: status ?? this.status,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'severity': severity,
    'criterion': criterion,
    'location': location,
    'text': text,
    'status': status,
  };
  factory TeamFinding.fromJson(Map<String, dynamic> j) => TeamFinding(
    id: j['id'] as String? ?? '',
    severity: j['severity'] as String? ?? 'major',
    criterion: j['criterion'] as String? ?? '',
    location: j['location'] as String? ?? '',
    text: j['text'] as String? ?? '',
    status: j['status'] as String? ?? 'open',
  );
}

class TeamMessage {
  const TeamMessage({
    this.id = '',
    this.actor = 'person',
    this.text = '',
    this.at = '',
  });
  final String id;
  final String actor;
  final String text;
  final String at;
  TeamMessage copyWith({String? id, String? actor, String? text, String? at}) =>
      TeamMessage(
        id: id ?? this.id,
        actor: actor ?? this.actor,
        text: text ?? this.text,
        at: at ?? this.at,
      );
  Map<String, Object?> toJson() => {
    'id': id,
    'actor': actor,
    'text': text,
    'at': at,
  };
  factory TeamMessage.fromJson(Map<String, dynamic> j) => TeamMessage(
    id: j['id'] as String? ?? '',
    actor: j['actor'] as String? ?? 'person',
    text: j['text'] as String? ?? '',
    at: j['at'] as String? ?? '',
  );
}

class TeamTask {
  const TeamTask({
    this.criterionResults = const [],
    this.id = '',
    this.title = '',
    this.phaseId = '',
    this.roleId = 'frontend',
    this.repoId = '',
    this.serverId = '',
    this.status = 'queued',
    this.dependsOn = const [],
    this.criteria = const [],
    this.branch = '',
    this.reason = '',
    this.changedAt = '',
    this.steps = 0,
    this.tokens = 0,
    this.fixRounds = 0,
    this.affected = false,
    this.findings = const [],
    this.messages = const [],
    this.diff = '',
  });
  final List<TeamCriterionResult> criterionResults;
  final String id;
  final String title;
  final String phaseId;
  final String roleId;
  final String repoId;
  final String serverId;
  final String status;
  final List<String> dependsOn;
  final List<String> criteria;
  final String branch;
  final String reason;
  final String changedAt;
  final int steps;
  final int tokens;
  final int fixRounds;
  final bool affected;
  final List<TeamFinding> findings;
  final List<TeamMessage> messages;
  final String diff;
  TeamTask copyWith({
    List<TeamCriterionResult>? criterionResults,
    String? id,
    String? title,
    String? phaseId,
    String? roleId,
    String? repoId,
    String? serverId,
    String? status,
    List<String>? dependsOn,
    List<String>? criteria,
    String? branch,
    String? reason,
    String? changedAt,
    int? steps,
    int? tokens,
    int? fixRounds,
    bool? affected,
    List<TeamFinding>? findings,
    List<TeamMessage>? messages,
    String? diff,
  }) => TeamTask(
    criterionResults: criterionResults ?? this.criterionResults,
    id: id ?? this.id,
    title: title ?? this.title,
    phaseId: phaseId ?? this.phaseId,
    roleId: roleId ?? this.roleId,
    repoId: repoId ?? this.repoId,
    serverId: serverId ?? this.serverId,
    status: status ?? this.status,
    dependsOn: dependsOn ?? this.dependsOn,
    criteria: criteria ?? this.criteria,
    branch: branch ?? this.branch,
    reason: reason ?? this.reason,
    changedAt: changedAt ?? this.changedAt,
    steps: steps ?? this.steps,
    tokens: tokens ?? this.tokens,
    fixRounds: fixRounds ?? this.fixRounds,
    affected: affected ?? this.affected,
    findings: findings ?? this.findings,
    messages: messages ?? this.messages,
    diff: diff ?? this.diff,
  );
  Map<String, Object?> toJson() => {
    'criterionResults': criterionResults.map((v) => v.toJson()).toList(),
    'id': id,
    'title': title,
    'phaseId': phaseId,
    'roleId': roleId,
    'repoId': repoId,
    'serverId': serverId,
    'status': status,
    'dependsOn': dependsOn,
    'criteria': criteria,
    'branch': branch,
    'reason': reason,
    'changedAt': changedAt,
    'steps': steps,
    'tokens': tokens,
    'fixRounds': fixRounds,
    'affected': affected,
    'findings': findings.map((v) => v.toJson()).toList(),
    'messages': messages.map((v) => v.toJson()).toList(),
    'diff': diff,
  };
  factory TeamTask.fromJson(Map<String, dynamic> j) => TeamTask(
    criterionResults: List<TeamCriterionResult>.unmodifiable(
      (j['criterionResults'] as List? ?? []).map(
        (v) =>
            TeamCriterionResult.fromJson(Map<String, dynamic>.from(v as Map)),
      ),
    ),
    id: j['id'] as String? ?? '',
    title: j['title'] as String? ?? '',
    phaseId: j['phaseId'] as String? ?? '',
    roleId: j['roleId'] as String? ?? 'frontend',
    repoId: j['repoId'] as String? ?? '',
    serverId: j['serverId'] as String? ?? '',
    status: j['status'] as String? ?? 'queued',
    dependsOn: List.unmodifiable(
      (j['dependsOn'] as List? ?? []).map((v) => v as String),
    ),
    criteria: List.unmodifiable(
      (j['criteria'] as List? ?? []).map((v) => v as String),
    ),
    branch: j['branch'] as String? ?? '',
    reason: j['reason'] as String? ?? '',
    changedAt: j['changedAt'] as String? ?? '',
    steps: j['steps'] as int? ?? 0,
    tokens: j['tokens'] as int? ?? 0,
    fixRounds: j['fixRounds'] as int? ?? 0,
    affected: j['affected'] as bool? ?? false,
    findings: List.unmodifiable(
      (j['findings'] as List? ?? []).map(
        (v) => TeamFinding.fromJson(Map<String, dynamic>.from(v as Map)),
      ),
    ),
    messages: List.unmodifiable(
      (j['messages'] as List? ?? []).map(
        (v) => TeamMessage.fromJson(Map<String, dynamic>.from(v as Map)),
      ),
    ),
    diff: j['diff'] as String? ?? '',
  );
}

class TeamRequest {
  const TeamRequest({
    this.id = '',
    this.kind = 'question',
    this.title = '',
    this.taskId = '',
    this.phaseId = '',
    this.createdAt = '',
    this.answered = false,
    this.answer = '',
  });
  final String id;
  final String kind;
  final String title;
  final String taskId;
  final String phaseId;
  final String createdAt;
  final bool answered;
  final String answer;
  TeamRequest copyWith({
    String? id,
    String? kind,
    String? title,
    String? taskId,
    String? phaseId,
    String? createdAt,
    bool? answered,
    String? answer,
  }) => TeamRequest(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    title: title ?? this.title,
    taskId: taskId ?? this.taskId,
    phaseId: phaseId ?? this.phaseId,
    createdAt: createdAt ?? this.createdAt,
    answered: answered ?? this.answered,
    answer: answer ?? this.answer,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'title': title,
    'taskId': taskId,
    'phaseId': phaseId,
    'createdAt': createdAt,
    'answered': answered,
    'answer': answer,
  };
  factory TeamRequest.fromJson(Map<String, dynamic> j) => TeamRequest(
    id: j['id'] as String? ?? '',
    kind: j['kind'] as String? ?? 'question',
    title: j['title'] as String? ?? '',
    taskId: j['taskId'] as String? ?? '',
    phaseId: j['phaseId'] as String? ?? '',
    createdAt: j['createdAt'] as String? ?? '',
    answered: j['answered'] as bool? ?? false,
    answer: j['answer'] as String? ?? '',
  );
}

class TeamMergeItem {
  const TeamMergeItem({
    this.id = '',
    this.taskId = '',
    this.repoId = '',
    this.status = 'queued',
    this.reason = '',
    this.checksPassed = false,
  });
  final String id;
  final String taskId;
  final String repoId;
  final String status;
  final String reason;
  final bool checksPassed;
  TeamMergeItem copyWith({
    String? id,
    String? taskId,
    String? repoId,
    String? status,
    String? reason,
    bool? checksPassed,
  }) => TeamMergeItem(
    id: id ?? this.id,
    taskId: taskId ?? this.taskId,
    repoId: repoId ?? this.repoId,
    status: status ?? this.status,
    reason: reason ?? this.reason,
    checksPassed: checksPassed ?? this.checksPassed,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'taskId': taskId,
    'repoId': repoId,
    'status': status,
    'reason': reason,
    'checksPassed': checksPassed,
  };
  factory TeamMergeItem.fromJson(Map<String, dynamic> j) => TeamMergeItem(
    id: j['id'] as String? ?? '',
    taskId: j['taskId'] as String? ?? '',
    repoId: j['repoId'] as String? ?? '',
    status: j['status'] as String? ?? 'queued',
    reason: j['reason'] as String? ?? '',
    checksPassed: j['checksPassed'] as bool? ?? false,
  );
}

class TeamProjectReceipt {
  const TeamProjectReceipt({
    this.id = '',
    this.kind = '',
    this.repoId = '',
    this.before = '',
    this.after = '',
    this.at = '',
    this.actor = 'person',
  });
  final String id;
  final String kind;
  final String repoId;
  final String before;
  final String after;
  final String at;
  final String actor;
  TeamProjectReceipt copyWith({
    String? id,
    String? kind,
    String? repoId,
    String? before,
    String? after,
    String? at,
    String? actor,
  }) => TeamProjectReceipt(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    repoId: repoId ?? this.repoId,
    before: before ?? this.before,
    after: after ?? this.after,
    at: at ?? this.at,
    actor: actor ?? this.actor,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'repoId': repoId,
    'before': before,
    'after': after,
    'at': at,
    'actor': actor,
  };
  factory TeamProjectReceipt.fromJson(Map<String, dynamic> j) =>
      TeamProjectReceipt(
        id: j['id'] as String? ?? '',
        kind: j['kind'] as String? ?? '',
        repoId: j['repoId'] as String? ?? '',
        before: j['before'] as String? ?? '',
        after: j['after'] as String? ?? '',
        at: j['at'] as String? ?? '',
        actor: j['actor'] as String? ?? 'person',
      );
}

class TeamTimelineEvent {
  const TeamTimelineEvent({
    this.id = '',
    this.kind = '',
    this.text = '',
    this.actor = 'fixture',
    this.at = '',
    this.taskId = '',
  });
  final String id;
  final String kind;
  final String text;
  final String actor;
  final String at;
  final String taskId;
  TeamTimelineEvent copyWith({
    String? id,
    String? kind,
    String? text,
    String? actor,
    String? at,
    String? taskId,
  }) => TeamTimelineEvent(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    text: text ?? this.text,
    actor: actor ?? this.actor,
    at: at ?? this.at,
    taskId: taskId ?? this.taskId,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'text': text,
    'actor': actor,
    'at': at,
    'taskId': taskId,
  };
  factory TeamTimelineEvent.fromJson(Map<String, dynamic> j) =>
      TeamTimelineEvent(
        id: j['id'] as String? ?? '',
        kind: j['kind'] as String? ?? '',
        text: j['text'] as String? ?? '',
        actor: j['actor'] as String? ?? 'fixture',
        at: j['at'] as String? ?? '',
        taskId: j['taskId'] as String? ?? '',
      );
}

/// Latest durable planner checkpoint, separate from project workflow status.
class TeamPlanningState {
  const TeamPlanningState({
    this.jobId = '',
    this.stage = '',
    this.reason = '',
    this.updatedAt = '',
  });
  final String jobId;
  final String stage;
  final String reason;
  final String updatedAt;
  Map<String, Object?> toJson() => {
    'jobId': jobId,
    'stage': stage,
    'reason': reason,
    'updatedAt': updatedAt,
  };
  factory TeamPlanningState.fromJson(Map<String, dynamic> j) =>
      TeamPlanningState(
        jobId: j['jobId'] as String? ?? '',
        stage: j['stage'] as String? ?? '',
        reason: j['reason'] as String? ?? '',
        updatedAt: j['updatedAt'] as String? ?? '',
      );
}

class TeamProject {
  const TeamProject({
    this.budgetWarning = false,
    this.id = '',
    this.name = '',
    this.status = 'spec',
    this.revision = 0,
    this.settings = const TeamProjectSettings(),
    this.repos = const [],
    this.specDraft = const TeamSpec(),
    this.specVersions = const [],
    this.phases = const [],
    this.tasks = const [],
    this.requests = const [],
    this.mergeQueue = const [],
    this.receipts = const [],
    this.timeline = const [],
    this.planningState,
    this.timelineTruncated = false,
    this.spent = 0,
    this.spentToday = 0,
    this.spendDay = '',
    this.digestReadAt = '',
    this.updatedAt = '',
    this.planApproved = false,
    this.quickTask = false,
    this.usageReported = false,
    this.simulated = true,
  });
  final bool budgetWarning;
  final String id;
  final String name;
  final String status;
  final int revision;
  final TeamProjectSettings settings;
  final List<TeamRepo> repos;
  final TeamSpec specDraft;
  final List<TeamSpec> specVersions;
  final List<TeamPhase> phases;
  final List<TeamTask> tasks;
  final List<TeamRequest> requests;
  final List<TeamMergeItem> mergeQueue;
  final List<TeamProjectReceipt> receipts;
  final List<TeamTimelineEvent> timeline;
  final TeamPlanningState? planningState;
  final bool timelineTruncated;
  final double spent;
  final double spentToday;
  final String spendDay;
  final String digestReadAt;
  final String updatedAt;
  final bool planApproved;
  final bool quickTask;
  final bool usageReported;
  final bool simulated;
  TeamProject copyWith({
    bool? budgetWarning,
    String? id,
    String? name,
    String? status,
    int? revision,
    TeamProjectSettings? settings,
    List<TeamRepo>? repos,
    TeamSpec? specDraft,
    List<TeamSpec>? specVersions,
    List<TeamPhase>? phases,
    List<TeamTask>? tasks,
    List<TeamRequest>? requests,
    List<TeamMergeItem>? mergeQueue,
    List<TeamProjectReceipt>? receipts,
    List<TeamTimelineEvent>? timeline,
    TeamPlanningState? planningState,
    bool? timelineTruncated,
    double? spent,
    double? spentToday,
    String? spendDay,
    String? digestReadAt,
    String? updatedAt,
    bool? planApproved,
    bool? quickTask,
    bool? usageReported,
    bool? simulated,
  }) => TeamProject(
    budgetWarning: budgetWarning ?? this.budgetWarning,
    id: id ?? this.id,
    name: name ?? this.name,
    status: status ?? this.status,
    revision: revision ?? this.revision,
    settings: settings ?? this.settings,
    repos: repos ?? this.repos,
    specDraft: specDraft ?? this.specDraft,
    specVersions: specVersions ?? this.specVersions,
    phases: phases ?? this.phases,
    tasks: tasks ?? this.tasks,
    requests: requests ?? this.requests,
    mergeQueue: mergeQueue ?? this.mergeQueue,
    receipts: receipts ?? this.receipts,
    timeline: timeline ?? this.timeline,
    planningState: planningState ?? this.planningState,
    timelineTruncated: timelineTruncated ?? this.timelineTruncated,
    spent: spent ?? this.spent,
    spentToday: spentToday ?? this.spentToday,
    spendDay: spendDay ?? this.spendDay,
    digestReadAt: digestReadAt ?? this.digestReadAt,
    updatedAt: updatedAt ?? this.updatedAt,
    planApproved: planApproved ?? this.planApproved,
    quickTask: quickTask ?? this.quickTask,
    usageReported: usageReported ?? this.usageReported,
    simulated: simulated ?? this.simulated,
  );
  Map<String, Object?> toJson() => {
    'budgetWarning': budgetWarning,
    'id': id,
    'name': name,
    'status': status,
    'revision': revision,
    'settings': settings.toJson(),
    'repos': repos.map((v) => v.toJson()).toList(),
    'specDraft': specDraft.toJson(),
    'specVersions': specVersions.map((v) => v.toJson()).toList(),
    'phases': phases.map((v) => v.toJson()).toList(),
    'tasks': tasks.map((v) => v.toJson()).toList(),
    'requests': requests.map((v) => v.toJson()).toList(),
    'mergeQueue': mergeQueue.map((v) => v.toJson()).toList(),
    'receipts': receipts.map((v) => v.toJson()).toList(),
    'timeline': timeline.map((v) => v.toJson()).toList(),
    'planningState': planningState?.toJson(),
    'timelineTruncated': timelineTruncated,
    'spent': spent,
    'spentToday': spentToday,
    'spendDay': spendDay,
    'digestReadAt': digestReadAt,
    'updatedAt': updatedAt,
    'planApproved': planApproved,
    'quickTask': quickTask,
    'usageReported': usageReported,
    'simulated': simulated,
  };
  factory TeamProject.fromJson(Map<String, dynamic> j) => TeamProject(
    budgetWarning: j['budgetWarning'] as bool? ?? false,
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '',
    status: j['status'] as String? ?? 'spec',
    revision: j['revision'] as int? ?? 0,
    settings: TeamProjectSettings.fromJson(
      Map<String, dynamic>.from(j['settings'] as Map? ?? {}),
    ),
    repos: List.unmodifiable(
      (j['repos'] as List? ?? []).map(
        (v) => TeamRepo.fromJson(Map<String, dynamic>.from(v as Map)),
      ),
    ),
    specDraft: TeamSpec.fromJson(
      Map<String, dynamic>.from(j['specDraft'] as Map? ?? {}),
    ),
    specVersions: List.unmodifiable(
      (j['specVersions'] as List? ?? []).map(
        (v) => TeamSpec.fromJson(Map<String, dynamic>.from(v as Map)),
      ),
    ),
    phases: List.unmodifiable(
      (j['phases'] as List? ?? []).map(
        (v) => TeamPhase.fromJson(Map<String, dynamic>.from(v as Map)),
      ),
    ),
    tasks: List.unmodifiable(
      (j['tasks'] as List? ?? []).map(
        (v) => TeamTask.fromJson(Map<String, dynamic>.from(v as Map)),
      ),
    ),
    requests: List.unmodifiable(
      (j['requests'] as List? ?? []).map(
        (v) => TeamRequest.fromJson(Map<String, dynamic>.from(v as Map)),
      ),
    ),
    mergeQueue: List.unmodifiable(
      (j['mergeQueue'] as List? ?? []).map(
        (v) => TeamMergeItem.fromJson(Map<String, dynamic>.from(v as Map)),
      ),
    ),
    receipts: List.unmodifiable(
      (j['receipts'] as List? ?? []).map(
        (v) => TeamProjectReceipt.fromJson(Map<String, dynamic>.from(v as Map)),
      ),
    ),
    timeline: List.unmodifiable(
      (j['timeline'] as List? ?? []).map(
        (v) => TeamTimelineEvent.fromJson(Map<String, dynamic>.from(v as Map)),
      ),
    ),
    planningState: j['planningState'] == null
        ? null
        : TeamPlanningState.fromJson(
            Map<String, dynamic>.from(j['planningState'] as Map),
          ),
    timelineTruncated: j['timelineTruncated'] as bool? ?? false,
    spent: (j['spent'] as num?)?.toDouble() ?? 0,
    spentToday: (j['spentToday'] as num?)?.toDouble() ?? 0,
    spendDay: j['spendDay'] as String? ?? '',
    digestReadAt: j['digestReadAt'] as String? ?? '',
    updatedAt: j['updatedAt'] as String? ?? '',
    planApproved: j['planApproved'] as bool? ?? false,
    quickTask: j['quickTask'] as bool? ?? false,
    usageReported: j['usageReported'] as bool? ?? false,
    simulated: j['simulated'] as bool? ?? true,
  );
}

class TeamWorkspace {
  const TeamWorkspace({
    this.defaultSettings,
    this.schemaVersion = 1,
    this.revision = 0,
    this.projects = const [],
    this.servers = const [],
    this.roles = const [],
    this.simulated = true,
  });
  final TeamProjectSettings? defaultSettings;
  final int schemaVersion;
  final int revision;
  final List<TeamProject> projects;
  final List<TeamServer> servers;
  final List<TeamProjectRole> roles;
  final bool simulated;
  TeamWorkspace copyWith({
    TeamProjectSettings? defaultSettings,
    int? schemaVersion,
    int? revision,
    List<TeamProject>? projects,
    List<TeamServer>? servers,
    List<TeamProjectRole>? roles,
    bool? simulated,
  }) => TeamWorkspace(
    defaultSettings: defaultSettings ?? this.defaultSettings,
    schemaVersion: schemaVersion ?? this.schemaVersion,
    revision: revision ?? this.revision,
    projects: projects ?? this.projects,
    servers: servers ?? this.servers,
    roles: roles ?? this.roles,
    simulated: simulated ?? this.simulated,
  );
  Map<String, Object?> toJson() => {
    'defaultSettings': defaultSettings?.toJson(),
    'schemaVersion': schemaVersion,
    'revision': revision,
    'projects': projects.map((v) => v.toJson()).toList(),
    'servers': servers.map((v) => v.toJson()).toList(),
    'roles': roles.map((v) => v.toJson()).toList(),
    'simulated': simulated,
  };
  factory TeamWorkspace.fromJson(Map<String, dynamic> j) => TeamWorkspace(
    defaultSettings: j['defaultSettings'] is Map
        ? TeamProjectSettings.fromJson(
            Map<String, dynamic>.from(j['defaultSettings'] as Map),
          )
        : null,
    schemaVersion: j['schemaVersion'] as int? ?? 1,
    revision: j['revision'] as int? ?? 0,
    projects: List.unmodifiable(
      (j['projects'] as List? ?? []).map(
        (v) => TeamProject.fromJson(Map<String, dynamic>.from(v as Map)),
      ),
    ),
    servers: List.unmodifiable(
      (j['servers'] as List? ?? []).map(
        (v) => TeamServer.fromJson(Map<String, dynamic>.from(v as Map)),
      ),
    ),
    roles: List.unmodifiable(
      (j['roles'] as List? ?? []).map(
        (v) => TeamProjectRole.fromJson(Map<String, dynamic>.from(v as Map)),
      ),
    ),
    simulated: j['simulated'] as bool? ?? true,
  );
}

/// One reported read-only acceptance result. Absence means not checked.
class TeamCriterionResult {
  const TeamCriterionResult({required this.criterion, required this.status});
  final String criterion;

  /// met, unmet, or notApplicable; these are simulated in the fixture.
  final String status;
  Map<String, Object?> toJson() => {'criterion': criterion, 'status': status};
  factory TeamCriterionResult.fromJson(Map<String, dynamic> j) =>
      TeamCriterionResult(
        criterion: j['criterion'] as String? ?? '',
        status: j['status'] as String? ?? 'unmet',
      );
}
