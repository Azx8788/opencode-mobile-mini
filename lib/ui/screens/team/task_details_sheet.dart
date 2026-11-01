/// Task details (slice-P3.5): the sheet behind "Task details" in a team
/// task's conversation menu. The task is its conversation (the team
/// decision: a task is a chat, its workers are sub-agents); this sheet
/// holds every fact the retired run page (team-run and its Overview,
/// Work, Agents and Timeline tabs) showed that the conversation does not:
///
/// - where the task stands: its state word, how many steps are done and
///   for how long (or since the hand-off to merge), then the four-stage
///   line (Waiting · Working · Reviewing · Done);
/// - its steps as the dependency graph in rows ([KitWorkGraph]), each
///   opening its Work sheet (owner, age, what it waits on, why);
///   a formula run that tracks no work lists its own stages;
/// - that the host reports no cost for one task (the team page has the
///   day's estimate, P5.2) and the host's supervision policy;
/// - last, folded, the technical details: the host's term, ids, times and
///   every raw field, then what the host reported about the task (its
///   event log), newest first.
///
/// What the conversation already says is not repeated here: the title,
/// the Now line (a stall), the agents (its strip and worker lines; each
/// agent's page is on the team page), the questions waiting on the person,
/// the merge section and the Stop receipt. The step counts are the status
/// line and the graph's rows.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/orchestration_gateway.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/orchestration.dart';
import '../../app_theme.dart';
import '../../kit/kit.dart';
import '../../widgets/team_vocabulary.dart';
import 'policy_block.dart';
import 'work_graph.dart';
import 'work_sheet.dart';

AppLocalizations _copy(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

/// Opens Task details for the task [runId].
Future<void> showTeamTaskDetails(
  BuildContext context,
  OrchestrationController controller,
  String runId, {
  DateTime Function()? now,
}) {
  final l10n = _copy(context);
  return showKitSheet<void>(
    context,
    sheetKey: const ValueKey('team-task-details'),
    title: l10n.teamChatTaskDetails,
    icon: AppIconography.info,
    body: (_) =>
        TeamTaskDetails(controller: controller, runId: runId, now: now),
  );
}

/// The sheet's body; live with [controller].
class TeamTaskDetails extends StatelessWidget {
  const TeamTaskDetails({
    super.key,
    required this.controller,
    required this.runId,
    this.now,
  });

  final OrchestrationController controller;
  final String runId;

  /// Clock for elapsed times; tests pin it.
  final DateTime Function()? now;

  OrchestrationRun? get _run {
    for (final run in controller.snapshot.runs) {
      if (run.id == runId) return run;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final l10n = _copy(context);
      final run = _run;
      if (run == null) {
        return KitStateView(
          key: const ValueKey('team-task-details-missing'),
          size: KitStateSize.inline,
          icon: AppIconography.cloudOff,
          title: l10n.teamUiRunMissingTitle,
          body: l10n.teamUiRunMissingHint,
        );
      }
      return _Body(
        controller: controller,
        run: run,
        now: (now ?? DateTime.now)(),
        clock: now,
      );
    },
  );
}

class _Body extends StatelessWidget {
  const _Body({
    required this.controller,
    required this.run,
    required this.now,
    required this.clock,
  });

  final OrchestrationController controller;
  final OrchestrationRun run;
  final DateTime now;
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context) {
    final l10n = _copy(context);
    final tokens = KitTokens.of(context);
    final snapshot = controller.snapshot;
    final work = [
      for (final item in snapshot.work)
        if (item.runId == run.id) item,
    ];
    final progress = TeamRunProgress.of(run, snapshot.work);
    final stage = teamRunStage(
      run,
      snapshot.work,
      cycleOf: controller.cycleFor,
    );
    final stages = _Stage.of(run);
    // A task's own cost is not reported (slice-P5.2,
    // docs/qa/codex-p52-2026-09-27): said once where the host reports usage
    // at all, never replaced by the team's day total or a worker's window.
    final costUnreported = controller.capabilities.usage;
    final policy = controller.policy;

    // Waiting for merge (TEAM-117): every open item is in the merge
    // agent's hands, so the time counts from the hand-off.
    final handoff =
        teamRunAwaitsMerge(run, snapshot.work, cycleOf: controller.cycleFor)
        ? teamRunHandoffAt(run, snapshot.work, cycleOf: controller.cycleFor)
        : null;
    final String? elapsed;
    if (handoff != null) {
      elapsed = l10n.teamUiRunSinceHandoff(
        KitSince.durationWords(l10n, now.difference(handoff)),
      );
    } else {
      final span = _elapsed(run, now);
      elapsed = span == null ? null : KitSince.durationWords(l10n, span);
    }

    Widget label(String text, {Key? key}) => Padding(
      key: key,
      padding: EdgeInsetsDirectional.only(
        top: tokens.space5,
        bottom: tokens.labelGap,
      ),
      child: KitText(
        text,
        role: KitTextRole.label,
        tone: KitTextTone.secondary,
      ),
    );

    void openStep(String workId) =>
        unawaited(showWorkSheet(context, controller, workId, now: clock));

    return Column(
      key: const ValueKey('team-task-details-body'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusLine(
          key: const ValueKey('team-task-details-status'),
          run: run,
          stateWord: teamRunStateWordFor(
            l10n,
            run,
            snapshot.work,
            cycleOf: controller.cycleFor,
          ),
          steps: _isOpen(run) || run.state == RunState.completed
              ? teamTaskSteps(l10n, progress)
              : null,
          elapsed: elapsed,
        ),
        if (stage != null) ...[
          SizedBox(height: tokens.space4),
          _StageLine(key: const ValueKey('team-task-details-stage'), at: stage),
        ],
        if (work.isNotEmpty) ...[
          label(
            l10n.teamUiRunStepsHeading,
            key: const ValueKey('team-task-details-steps'),
          ),
          KitWorkGraph(
            key: const ValueKey('team-task-details-graph'),
            layout: KitWorkGraphLayout.rows,
            nodes: [
              for (final item in work) WorkGraphNode.of(item).toKit(l10n),
            ],
            onOpen: openStep,
            nodeKey: (id) => ValueKey('team-task-details-step-$id'),
          ),
        ] else if (stages.isNotEmpty) ...[
          // A formula run that tracks no work: its own stages are its steps.
          label(
            l10n.teamUiRunStepsHeading,
            key: const ValueKey('team-task-details-stages'),
          ),
          for (final (index, step) in stages.indexed)
            KitRow(
              key: ValueKey('team-task-details-stage-$index'),
              leading: KitRow.icon(
                context,
                teamRunGlyph(step.state).$1,
                color: AppTheme.statusColor(
                  Theme.of(context),
                  teamRunGlyph(step.state).$2,
                ),
              ),
              title: step.title,
              titleMaxLines: 2,
              supporting: TextSpan(text: teamRunStateWord(l10n, step.state)),
            ),
        ],
        if (costUnreported) ...[
          SizedBox(height: tokens.space4),
          _DetailLine(
            label: l10n.teamUiRunDetailsUsage,
            value: l10n.teamRunCostUnreported,
            valueKey: const ValueKey('team-task-details-usage'),
          ),
        ],
        // 02-ux §7: the host's supervision level and boundaries, read-only
        // (TEAM-207); absent when the host reports none.
        if (policy != null) ...[
          SizedBox(height: tokens.space4),
          TeamPolicyBlock(policy: policy),
        ],
        SizedBox(height: tokens.space4),
        _Technical(controller: controller, run: run, work: work),
      ],
    );
  }
}

/// A task the host can still stop: not finished, failed or cancelled.
bool _isOpen(OrchestrationRun run) => switch (run.state) {
  RunState.completed || RunState.cancelled || RunState.failed => false,
  _ => true,
};

/// Time since the run started; for a finished run, how long it took.
Duration? _elapsed(OrchestrationRun run, DateTime now) {
  final started = run.startedAt;
  if (started == null) return null;
  final finished = _isOpen(run) ? now : run.updatedAt ?? now;
  final elapsed = finished.difference(started);
  return elapsed.isNegative ? Duration.zero : elapsed;
}

/// One stage of a formula run, read from the provider's `steps` (or
/// `stages`) list when the host sent one.
class _Stage {
  const _Stage({required this.title, required this.state});

  final String title;
  final RunState state;

  static List<_Stage> of(OrchestrationRun run) {
    final steps = run.raw['steps'] ?? run.raw['stages'];
    if (steps is! List) return const [];
    return [
      for (final step in steps)
        if (step is Map)
          _Stage(
            title: _text(step['title']) ?? _text(step['id']) ?? '',
            state: RunState.fromProvider(
              _text(step['status']) ?? _text(step['state']),
            ),
          ),
    ];
  }
}

String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

Map<String, Object?> _map(Object? value) => value is Map
    ? {for (final entry in value.entries) '${entry.key}': entry.value}
    : const {};

/// A status tone as a text tone: the state word in its colour, never the
/// only sign (the word itself says it).
KitTextTone? _textTone(AppStatusTone tone) => switch (tone) {
  AppStatusTone.ok => KitTextTone.success,
  AppStatusTone.failure => KitTextTone.primary,
  AppStatusTone.progress => KitTextTone.primary,
  AppStatusTone.neutral => KitTextTone.secondary,
  // Amber is only the needs-you card's (LOOK-4, LOOK-24): the word says it.
  _ => KitTextTone.primary,
};

/// "Working · 1 of 5 steps done · 3 h 12 min": the state word in its tone,
/// how many steps are done, and for how long.
class _StatusLine extends StatelessWidget {
  const _StatusLine({
    super.key,
    required this.run,
    required this.stateWord,
    required this.steps,
    required this.elapsed,
  });

  final OrchestrationRun run;
  final String stateWord;
  final String? steps;
  final String? elapsed;

  @override
  Widget build(BuildContext context) {
    final (_, tone) = teamRunGlyph(run.state);
    const dot = KitText(
      teamUsageSeparator,
      role: KitTextRole.secondary,
      tone: KitTextTone.secondary,
    );
    // One line that wraps at large text rather than overflowing.
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        KitText(
          stateWord,
          key: const ValueKey('team-task-details-state'),
          role: KitTextRole.label,
          tone: _textTone(tone),
        ),
        if (steps case final steps?) ...[
          dot,
          KitText(
            steps,
            key: const ValueKey('team-task-details-progress'),
            role: KitTextRole.secondary,
            tone: KitTextTone.secondary,
          ),
        ],
        if (elapsed case final elapsed?) ...[
          dot,
          KitText(
            elapsed,
            key: const ValueKey('team-task-details-elapsed'),
            role: KitTextRole.secondary,
            tone: KitTextTone.secondary,
          ),
        ],
      ],
    );
  }
}

/// Waiting · Working · Reviewing · Done: where the task is, the current
/// stage named in the accent and the ones behind it checked. One
/// semantics label says it.
class _StageLine extends StatelessWidget {
  const _StageLine({super.key, required this.at});

  final TeamStage at;

  @override
  Widget build(BuildContext context) {
    final l10n = _copy(context);
    final tokens = KitTokens.of(context);
    final done = at == TeamStage.done;
    Widget mark(TeamStage stage) {
      final passed = stage.index < at.index || done;
      final current = stage == at && !done;
      final Widget glyph = passed
          ? const KitIcon.status(AppStatusTone.ok, icon: AppIconography.check)
          : current
          ? const KitIcon.status(
              AppStatusTone.progress,
              icon: AppIconography.statusDot,
            )
          : const KitIcon(
              AppIconography.statusDot,
              size: KitIconSize.small,
              tone: KitTextTone.tertiary,
            );
      return Row(
        key: ValueKey('team-task-details-stage-${stage.name}'),
        mainAxisSize: MainAxisSize.min,
        children: [
          glyph,
          SizedBox(width: tokens.space1),
          // Flexible: a stage word at 2.5× on a 320 dp phone wraps under
          // its mark instead of overflowing.
          Flexible(
            child: KitText(
              teamStageWord(l10n, stage),
              role: current ? KitTextRole.label : KitTextRole.secondary,
              tone: current || passed
                  ? KitTextTone.primary
                  : KitTextTone.secondary,
            ),
          ),
        ],
      );
    }

    return Semantics(
      label: l10n.teamUiRunStageSemantics(
        at.index + 1,
        teamStageWord(l10n, at),
      ),
      child: ExcludeSemantics(
        child: Wrap(
          spacing: tokens.space4,
          runSpacing: tokens.space2,
          children: [for (final stage in TeamStage.values) mark(stage)],
        ),
      ),
    );
  }
}

/// A label over its value.
class _DetailLine extends StatelessWidget {
  const _DetailLine({
    required this.label,
    required this.value,
    required this.valueKey,
  });

  final String label;
  final String value;
  final Key valueKey;

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    return Padding(
      padding: EdgeInsetsDirectional.symmetric(vertical: tokens.space1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          KitText(
            label,
            role: KitTextRole.caption,
            tone: KitTextTone.secondary,
          ),
          KitText(value, key: valueKey),
        ],
      ),
    );
  }
}

/// "Run · convoy" / "Run · formula": the product word with its Gas City
/// term beside it (02-ux §8).
String _term(AppLocalizations l10n, OrchestrationRun run) => switch (run.kind) {
  RunKind.batch => l10n.teamUiRunTermBatch,
  RunKind.formula => l10n.teamUiRunTermFormula,
  RunKind.unknown => l10n.teamUiRunTermUnknown,
};

/// The one technical fold: the host's term, state and times, every raw
/// provider field, then what the host reported about the task (its event
/// log, newest first).
class _Technical extends StatelessWidget {
  const _Technical({
    required this.controller,
    required this.run,
    required this.work,
  });

  final OrchestrationController controller;
  final OrchestrationRun run;
  final List<WorkItem> work;

  @override
  Widget build(BuildContext context) {
    final l10n = _copy(context);
    final tokens = KitTokens.of(context);
    final snapshot = controller.snapshot;
    // Every scalar the provider sent, minus what the values above show.
    const shown = {'id', 'run_id', 'title', 'status', 'formula'};
    final scalars = <(String, String)>[];
    void collect(Map<String, Object?> map, String prefix) {
      for (final entry in map.entries) {
        final value = entry.value;
        if (prefix.isEmpty && shown.contains(entry.key)) continue;
        if (value is String || value is num || value is bool) {
          scalars.add(('$prefix${entry.key}', '$value'));
        }
      }
    }

    collect(run.raw, '');
    collect(_map(run.raw['metadata']), 'metadata.');
    scalars.sort((a, b) => a.$1.compareTo(b.$1));

    final scope = TaskEventScope.of(snapshot, run.id);
    final events = controller.timeline;
    final reported = [
      for (var i = events.length - 1; i >= 0; i--)
        if (scope.includes(events[i]) && _category(events[i]) != null)
          events[i],
    ];

    return KitDetailsFold(
      key: const ValueKey('team-task-details-technical'),
      label: l10n.teamUiTechnicalDetails,
      values: [
        KitTechnicalValue(l10n.teamUiRunLabelKind, _term(l10n, run)),
        if (run.startedAt case final at?)
          KitTechnicalValue(l10n.teamUiRunLabelStarted, _stamp(at)),
        if (run.updatedAt case final at?)
          KitTechnicalValue(l10n.teamUiRunLabelUpdated, _stamp(at)),
        KitTechnicalValue(
          l10n.teamUiRunLabelId,
          run.id,
          key: const ValueKey('team-task-details-id'),
        ),
        if (run.rawState case final raw? when raw.isNotEmpty)
          KitTechnicalValue(l10n.teamUiRunLabelRawState, raw),
        // A batch is named by its work; the convoy's own title stays here.
        if (_text(run.raw['title']) case final rawTitle?
            when rawTitle != run.title)
          KitTechnicalValue(l10n.teamUiRunLabelRawTitle, rawTitle),
        if (run.formula case final formula?)
          KitTechnicalValue(l10n.teamUiRunLabelFormula, formula),
        if (run.projectId case final project?)
          KitTechnicalValue(l10n.teamUiRunLabelProject, project),
        if (run.lastError case final error?)
          KitTechnicalValue(l10n.teamUiRunLabelLastError, error),
        if (work.isNotEmpty)
          KitTechnicalValue(
            l10n.teamUiRunLabelTrackedWork,
            [for (final item in work) item.id].join(', '),
          ),
        for (final (key, value) in scalars) KitTechnicalValue(key, value),
      ],
      child: reported.isEmpty
          ? null
          : Column(
              key: const ValueKey('team-task-details-reported'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsetsDirectional.only(
                    top: tokens.space3,
                    bottom: tokens.labelGap,
                  ),
                  child: KitText(
                    l10n.teamTaskDetailsReported,
                    role: KitTextRole.label,
                    tone: KitTextTone.secondary,
                  ),
                ),
                for (final (index, event) in reported.indexed)
                  _EventRow(
                    key: ValueKey(
                      'team-task-details-event-${event.seq ?? index}',
                    ),
                    category: _category(event)!,
                    text: _eventText(l10n, snapshot, event),
                    at: _eventTime(event),
                  ),
              ],
            ),
    );
  }

  String _stamp(DateTime at) => at.toLocal().toString();
}

/// The ids an event must name to count as a task's: the run, its work
/// items, the agents on that work (by id, session and name) and its gates.
class TaskEventScope {
  const TaskEventScope({
    required this.runId,
    required this.workIds,
    required this.agentIds,
    required this.gateIds,
  });

  final String runId;
  final Set<String> workIds;
  final Set<String> agentIds;
  final Set<String> gateIds;

  static TaskEventScope of(OrchestrationSnapshot snapshot, String runId) {
    final workIds = {
      for (final item in snapshot.work)
        if (item.runId == runId) item.id,
    };
    final agentIds = <String>{};
    for (final agent in snapshot.agents) {
      if (workIds.contains(agent.currentWorkId)) {
        agentIds.addAll({
          agent.id,
          agent.name,
          ?agent.sessionId,
          ?agent.sessionName,
        });
      }
    }
    final gateIds = {
      for (final gate in snapshot.gates)
        if (teamGateRunId(snapshot, gate) == runId) gate.id,
    };
    return TaskEventScope(
      runId: runId,
      workIds: workIds,
      agentIds: agentIds,
      gateIds: gateIds,
    );
  }

  bool _known(String? id) =>
      id != null &&
      (id == runId ||
          workIds.contains(id) ||
          agentIds.contains(id) ||
          gateIds.contains(id));

  bool includes(OrchestrationEvent event) => switch (event) {
    BeadChanged() => workIds.contains(event.beadId) || event.beadId == runId,
    RunChanged() => event.runId == runId,
    SessionChanged() =>
      agentIds.contains(event.sessionId) || agentIds.contains(event.agentId),
    GateChanged() => gateIds.contains(event.gateId),
    RequestResult() => _mentions(event.payload),
    ActivityAppended() =>
      _known(event.event.subject) ||
          _known(event.event.actor) ||
          _mentions(event.event.payload),
    UnknownOrchestrationEvent() =>
      _known(_text(event.raw['subject'])) || _mentions(_map(event.raw)),
    StreamHeartbeat() || StreamHeadOnlyReplay() => false,
  };

  /// Whether a payload names one of the task's ids where Gas City puts
  /// them.
  bool _mentions(Map<String, Object?> payload) {
    if (_known(_text(_map(payload['bead'])['id']))) return true;
    for (final key in const [
      'bead_id',
      'run_id',
      'convoy_id',
      'session_id',
      'issue_id',
      'request_id',
      'subject',
    ]) {
      if (_known(_text(payload[key]))) return true;
    }
    return false;
  }
}

enum _EventCategory { work, agents, decisions, other }

/// Null for the stream's own bookkeeping (heartbeats, replays): not news.
_EventCategory? _category(OrchestrationEvent event) => switch (event) {
  BeadChanged() || RunChanged() => _EventCategory.work,
  SessionChanged() => _EventCategory.agents,
  GateChanged() => _EventCategory.decisions,
  ActivityAppended() ||
  RequestResult() ||
  UnknownOrchestrationEvent() => _typeCategory(event.type),
  StreamHeartbeat() || StreamHeadOnlyReplay() => null,
};

_EventCategory _typeCategory(String type) {
  final dot = type.indexOf('.');
  final family = dot < 0 ? type : type.substring(0, dot);
  return switch (family) {
    'bead' || 'beads' || 'convoy' || 'run' => _EventCategory.work,
    'session' || 'agent' => _EventCategory.agents,
    'request' || 'pending' || 'gate' || 'decision' => _EventCategory.decisions,
    _ => _EventCategory.other,
  };
}

/// When an event happened: the activity line's own stamp, else the `ts`
/// (or `timestamp`) of the raw frame or its `data`.
DateTime? _eventTime(OrchestrationEvent event) {
  if (event is ActivityAppended && event.event.timestamp != null) {
    return event.event.timestamp;
  }
  DateTime? of(Map<String, Object?> map) {
    final value = map['ts'] ?? map['timestamp'];
    return value is String ? DateTime.tryParse(value) : null;
  }

  return of(event.raw) ?? of(_map(event.raw['data']));
}

/// One line for an event: server text for activity lines, product copy
/// for the modelled changes.
/// One timeline event in words, redacted at this presentation boundary
/// (audit2 A2): an activity summary or a request error is the host's text
/// and may echo a credential, and a work title or agent name is server
/// data too. Being under Details does not waive redaction.
String _eventText(
  AppLocalizations l10n,
  OrchestrationSnapshot snapshot,
  OrchestrationEvent event,
) => KitRedact.text(_eventWords(l10n, snapshot, event));

String _eventWords(
  AppLocalizations l10n,
  OrchestrationSnapshot snapshot,
  OrchestrationEvent event,
) {
  String workTitle(String id) {
    for (final item in snapshot.work) {
      if (item.id == id) return item.title;
    }
    return id;
  }

  String agentName(String? id, String fallback) {
    for (final agent in snapshot.agents) {
      if (agent.id == id || agent.sessionId == id || agent.name == id) {
        return agent.name;
      }
    }
    return id ?? fallback;
  }

  String gateTitle(String id) {
    for (final gate in snapshot.gates) {
      if (gate.id == id) return gate.title;
    }
    return id;
  }

  return switch (event) {
    BeadChanged() => switch (event.change) {
      BeadChange.created => l10n.teamUiRunTimelineWorkCreated(
        workTitle(event.beadId),
      ),
      BeadChange.updated => l10n.teamUiRunTimelineWorkUpdated(
        workTitle(event.beadId),
      ),
      BeadChange.closed => l10n.teamUiRunTimelineWorkClosed(
        workTitle(event.beadId),
      ),
    },
    RunChanged() => l10n.teamUiRunTimelineRunChanged(
      teamRunStateWord(l10n, event.state),
    ),
    SessionChanged() => switch (event.change) {
      SessionChange.woke => l10n.teamUiRunTimelineAgentWoke(
        agentName(event.agentId ?? event.sessionId, event.sessionId),
      ),
      SessionChange.stopped => l10n.teamUiRunTimelineAgentStopped(
        agentName(event.agentId ?? event.sessionId, event.sessionId),
      ),
    },
    GateChanged() =>
      event.resolved
          ? l10n.teamUiRunTimelineGateResolved(gateTitle(event.gateId))
          : l10n.teamUiRunTimelineGateOpened(gateTitle(event.gateId)),
    ActivityAppended() => event.event.summary ?? event.type,
    RequestResult() => event.errorMessage ?? event.type,
    UnknownOrchestrationEvent() ||
    StreamHeartbeat() ||
    StreamHeadOnlyReplay() => event.type,
  };
}

(IconData, AppStatusTone) _categoryGlyph(_EventCategory category) =>
    switch (category) {
      _EventCategory.work => (AppIconography.checklist, AppStatusTone.neutral),
      _EventCategory.agents => (AppIconography.agent, AppStatusTone.neutral),
      _EventCategory.decisions => (
        AppIconography.question,
        AppStatusTone.neutral,
      ),
      _EventCategory.other => (AppIconography.timeline, AppStatusTone.neutral),
    };

/// One quiet line per event: category glyph, the text, the clock time.
class _EventRow extends StatelessWidget {
  const _EventRow({
    super.key,
    required this.category,
    required this.text,
    required this.at,
  });

  final _EventCategory category;
  final String text;
  final DateTime? at;

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final (icon, tone) = _categoryGlyph(category);
    final at = this.at;
    return KitRow(
      leading: KitRow.icon(
        context,
        icon,
        color: AppTheme.statusColor(Theme.of(context), tone),
      ),
      title: text,
      titleMaxLines: 3,
      trailing: at == null
          ? null
          : Padding(
              padding: EdgeInsetsDirectional.only(end: tokens.space3),
              child: KitText(
                teamClockLabel(context, at),
                role: KitTextRole.caption,
                tone: KitTextTone.secondary,
                tabular: true,
              ),
            ),
    );
  }
}
