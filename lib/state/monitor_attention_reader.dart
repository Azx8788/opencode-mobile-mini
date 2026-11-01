import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import '../orchestration/adapters/fixture/project_fixture_gateway.dart';
import '../orchestration/adapters/inapp/phone_engine_gateway.dart';
import 'team_project_persistence.dart';

import '../domain/models.dart';
import '../domain/attention_feed.dart';
import '../domain/orchestration_gateway.dart';
import '../domain/run_result.dart';
import '../domain/work_row_status.dart';
import '../ui/kit/kit_redact.dart';
import 'orchestration.dart';
import 'profile_monitor.dart';
import 'profiles.dart';

/// Bounded enrichment inside the existing monitor's polling lane. Owns no
/// watcher, timer, message cache or persistent state. Reads never perform acts.
class MonitorAttentionReader {
  MonitorAttentionReader({
    OrchestrationProbe? probe,
    OrchestrationGatewayFactory? teamGatewayFactory,
    PhoneEngineGateway Function(ServerProfile profile)? phoneGatewayBuilder,
    DateTime Function()? now,
    this.timeout = const Duration(seconds: 8),
  }) : _probe = probe ?? OrchestrationController.defaultProbe,
       _teamGatewayFactory = teamGatewayFactory,
       _phoneGatewayBuilder = phoneGatewayBuilder ?? _phoneGateway,
       _now = now ?? DateTime.now;

  final OrchestrationProbe _probe;
  final OrchestrationGatewayFactory? _teamGatewayFactory;
  final PhoneEngineGateway Function(ServerProfile profile) _phoneGatewayBuilder;
  static PhoneEngineGateway _phoneGateway(ServerProfile profile) =>
      PhoneEngineGateway(
        baseUrl: profile.orchestration!.url,
        profileId: profile.id,
        bearerToken: profile.teamEngineAuth,
      );
  final DateTime Function() _now;
  final Duration timeout;
  final _cursors = <String, ({String location, int offset})>{};
  bool _disposed = false;
  static const sessionLimit = 4;
  static const messageLimit = 50;
  static const teamRecordLimit = 256;

  void forget(String profileID) => _cursors.remove(profileID);
  void dispose() {
    _disposed = true;
    _cursors.clear();
  }

  Future<MonitorAttentionDetails> read(
    ServerProfile profile,
    MonitorGatewayPair pair,
    List<Session> sessions,
    Map<String, String> statuses,
    bool Function() current,
  ) async {
    final clock = Stopwatch()..start();
    bool allowed() => !_disposed && current() && clock.elapsed < timeout;
    Future<T> call<T>(Future<T> Function() action) async {
      if (!allowed()) throw const _ReadExpired();
      final value = await action().timeout(timeout - clock.elapsed);
      if (!allowed()) throw const _ReadExpired();
      return value;
    }

    final items = <AttentionObservation>[];
    final checked = <String>{};
    var historiesComplete = true;
    var teamComplete = profile.orchestration == null;
    final location = jsonEncode([
      pair.gateway.directory,
      pair.gateway.workspace,
    ]);
    final old = _cursors[profile.id];
    final start = old?.location == location ? old!.offset : 0;
    final count = math.min(sessionLimit, sessions.length);
    if (allowed() && sessions.isNotEmpty) {
      if (_cursors.length >= 64 && !_cursors.containsKey(profile.id)) {
        _cursors.remove(_cursors.keys.first);
      }
      _cursors[profile.id] = (
        location: location,
        offset: (start + count) % sessions.length,
      );
    }
    for (var index = 0; index < count && allowed(); index++) {
      final session = sessions[(start + index) % sessions.length];
      // A newer active turn makes an earlier terminal failure obsolete.
      final status = statuses[session.id];
      if (status != null && status != 'idle') {
        checked.add(session.id);
        continue;
      }
      try {
        final page = await call(
          () => pair.gateway.messagePage(session.id, limit: messageLimit),
        );
        if (page.hasMore || page.items.length >= messageLimit) {
          historiesComplete = false;
        }
        final messages = page.items.length > messageLimit
            ? page.items.sublist(page.items.length - messageLimit)
            : page.items;
        final hasUser = messages.any((m) => m.info.role == 'user');
        final emptyComplete = messages.isEmpty && !page.hasMore;
        if (!hasUser && !emptyComplete) continue;
        checked.add(session.id);
        final result = RunResult.fromMessages(session.id, messages);
        if (result == null || result.userMessageID == null) continue;
        if (result.outcome.kind != RunOutcomeKind.failed &&
            result.outcome.kind != RunOutcomeKind.cutOff) {
          continue;
        }
        items.add(
          AttentionObservation(
            id: 'session-failure:${session.id}',
            kind: AttentionKind.failedRun,
            facts: WorkRowFacts.chat(
              busy: false,
              needsYou: false,
              result: result,
            ),
            observedAt: _now(),
            sessionID: session.id,
            title: _title(session.title),
            directory: session.directory ?? pair.gateway.directory,
            workspace: session.workspaceID ?? pair.gateway.workspace,
          ),
        );
      } catch (_) {
        // Failed/truncated history is unknown. The monitor keeps older facts.
      }
    }

    final config = profile.orchestration;
    OrchestrationGateway? team;
    if (config?.provider == OrchestrationProvider.phoneEngine && allowed()) {
      try {
        // One authenticated client owns the probe and the read. Generic probes
        // have no profile credential context and cannot identify this engine.
        final gateway = _phoneGatewayBuilder(profile);
        team = gateway;
        await call(gateway.probe);
        if (!gateway.capabilities.projects) throw const _ReadExpired();
        final snapshot = await call(gateway.teamWorkspace);
        final records = snapshot.projects.fold<int>(
          snapshot.projects.length,
          (count, project) =>
              count + project.tasks.length + project.requests.length,
        );
        items.addAll(
          projectObservations(
            snapshot,
            observedAt: _now(),
            directory: pair.gateway.directory,
            workspace: pair.gateway.workspace,
          ),
        );
        teamComplete = records <= teamRecordLimit && allowed();
      } catch (_) {
        teamComplete = false;
      } finally {
        try {
          await team?.close();
        } catch (_) {
          teamComplete = false;
        }
        team = null;
      }
    } else if (config != null && allowed()) {
      try {
        final verdict = await call(() => _probe(config));
        if (verdict is! ProbeFound) throw const _ReadExpired();
        // A late factory result still belongs to this reader and must close.
        final gateway = await call(() async {
          final OrchestrationGateway gateway;
          final factory = _teamGatewayFactory;
          if (factory != null) {
            gateway = await factory(config, verdict);
          } else if (config.provider == OrchestrationProvider.fixture &&
              config.url == 'fixture://project-demo') {
            gateway = ProjectFixtureGateway(
              persistence: SharedPreferencesTeamProjectPersistence(
                await SharedPreferences.getInstance(),
                profile.id,
              ),
              readOnly: true,
              seedDemo: false,
            );
          } else {
            gateway = OrchestrationController.defaultGatewayFactory(
              config,
              verdict,
            );
          }
          // Retain ownership before the outer post-await admission check.
          team = gateway;
          if (!allowed()) {
            await gateway.close();
            team = null;
            throw const _ReadExpired();
          }
          return gateway;
        });
        final caps = gateway.capabilities;
        var allRead = true;
        var work = <WorkItem>[];
        var gates = <OrchestrationGate>[];
        var runs = <OrchestrationRun>[];
        if (caps.workGraph) {
          try {
            work = await call(() => gateway.work());
          } catch (_) {
            allRead = false;
          }
        }
        if (caps.gatesInteractions || caps.gatesBeads) {
          try {
            gates = await call(gateway.gates);
          } catch (_) {
            allRead = false;
          }
        }
        if (caps.runs) {
          try {
            runs = await call(() => gateway.runs());
          } catch (_) {
            allRead = false;
          }
        }
        if (work.length > teamRecordLimit ||
            gates.length > teamRecordLimit ||
            runs.length > teamRecordLimit) {
          allRead = false;
        }
        if (_disposed || !current()) throw const _ReadExpired();
        items.addAll(
          teamObservations(
            gates: gates,
            work: work,
            runs: runs,
            observedAt: _now(),
            directory: pair.gateway.directory,
            workspace: pair.gateway.workspace,
          ),
        );
        teamComplete = allRead && allowed();
      } catch (_) {
        teamComplete = false;
      } finally {
        final closingGateway = team;
        if (closingGateway != null) {
          try {
            // Start closure even if the read budget has just expired.
            final closing = closingGateway.close();
            final remaining = timeout - clock.elapsed;
            await closing.timeout(
              remaining.isNegative ? Duration.zero : remaining,
            );
          } catch (_) {
            teamComplete = false;
          }
        }
      }
    }
    return MonitorAttentionDetails(
      items: items,
      complete:
          allowed() &&
          checked.length == sessions.length &&
          sessions.length < 100 &&
          historiesComplete &&
          teamComplete,
      checkedSessionIDs: checked,
      teamComplete: teamComplete,
    );
  }

  /// Bounded projection of the authenticated phone engine's project snapshot.
  static List<AttentionObservation> projectObservations(
    TeamWorkspace snapshot, {
    required DateTime observedAt,
    String? directory,
    String? workspace,
  }) {
    final result = <AttentionObservation>[];
    var remaining = teamRecordLimit;
    for (final project in snapshot.projects) {
      if (remaining-- <= 0) break;
      final requestedTasks = <String>{};
      for (final request in project.requests) {
        if (remaining-- <= 0) return result;
        if (request.answered) continue;
        requestedTasks.add(request.taskId);
        result.add(
          AttentionObservation(
            id: 'team-project-request:${project.id}:${request.id}',
            kind: AttentionKind.teamGate,
            facts: const WorkRowFacts(phase: WorkRowPhase.needsYou),
            observedAt: observedAt,
            requestID: request.id,
            taskID: request.taskId.isEmpty ? null : request.taskId,
            title: _title(request.title),
            directory: directory,
            workspace: workspace,
          ),
        );
      }
      for (final task in project.tasks) {
        if (remaining-- <= 0) return result;
        if (requestedTasks.contains(task.id) ||
            !{
              'failed',
              'interrupted',
              'needsYou',
              'waitingForYou',
            }.contains(task.status)) {
          continue;
        }
        final failed = task.status == 'failed';
        result.add(
          AttentionObservation(
            id: 'team-project-task:${project.id}:${task.id}',
            kind: failed ? AttentionKind.failedRun : AttentionKind.teamGate,
            facts: WorkRowFacts(
              phase: failed ? WorkRowPhase.failed : WorkRowPhase.needsYou,
            ),
            observedAt: observedAt,
            taskID: task.id,
            title: _title(task.title),
            directory: directory,
            workspace: workspace,
          ),
        );
      }
    }
    return result;
  }

  /// Shared projection for the active team controller and monitor reads.
  /// Freshness belongs to the consuming feed; no stale snapshot is re-dated.
  static List<AttentionObservation> teamObservations({
    required List<OrchestrationGate> gates,
    required List<WorkItem> work,
    required DateTime observedAt,
    List<OrchestrationRun> runs = const [],
    String? directory,
    String? workspace,
    bool isFresh = true,
  }) {
    final observations = <AttentionObservation>[];
    final byID = {for (final item in work.take(teamRecordLimit)) item.id: item};
    final gateWork = <String>{};
    final gateRuns = <String>{};
    for (final gate in gates.take(teamRecordLimit)) {
      if (gate.kind == GateKind.reviewReady) continue;
      final item = byID[gate.workId];
      if (gate.workId != null) gateWork.add(gate.workId!);
      if (gate.runId != null) gateRuns.add(gate.runId!);
      observations.add(
        AttentionObservation(
          id: 'team-gate:${gate.id}',
          kind: AttentionKind.teamGate,
          facts: WorkRowFacts(
            phase: gate.kind == GateKind.runFailed
                ? WorkRowPhase.failed
                : WorkRowPhase.needsYou,
          ),
          observedAt: observedAt,
          isFresh: isFresh,
          sessionID: item?.sessionId,
          requestID: gate.id,
          taskID: gate.workId,
          runID: gate.runId,
          title: _title(gate.title),
          directory: directory,
          workspace: workspace,
        ),
      );
    }
    final failedRuns = <String>{...gateRuns};
    for (final item in work.take(teamRecordLimit)) {
      if (item.state != WorkState.failed || gateWork.contains(item.id)) {
        continue;
      }
      if (item.runId != null && gateRuns.contains(item.runId)) continue;
      if (item.runId != null) failedRuns.add(item.runId!);
      observations.add(
        AttentionObservation(
          id: 'team-work-failure:${item.id}',
          kind: AttentionKind.failedRun,
          facts: WorkRowFacts.team(item: item),
          observedAt: observedAt,
          isFresh: isFresh,
          sessionID: item.sessionId,
          taskID: item.id,
          runID: item.runId,
          title: _title(item.title),
          directory: directory,
          workspace: workspace,
        ),
      );
    }
    for (final run in runs.take(teamRecordLimit)) {
      if (run.state != RunState.failed ||
          run.isUpkeep ||
          failedRuns.contains(run.id)) {
        continue;
      }
      observations.add(
        AttentionObservation(
          id: 'team-run-failure:${run.id}',
          kind: AttentionKind.failedRun,
          facts: const WorkRowFacts(phase: WorkRowPhase.failed),
          observedAt: observedAt,
          isFresh: isFresh,
          runID: run.id,
          title: _title(run.title),
          directory: directory,
          workspace: workspace,
        ),
      );
    }
    return observations;
  }

  static String? _title(String? value) {
    if (value == null || value.isEmpty) return null;
    final redacted = KitRedact.text(value);
    return redacted.length <= 160 ? redacted : redacted.substring(0, 160);
  }
}

class _ReadExpired implements Exception {
  const _ReadExpired();
}
