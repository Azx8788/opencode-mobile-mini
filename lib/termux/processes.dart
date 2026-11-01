/// Running on this phone (TEAM-305, P5.3): every process the app's Termux
/// user owns, grouped by ancestry, and polite-then-forced stopping through
/// `~/.oc/tools.sh`.
///
/// The scanner's groups say who owns a process; [PhoneProcessKind] says
/// what runs, in the six kinds the page names (OpenCode server, AI Team,
/// Claude Code, dev services, terminals, helpers). Activity is measured
/// between two scans ([TermuxProcessReport.activityOf]), never read from
/// `ps`'s lifetime average; a reading that is missing stays unknown.
library;

import 'dart:convert';

import 'bridge.dart';

enum TermuxProcessGroup {
  orphans('orphans'),
  opencodeServer('opencode_server'),
  aiTeam('ai_team'),
  buildDaemons('build_daemons'),
  other('other');

  const TermuxProcessGroup(this.wireName);
  final String wireName;

  static TermuxProcessGroup parse(String? value) {
    for (final group in values) {
      if (group.wireName == value) return group;
    }
    return other;
  }

  /// The OpenCode server group is managed from the server controls, never
  /// stopped wholesale from the process list.
  bool get stoppable => this != opencodeServer;
}

enum TermuxOrphanReason { parentGone, cpuNoOwner }

/// What runs, as the page groups it (P5.3). Declared in the page's order.
enum PhoneProcessKind {
  openCodeServer,
  aiTeam,
  claudeCode,
  devServices,
  terminals,
  helpers,
}

/// Whether a process used the processor between the last two scans.
enum PhoneProcessActivity { busy, idle, unknown }

class TermuxProcess {
  const TermuxProcess({
    required this.pid,
    required this.ppid,
    required this.group,
    required this.name,
    required this.cmd,
    required this.cpuPct,
    required this.cpuSeconds,
    required this.rssKb,
    required this.elapsedSeconds,
    required this.cwd,
    required this.orphanReason,
    required this.protected,
  });

  final int pid;
  final int ppid;
  final TermuxProcessGroup group;
  final String name;
  final String cmd;
  final double cpuPct;
  final int cpuSeconds;
  final int rssKb;
  final int elapsedSeconds;
  final String cwd;
  final TermuxOrphanReason? orphanReason;
  final bool protected;

  bool get isOrphan => group == TermuxProcessGroup.orphans;

  /// The Termux app's own process: the host itself, never a background
  /// process of it and never stopped from the list.
  bool get isHostApp =>
      name.startsWith('com.termux') || cmd.startsWith('com.termux');

  /// Whether the list may offer to stop it: not protected by the scanner
  /// (the server, sshd) and not the Termux app itself.
  bool get stoppable => !protected && !isHostApp;

  /// Memory in whole megabytes, null when the reading is missing (a live
  /// process never has none).
  int? get memoryMb {
    if (rssKb <= 0) return null;
    final mb = (rssKb + 512) ~/ 1024;
    return mb < 1 ? 1 : mb;
  }

  static const _shells = {'bash', 'zsh', 'fish', 'sh', 'dash', 'ash', 'login'};

  static final _claude = RegExp(
    r'(^|[/ ])claude(-code)?( |$)|@anthropic-ai/claude-code',
  );

  static final _devTool = RegExp(
    r'GradleDaemon|GradleWrapperMain|KotlinCompileDaemon|analysis_server|'
    r'frontend_server|gradle',
  );

  /// What runs: the scanner's owner first (the server, the team), then
  /// what the process is by its name and command.
  PhoneProcessKind get kind {
    switch (group) {
      case TermuxProcessGroup.opencodeServer:
        return PhoneProcessKind.openCodeServer;
      case TermuxProcessGroup.aiTeam:
        return PhoneProcessKind.aiTeam;
      case _:
        break;
    }
    if (_claude.hasMatch(name) || _claude.hasMatch(cmd)) {
      return PhoneProcessKind.claudeCode;
    }
    if (group == TermuxProcessGroup.buildDaemons || _devTool.hasMatch(cmd)) {
      return PhoneProcessKind.devServices;
    }
    if (!isOrphan && !protected && _shells.contains(name)) {
      return PhoneProcessKind.terminals;
    }
    return PhoneProcessKind.helpers;
  }

  static TermuxProcess? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final pid = _int(raw['pid']);
    if (pid <= 0) return null;
    return TermuxProcess(
      pid: pid,
      ppid: _int(raw['ppid']),
      group: TermuxProcessGroup.parse(raw['group']?.toString()),
      name: raw['name']?.toString() ?? '',
      cmd: raw['cmd']?.toString() ?? '',
      cpuPct: switch (raw['cpu_pct']) {
        num v => v.toDouble(),
        String v => double.tryParse(v) ?? 0,
        _ => 0,
      },
      cpuSeconds: _int(raw['cpu_seconds']),
      rssKb: _int(raw['rss_kb']),
      elapsedSeconds: _int(raw['elapsed_s']),
      cwd: raw['cwd']?.toString() ?? '',
      orphanReason: switch (raw['orphan_reason']?.toString()) {
        'parent_gone' => TermuxOrphanReason.parentGone,
        'cpu_no_owner' => TermuxOrphanReason.cpuNoOwner,
        _ => null,
      },
      protected: raw['protected'] == true,
    );
  }
}

class TermuxProcessReport {
  const TermuxProcessReport(this.processes);

  final List<TermuxProcess> processes;

  int get count => processes.length;

  /// Android 12 and later stop the oldest child processes of apps when all
  /// apps together run more than this many (the phantom process limit's
  /// default). An advisory budget: the phone's owner may have lifted it,
  /// and other apps' processes count too.
  static const androidBackgroundLimit = 32;

  /// The processes that count against [androidBackgroundLimit]: everything
  /// Termux started, not the Termux app itself.
  int get backgroundCount => processes.where((p) => !p.isHostApp).length;

  /// Whether [process] was busy since the same process in [previous]: two
  /// or more seconds of processor time and at least a quarter of the time
  /// between the scans. Unknown without an earlier reading of the same
  /// process (same pid and name, still running longer than before).
  static PhoneProcessActivity activityOf(
    TermuxProcess process,
    TermuxProcessReport? previous,
  ) {
    final before = previous?.processes
        .where((p) => p.pid == process.pid && p.name == process.name)
        .firstOrNull;
    if (before == null) return PhoneProcessActivity.unknown;
    final wall = process.elapsedSeconds - before.elapsedSeconds;
    final cpu = process.cpuSeconds - before.cpuSeconds;
    if (wall <= 0 || cpu < 0) return PhoneProcessActivity.unknown;
    return cpu >= 2 && cpu * 4 >= wall
        ? PhoneProcessActivity.busy
        : PhoneProcessActivity.idle;
  }

  double get totalCpuPct => processes.fold(0.0, (sum, p) => sum + p.cpuPct);

  int get totalRssKb => processes.fold(0, (sum, p) => sum + p.rssKb);

  List<TermuxProcess> inGroup(TermuxProcessGroup group) =>
      processes.where((p) => p.group == group).toList();

  /// Groups in display order, only those with members.
  List<TermuxProcessGroup> get groups => [
    for (final group in TermuxProcessGroup.values)
      if (processes.any((p) => p.group == group)) group,
  ];

  /// Orphans that have burned more than [threshold] of CPU: the Workspace's
  /// "Something is still running on this phone" line.
  List<TermuxProcess> orphansOver(Duration threshold) => processes
      .where((p) => p.isOrphan && p.cpuSeconds > threshold.inSeconds)
      .toList();

  static TermuxProcessReport parse(String json) {
    final trimmed = json.trim();
    if (trimmed.isEmpty) return const TermuxProcessReport([]);
    final decoded = jsonDecode(trimmed);
    if (decoded is! List) {
      throw const TermuxBridgeException(
        'Could not read the process list.',
        code: 'invalid_process_list',
      );
    }
    return TermuxProcessReport([
      for (final raw in decoded) ?TermuxProcess.fromJson(raw),
    ]);
  }
}

class TermuxProcessStopResult {
  const TermuxProcessStopResult({
    required this.stopped,
    required this.killed,
    required this.remaining,
    required this.refused,
  });

  final List<int> stopped;
  final List<int> killed;
  final List<({int pid, String name})> remaining;
  final List<({int pid, String reason})> refused;

  int get endedCount => stopped.length + killed.length;

  static TermuxProcessStopResult parse(String json) {
    final decoded = jsonDecode(json.trim());
    if (decoded is! Map) {
      throw const TermuxBridgeException(
        'Could not read the stop result.',
        code: 'invalid_stop_result',
      );
    }
    List<int> pids(Object? raw) => [
      for (final v in raw as List? ?? const [])
        if (_int(v) > 0) _int(v),
    ];
    return TermuxProcessStopResult(
      stopped: pids(decoded['stopped']),
      killed: pids(decoded['killed']),
      remaining: [
        for (final raw in decoded['remaining'] as List? ?? const [])
          if (raw is Map)
            (pid: _int(raw['pid']), name: raw['name']?.toString() ?? ''),
      ],
      refused: [
        for (final raw in decoded['refused'] as List? ?? const [])
          if (raw is Map)
            (pid: _int(raw['pid']), reason: raw['reason']?.toString() ?? ''),
      ],
    );
  }
}

/// Runs the process verbs of `~/.oc/tools.sh`.
class TermuxProcesses {
  const TermuxProcesses._();

  static Future<TermuxProcessReport> scan() async => TermuxProcessReport.parse(
    await TermuxBridge.runTool(
      'procs-scan',
      timeout: const Duration(seconds: 20),
    ),
  );

  /// TERM, five seconds, then KILL; protected processes are refused.
  static Future<TermuxProcessStopResult> stopPid(int pid) async {
    if (pid <= 1) throw ArgumentError.value(pid, 'pid');
    return TermuxProcessStopResult.parse(
      await TermuxBridge.runTool(
        'procs-stop',
        argument: '$pid',
        timeout: const Duration(seconds: 25),
      ),
    );
  }

  /// Stops exactly [pids] (one kind's processes, confirmed together), each
  /// checked again by the script: gone and protected ones are refused.
  static Future<TermuxProcessStopResult> stopPids(List<int> pids) async {
    if (pids.isEmpty || pids.any((pid) => pid <= 1)) {
      throw ArgumentError.value(pids, 'pids');
    }
    if (pids.length == 1) return stopPid(pids.single);
    return TermuxProcessStopResult.parse(
      await TermuxBridge.runTool(
        'procs-stop',
        argument: pids.join(','),
        timeout: const Duration(seconds: 25),
      ),
    );
  }

  static Future<TermuxProcessStopResult> stopGroup(
    TermuxProcessGroup group,
  ) async => TermuxProcessStopResult.parse(
    await TermuxBridge.runTool(
      'procs-stop',
      argument: group.wireName,
      timeout: const Duration(seconds: 25),
    ),
  );
}

int _int(Object? value) => switch (value) {
  int v => v,
  num v => v.toInt(),
  String v => int.tryParse(v) ?? 0,
  _ => 0,
};
