/// The Work sheet (02-ux §4.2): what a step row of a task, a node of the
/// graph, a gate chip, the merge changes or a board card opens. The sheet
/// is titled with the item's title and its Gas City term ("Work · bead
/// oc-loy"); then the step's Now line (slice-P5.1: what is happening to
/// it, since when, what comes next, and why it waits after 8 s), owner,
/// the description as markdown, what it depends on and what waits on it
/// as rows that open the other item's
/// sheet in this one's place, "Open this step's conversation" only when the
/// adapter can link sessions and this item carries one (Gas City never
/// does) or else the working agent's conversation, the output excerpt and
/// validation result when the host sent them, the timestamps, and last one
/// Technical details fold with the branch, the worktree and every raw
/// field (KIT-33).
///
/// Map work-sheet is `redesign`: this is the kit-only rebuild of today's
/// layout (MAP-1); the "Step · task" structure with one primary per
/// state waits for its slice.
///
/// Kit only (KIT-1): [showKitSheet], [KitText], [KitIcon], [KitRowGroup]
/// rows, [KitMarkdown], [KitCodeBlock], [KitDetailsFold], [KitStateView].
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/orchestration_gateway.dart';
import '../../../l10n/app_localizations.dart';
import '../../../orchestration/adapters/gascity/gascity_mappers.dart'
    show WorkItemGasCity;
import '../../../state/orchestration.dart';
import '../../app_iconography.dart';
import '../../app_theme.dart' show AppStatusTone;
import '../../kit/chat/kit_markdown.dart';
import '../../kit/kit_buttons.dart';
import '../../kit/kit_code_block.dart';

import '../../kit/kit_icon.dart';
import '../../kit/kit_row.dart';
import '../../kit/kit_row_parts.dart' show KitChevron;
import '../../kit/kit_sheet.dart';
import '../../kit/kit_state_view.dart';
import '../../kit/kit_technical_value.dart';
import '../../kit/kit_text.dart';
import '../../kit/kit_tokens.dart';
import '../../widgets/relative_time.dart';
import '../../widgets/team_now_line_view.dart';
import '../../widgets/team_technical_details.dart';
import '../../widgets/team_vocabulary.dart';
import '../team_conversation/team_conversation.dart'
    show openTeamAgentConversation;
import 'team_agents_screen.dart' show teamAgentNickname;

AppLocalizations _copy(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

WorkItem? _itemIn(OrchestrationSnapshot snapshot, String workId) {
  for (final candidate in snapshot.work) {
    if (candidate.id == workId) return candidate;
  }
  return null;
}

/// Opens the Work sheet for [workId]. Dependency and blocking rows close
/// this sheet and open the other item's in its place (no sheet on a
/// sheet, KIT-16), so [context] must outlive the sheet (the run screen's
/// does). [onOpenSession] receives the linked OpenCode session id; without
/// it no "Open this step's conversation" is offered.
Future<void> showWorkSheet(
  BuildContext context,
  OrchestrationController controller,
  String workId, {
  DateTime Function()? now,
  ValueChanged<String>? onOpenSession,
}) {
  final l10n = _copy(context);
  final item = _itemIn(controller.snapshot, workId);
  return showKitSheet<void>(
    context,
    sheetKey: const ValueKey('team-work-sheet'),
    title: item?.title ?? l10n.teamWorkSheetMissingTitle,
    // The task it belongs to, in the person's words; the host's own term
    // and id wait under Technical details.
    subtitle: item == null ? null : _taskOf(controller.snapshot, item),
    icon: AppIconography.checklist,
    body: (sheetContext) => WorkSheet(
      controller: controller,
      workId: workId,
      now: now,
      onOpenSession: onOpenSession,
      onJump: (id) {
        Navigator.of(sheetContext).pop();
        unawaited(
          showWorkSheet(
            context,
            controller,
            id,
            now: now,
            onOpenSession: onOpenSession,
          ),
        );
      },
    ),
  );
}

/// The OpenCode session an item links to, when the host recorded one
/// (`opencode_session_id` on the item or its metadata). Gas City agents
/// run as `opencode acp` children no server lists, so this is null there.
String? workSessionLink(WorkItem item) {
  final metadata = _map(item.raw['metadata']);
  return _text(item.raw['opencode_session_id']) ??
      _text(metadata['opencode_session_id']) ??
      _text(metadata['oc.session_id']);
}

/// The agent working on [item] now, when the host lists one.
OrchestrationAgent? _agentOn(OrchestrationSnapshot snapshot, WorkItem item) {
  if (item.state != WorkState.working) return null;
  for (final agent in snapshot.agents) {
    if (agent.currentWorkId == item.id) return agent;
  }
  return null;
}

/// The title of the task [item] belongs to, else its project; null when
/// the snapshot names neither.
String? _taskOf(OrchestrationSnapshot snapshot, WorkItem item) {
  for (final run in snapshot.runs) {
    // A one-step task shares its step's title: the title says it once.
    if (run.id == item.runId) return run.title == item.title ? null : run.title;
  }
  final project = item.projectId?.trim();
  return project == null || project.isEmpty ? null : project;
}

/// An owner as the person knows it: the agent's own name, never the host's
/// handle ("ocproof/gastown.furiosa" reads "furiosa"). The full handle
/// stays under Technical details.
String? workOwnerShortName(OrchestrationSnapshot snapshot, WorkItem item) {
  final owner = workOwnerName(snapshot, item);
  if (owner == null) return null;
  final tail = owner.split('/').last.split('.').last.trim();
  return tail.isEmpty ? owner : tail;
}

/// Who owns an item: the agent on it (by work id, id, name or session),
/// else the assignee string as the host sent it; null when nobody.
String? workOwnerName(OrchestrationSnapshot snapshot, WorkItem item) {
  for (final agent in snapshot.agents) {
    if (agent.currentWorkId == item.id) return agent.name;
  }
  final assignee = item.assignee;
  if (assignee == null || assignee.isEmpty) return null;
  for (final agent in snapshot.agents) {
    if (agent.id == assignee ||
        agent.name == assignee ||
        agent.sessionId == assignee ||
        agent.sessionName == assignee) {
      return agent.name;
    }
  }
  return assignee;
}

/// The output excerpt the host attached to an item, if any.
String? workOutputExcerpt(WorkItem item) {
  final metadata = _map(item.raw['metadata']);
  return _text(item.raw['output_excerpt']) ??
      _text(item.raw['output']) ??
      _text(metadata['output_excerpt']) ??
      _text(metadata['last_output']) ??
      _text(metadata['gc.last_output']);
}

/// A validation result: passed or not, with the host's summary.
class WorkValidation {
  const WorkValidation({required this.passed, this.summary});

  final bool? passed;
  final String? summary;

  static WorkValidation? of(WorkItem item) {
    final metadata = _map(item.raw['metadata']);
    final raw =
        item.raw['validation'] ??
        metadata['validation'] ??
        metadata['validation_result'] ??
        metadata['gc.validation'];
    if (raw == null) return null;
    if (raw is String) {
      final text = raw.trim();
      if (text.isEmpty) return null;
      final lower = text.toLowerCase();
      return WorkValidation(
        passed: switch (lower) {
          'passed' || 'pass' || 'ok' || 'success' || 'true' => true,
          'failed' || 'fail' || 'error' || 'false' => false,
          _ => null,
        },
        summary: text,
      );
    }
    if (raw is bool) return WorkValidation(passed: raw);
    final map = _map(raw);
    if (map.isEmpty) return null;
    final status = (_text(map['status']) ?? _text(map['result']) ?? '')
        .toLowerCase();
    final passed = map['passed'] is bool
        ? map['passed'] as bool
        : switch (status) {
            'passed' || 'pass' || 'ok' || 'success' => true,
            'failed' || 'fail' || 'error' => false,
            _ => null,
          };
    return WorkValidation(
      passed: passed,
      summary:
          _text(map['summary']) ??
          _text(map['message']) ??
          _text(map['output']) ??
          _text(map['error']),
    );
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

/// The Work sheet's body: everything under the sheet's title. It rebuilds
/// with the controller, so the strip, the state and the rows stay live.
class WorkSheet extends StatelessWidget {
  const WorkSheet({
    super.key,
    required this.controller,
    required this.workId,
    required this.onJump,
    this.now,
    this.onOpenSession,
  });

  final OrchestrationController controller;
  final String workId;
  final ValueChanged<String> onJump;
  final DateTime Function()? now;
  final ValueChanged<String>? onOpenSession;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final l10n = _copy(context);
      final snapshot = controller.snapshot;
      final item = _itemIn(snapshot, workId);
      if (item == null) {
        // Gone from the host meanwhile: a designed state that says what
        // happened and where the rest is, not an empty sheet.
        return KitStateView(
          key: const ValueKey('team-work-sheet-missing'),
          size: KitStateSize.inline,
          icon: AppIconography.cloudOff,
          title: l10n.teamUiWorkSheetMissing,
          body: l10n.teamWorkSheetMissingBody,
        );
      }
      return _Body(
        key: ValueKey('team-work-sheet-${item.id}'),
        controller: controller,
        item: item,
        snapshot: snapshot,
        sessionLink: controller.capabilities.sessionLink,
        now: (now ?? DateTime.now)(),
        clock: now ?? DateTime.now,
        onJump: onJump,
        onOpenSession: onOpenSession,
      );
    },
  );
}

/// A section's name above its content (sentence case, LOOK-15).
class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    return Padding(
      padding: EdgeInsetsDirectional.only(
        top: tokens.space4,
        bottom: tokens.labelGap,
      ),
      child: Semantics(
        header: true,
        child: KitText(text, role: KitTextRole.label),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    super.key,
    required this.controller,
    required this.item,
    required this.snapshot,
    required this.sessionLink,
    required this.now,
    required this.clock,
    required this.onJump,
    required this.onOpenSession,
  });

  final OrchestrationController controller;
  final WorkItem item;
  final OrchestrationSnapshot snapshot;
  final bool sessionLink;
  final DateTime now;

  /// The page's clock, for the Now line's 8 s explanation.
  final DateTime Function() clock;
  final ValueChanged<String> onJump;
  final ValueChanged<String>? onOpenSession;

  @override
  Widget build(BuildContext context) {
    final l10n = _copy(context);
    final tokens = KitTokens.of(context);
    final byId = {for (final w in snapshot.work) w.id: w};
    final dependencies = [
      for (final id in {...item.dependsOn})
        if (id != item.id) (id, byId[id]),
    ];
    final blocking = [
      for (final other in snapshot.work)
        if (other.id != item.id && other.dependsOn.contains(item.id))
          (other.id, other),
    ];
    final description = _text(item.raw['description']);
    final owner = workOwnerShortName(snapshot, item);
    final link = workSessionLink(item);
    final output = workOutputExcerpt(item);
    final validation = WorkValidation.of(item);
    final openSession = onOpenSession;
    final agent = _agentOn(snapshot, item);
    final closedAt = _closedAt(item);
    OrchestrationRun? run;
    for (final candidate in snapshot.runs) {
      if (candidate.id == item.runId) run = candidate;
    }

    Widget rows(String prefix, List<(String, WorkItem?)> items) => KitRowGroup(
      margin: EdgeInsetsDirectional.zero,
      children: [
        for (final (id, other) in items)
          KitRow(
            key: ValueKey('team-work-$prefix-$id'),
            leading: other == null
                ? KitRow.icon(context, AppIconography.cloudOff)
                : teamWorkMark(other.state).leading(context),
            title: other?.title ?? id,
            titleMaxLines: 2,
            supporting: TextSpan(
              text: other == null
                  ? l10n.teamWorkSheetNotOnHost
                  : teamWorkStateWord(l10n, other.state),
            ),
            trailing: other == null ? null : const KitChevron(),
            onTap: other == null ? null : () => onJump(id),
          ),
      ],
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The step's Now line: what is happening to it, for how long and
        // what comes next, in the person's words (slice-P5.1; it replaced
        // the dispatch cycle strip and its seven engine steps). A step in
        // no task says its state on the owner line instead.
        if (run != null) ...[
          TeamNowLineView(
            keyPrefix: 'team-work-sheet',
            watchCycles: controller,
            watchWorkId: item.id,
            clock: clock,
            input: TeamNowInput.forRun(
              activityKey: '${controller.profileId}:work:${item.id}',
              run: run,
              work: [item],
              cycleOf: controller.cycleFor,
              agents: snapshot.agents,
              connected: controller.phase == OrchestrationPhase.ready,
              now: now,
            ),
            // The step's conversation is its own row below; checking
            // again is this sheet's one way out.
            wayOut: (action) => action == TeamNowAction.refresh
                ? KitAction(
                    key: const ValueKey('team-work-sheet-now-refresh'),
                    label: l10n.teamUiRefresh,
                    onPressed: () => unawaited(controller.refresh()),
                  )
                : null,
          ),
          SizedBox(height: tokens.space3),
        ],
        // The Now line above carries the state; this line says only who
        // owns the work, by the agent's name.
        Row(
          children: [
            const KitIcon(
              AppIconography.person,
              size: KitIconSize.small,
              tone: KitTextTone.secondary,
            ),
            SizedBox(width: tokens.space2),
            Flexible(
              child: KitText(
                [
                  if (run == null) teamWorkStateWord(l10n, item.state),
                  owner ?? l10n.teamUiWorkOwnerNone,
                ].join(teamUsageSeparator),
                key: const ValueKey('team-work-sheet-owner'),
                role: KitTextRole.secondary,
              ),
            ),
          ],
        ),
        if (description != null) ...[
          _Heading(l10n.teamUiWorkSheetDescription),
          KitMarkdown(
            description,
            key: const ValueKey('team-work-sheet-description'),
            selectable: false,
          ),
        ],
        if (dependencies.isNotEmpty) ...[
          _Heading(l10n.teamUiWorkSheetDependencies),
          rows('dependency', dependencies),
        ],
        if (blocking.isNotEmpty) ...[
          _Heading(l10n.teamUiWorkSheetBlocking),
          rows('blocking', blocking),
        ],
        if (sessionLink && link != null && openSession != null) ...[
          SizedBox(height: tokens.space4),
          KitButton.secondary(
            key: const ValueKey('team-work-sheet-open-session'),
            onPressed: () => openSession(link),
            icon: AppIconography.chat,
            label: l10n.teamWorkSheetOpenStepConversation,
          ),
        ] else if (agent != null) ...[
          // The work itself is shown in one place: the agent's own
          // conversation on the chat page (Live output when it has none).
          SizedBox(height: tokens.space4),
          KitButton.secondary(
            key: const ValueKey('team-work-sheet-open-conversation'),
            onPressed: () =>
                openTeamAgentConversation(context, agent, team: controller),
            icon: AppIconography.chat,
            label: l10n.teamWorkSheetOpenAgentConversation(
              teamAgentNickname(agent) ??
                  teamAgentRoleWord(l10n, teamAgentRole(agent)),
            ),
          ),
        ],
        if (output != null) ...[
          _Heading(l10n.teamUiWorkSheetOutput),
          KitCodeBlock(
            text: output,
            kind: KitCodeKind.output,
            blockKey: const ValueKey('team-work-sheet-output'),
          ),
        ],
        if (validation != null) ...[
          _Heading(l10n.teamUiWorkSheetValidation),
          _ValidationRow(validation: validation),
        ],
        _Heading(l10n.teamUiWorkSheetTimestamps),
        if (item.createdAt case final at?)
          TeamIdentityRow(
            key: const ValueKey('team-work-sheet-created'),
            label: l10n.teamUiWorkSheetCreated,
            value: _stamp(context, l10n, at),
          ),
        if (item.updatedAt case final at?)
          TeamIdentityRow(
            key: const ValueKey('team-work-sheet-updated'),
            label: l10n.teamUiWorkSheetUpdated,
            value: _stamp(context, l10n, at),
          ),
        if (closedAt != null)
          TeamIdentityRow(
            label: l10n.teamUiWorkSheetClosed,
            value: _stamp(context, l10n, closedAt),
          ),
        if (item.createdAt == null &&
            item.updatedAt == null &&
            closedAt == null)
          KitText(
            l10n.teamUiWorkSheetNoTimestamps,
            role: KitTextRole.secondary,
          ),
        SizedBox(height: tokens.space3),
        KitDetailsFold(
          foldKey: const ValueKey('team-work-sheet-technical'),
          label: l10n.teamUiTechnicalDetails,
          values: _technicalValues(l10n, item, dependencies),
        ),
      ],
    );
  }

  /// "11 Sep 2026 · 09:41 (3h ago)".
  String _stamp(BuildContext context, AppLocalizations l10n, DateTime at) {
    final local = at.toLocal();
    final date = MaterialLocalizations.of(context).formatMediumDate(local);
    final clock = teamClockLabel(context, at);
    final age = relativeTimeLabel(
      at.millisecondsSinceEpoch,
      now: now,
      l10n: l10n,
    );
    return l10n.teamUiWorkSheetStamp(date, clock, age);
  }

  DateTime? _closedAt(WorkItem item) {
    final raw =
        item.raw['closed_at'] ?? _map(item.raw['metadata'])['closed_at'];
    return raw is String ? DateTime.tryParse(raw) : null;
  }
}

/// Passed, failed or recorded, with the host's summary under the word.
class _ValidationRow extends StatelessWidget {
  const _ValidationRow({required this.validation});

  final WorkValidation validation;

  @override
  Widget build(BuildContext context) {
    final l10n = _copy(context);
    final tokens = KitTokens.of(context);
    final (tone, word) = switch (validation.passed) {
      true => (AppStatusTone.ok, l10n.teamUiWorkSheetValidationPassed),
      false => (AppStatusTone.failure, l10n.teamUiWorkSheetValidationFailed),
      null => (AppStatusTone.neutral, l10n.teamUiWorkSheetValidationUnknown),
    };
    final summary = validation.summary;
    return Row(
      key: const ValueKey('team-work-sheet-validation'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        KitIcon.status(tone),
        SizedBox(width: tokens.space2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              KitText(word, role: KitTextRole.rowTitle),
              if (summary != null && summary != word)
                KitText(summary, role: KitTextRole.secondary),
            ],
          ),
        ),
      ],
    );
  }
}

/// Technical details (02-ux §8, KIT-33): where the code lives (branch,
/// worktree, merge target), the product values, then every raw scalar the
/// provider sent. Each value shows once, mono, left to right, copyable.
List<KitTechnicalValue> _technicalValues(
  AppLocalizations l10n,
  WorkItem item,
  List<(String, WorkItem?)> dependencies,
) {
  const shown = {'id', 'title', 'status', 'description'};
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

  collect(item.raw, '');
  collect(_map(item.raw['metadata']), 'metadata.');
  scalars.sort((a, b) => a.$1.compareTo(b.$1));
  KitTechnicalValue value(String label, String value, {Key? key}) =>
      KitTechnicalValue(label, value, copyable: value.isNotEmpty, key: key);
  return [
    if (item.branch case final branch?)
      value(
        l10n.teamUiWorkSheetBranch,
        branch,
        key: const ValueKey('team-work-sheet-branch'),
      ),
    if (item.workDir case final dir?)
      value(
        l10n.teamUiWorkSheetWorktree,
        dir,
        key: const ValueKey('team-work-sheet-worktree'),
      ),
    if (item.target case final target?)
      value(
        l10n.teamUiWorkSheetTarget,
        target,
        key: const ValueKey('team-work-sheet-target'),
      ),
    value(l10n.teamUiWorkLabelId, item.id),
    value(l10n.teamUiWorkLabelRawState, item.rawState ?? ''),
    if (item.issueType case final type?) value(l10n.teamUiWorkLabelType, type),
    if (item.runId case final run?) value(l10n.teamUiWorkLabelRun, run),
    if (item.parentId case final parent?)
      value(l10n.teamUiWorkLabelParent, parent),
    if (item.projectId case final project?)
      value(l10n.teamUiWorkLabelProject, project),
    if (item.assignee case final assignee?)
      value(l10n.teamUiWorkLabelAssignee, assignee),
    if (item.sessionId case final session?)
      value(l10n.teamUiWorkLabelSession, session),
    if (item.sessionName case final name?)
      value(l10n.teamUiWorkLabelSessionName, name),
    if (item.labels.isNotEmpty)
      value(l10n.teamUiWorkLabelLabels, item.labels.join(', ')),
    if (dependencies.isNotEmpty)
      value(
        l10n.teamUiWorkLabelDependsOn,
        [for (final (id, _) in dependencies) id].join(', '),
      ),
    if (item.closedReason case final reason?)
      value(l10n.teamUiWorkLabelClosedReason, reason),
    for (final (key, raw) in scalars) value(key, raw),
  ];
}
