/// Storage on this phone (TEAM-304): what the managed Termux environment
/// uses, by category, and per-category cleaning through `~/.oc/tools.sh`.
///
/// The scan runs in the background inside Termux and writes a log the UI
/// tails plus a JSON report; [TermuxStorage.status] reads both. Cleaning is
/// limited to explicit regenerable caches from a current scan. A clean makes
/// the report stale; another scan is required before further cleanup.
library;

import 'dart:convert';

import 'bridge.dart';

enum TermuxStorageScanState { idle, running, done, cancelled, failed, stale }

/// Category keys in the order the screen shows them; the script emits the
/// same keys, and an unknown one stays visible under its raw key.
enum TermuxStorageCategoryKey {
  buildCaches('build_caches'),
  agentScratch('agent_scratch'),
  projectBuildOutputs('project_build_outputs'),
  toolchains('toolchains'),
  aiTeam('ai_team'),
  opencode('opencode'),
  projects('projects'),
  sharedCaches('shared_caches');

  const TermuxStorageCategoryKey(this.wireName);
  final String wireName;

  static TermuxStorageCategoryKey? parse(String value) {
    for (final key in values) {
      if (key.wireName == value) return key;
    }
    return null;
  }
}

class TermuxStoragePath {
  const TermuxStoragePath({required this.path, required this.bytes});
  final String path;
  final int bytes;
}

class TermuxStorageCategory {
  const TermuxStorageCategory({
    required this.key,
    required this.bytes,
    required this.deletable,
    required this.paths,
    this.labelKey = '',
    this.noteKey = '',
  });

  final String key;
  final String labelKey;
  final String noteKey;
  final int bytes;
  final bool deletable;
  final List<TermuxStoragePath> paths;

  /// Old or untrusted reports cannot expose cleanup for protected categories.
  bool get canClean =>
      deletable && known == TermuxStorageCategoryKey.buildCaches;

  TermuxStorageCategoryKey? get known => TermuxStorageCategoryKey.parse(key);

  TermuxStorageCategory without(Set<String> removed) {
    final kept = paths.where((p) => !removed.contains(p.path)).toList();
    return TermuxStorageCategory(
      key: key,
      labelKey: labelKey,
      noteKey: noteKey,
      bytes: kept.fold(0, (sum, p) => sum + p.bytes),
      deletable: deletable,
      paths: kept,
    );
  }
}

class TermuxStorageProject {
  const TermuxStorageProject({
    required this.name,
    required this.path,
    required this.bytes,
    required this.buildBytes,
  });
  final String name;
  final String path;
  final int bytes;
  final int buildBytes;
}

class TermuxStorageReport {
  const TermuxStorageReport({
    required this.scannedAtEpochSeconds,
    required this.totalBytes,
    required this.categories,
    required this.projects,
    this.isStale = false,
  });

  final int? scannedAtEpochSeconds;
  final int totalBytes;
  final List<TermuxStorageCategory> categories;
  final List<TermuxStorageProject> projects;
  final bool isStale;

  DateTime? get scannedAt => scannedAtEpochSeconds == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(scannedAtEpochSeconds! * 1000);

  TermuxStorageReport asStale() => TermuxStorageReport(
    scannedAtEpochSeconds: scannedAtEpochSeconds,
    totalBytes: totalBytes,
    categories: categories,
    projects: projects,
    isStale: true,
  );

  /// Everything a clean may remove, in bytes.
  int get deletableBytes => isStale
      ? 0
      : categories.where((c) => c.canClean).fold(0, (sum, c) => sum + c.bytes);

  TermuxStorageCategory? category(TermuxStorageCategoryKey key) {
    for (final c in categories) {
      if (c.key == key.wireName) return c;
    }
    return null;
  }

  /// The report after [removed] paths of [key] went away: the category's
  /// entries and the total shrink by exactly what was freed.
  TermuxStorageReport afterClean(
    String key,
    Iterable<String> removed,
    int freedBytes,
  ) {
    final gone = removed.toSet();
    return TermuxStorageReport(
      scannedAtEpochSeconds: scannedAtEpochSeconds,
      totalBytes: (totalBytes - freedBytes).clamp(0, totalBytes),
      categories: [
        for (final c in categories)
          if (c.key == key) c.without(gone) else c,
      ],
      projects: projects,
      isStale: true,
    );
  }

  static TermuxStorageReport parse(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! Map) {
      throw const TermuxBridgeException(
        'Could not read the storage scan.',
        code: 'invalid_storage_report',
      );
    }
    final categories = <TermuxStorageCategory>[];
    for (final raw in decoded['categories'] as List? ?? const []) {
      if (raw is! Map) continue;
      final key = raw['key']?.toString() ?? '';
      if (key.isEmpty) continue;
      final paths = <TermuxStoragePath>[];
      for (final entry in raw['paths'] as List? ?? const []) {
        if (entry is! Map) continue;
        final path = entry['path']?.toString() ?? '';
        if (path.isEmpty) continue;
        paths.add(TermuxStoragePath(path: path, bytes: _int(entry['bytes'])));
      }
      categories.add(
        TermuxStorageCategory(
          key: key,
          labelKey: raw['label_key']?.toString() ?? '',
          noteKey: raw['note_key']?.toString() ?? '',
          bytes: _int(raw['bytes']),
          deletable: raw['deletable'] == true,
          paths: paths,
        ),
      );
    }
    final projects = <TermuxStorageProject>[];
    for (final raw in decoded['projects'] as List? ?? const []) {
      if (raw is! Map) continue;
      final name = raw['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      projects.add(
        TermuxStorageProject(
          name: name,
          path: raw['path']?.toString() ?? '',
          bytes: _int(raw['bytes']),
          buildBytes: _int(raw['build_bytes']),
        ),
      );
    }
    final scannedAt = _int(decoded['scanned_at']);
    return TermuxStorageReport(
      scannedAtEpochSeconds: scannedAt > 0 ? scannedAt : null,
      totalBytes: _int(decoded['total_bytes']),
      categories: categories,
      projects: projects,
      isStale: decoded['stale'] == true || decoded['cleanup_policy'] != 2,
    );
  }
}

class TermuxStorageScanStatus {
  const TermuxStorageScanStatus({
    required this.state,
    required this.log,
    required this.report,
  });

  static const _logMarker = '__OC_TOOLS_LOG__';
  static const _jsonMarker = '__OC_TOOLS_JSON__';

  final TermuxStorageScanState state;
  final String log;
  final TermuxStorageReport? report;

  static TermuxStorageScanStatus parse(String raw) {
    final logIndex = raw.indexOf(_logMarker);
    final jsonIndex = raw.indexOf(_jsonMarker);
    final head = logIndex < 0 ? raw : raw.substring(0, logIndex);
    final stateValue = RegExp(
      r'^state=(\w+)',
      multiLine: true,
    ).firstMatch(head)?.group(1);
    final state = switch (stateValue) {
      'running' => TermuxStorageScanState.running,
      'done' => TermuxStorageScanState.done,
      'cancelled' => TermuxStorageScanState.cancelled,
      'failed' => TermuxStorageScanState.failed,
      'stale' => TermuxStorageScanState.stale,
      _ => TermuxStorageScanState.idle,
    };
    var log = '';
    var json = '';
    if (logIndex >= 0) {
      final logStart = logIndex + _logMarker.length;
      if (jsonIndex > logIndex) {
        log = raw.substring(logStart, jsonIndex);
        json = raw.substring(jsonIndex + _jsonMarker.length).trim();
      } else {
        log = raw.substring(logStart);
      }
    }
    TermuxStorageReport? report;
    if (json.isNotEmpty) {
      try {
        report = TermuxStorageReport.parse(json);
        if (state != TermuxStorageScanState.done) report = report.asStale();
      } on FormatException {
        report = null;
      }
    }
    return TermuxStorageScanStatus(
      state: state,
      log: log.trim(),
      report: report,
    );
  }
}

/// The scan's stages, in the order the bundled script measures them. Each
/// starts with one `[oc] <heading>` log line (TermuxBridge's storage scan),
/// so the scan view can fill its rows in as it goes: the sizes themselves
/// arrive only with the finished report.
enum TermuxStorageScanStage {
  buildCaches('Build caches'),
  sharedCaches('Other caches and package data (read only)'),
  agentScratch('Agent scratch'),
  toolchains('Toolchains'),
  aiTeam('AI Team'),
  opencode('OpenCode'),
  projects('Projects'),
  total('Measuring the whole Termux install');

  const TermuxStorageScanStage(this.heading);

  /// The script's log line for this stage, without the `[oc] ` prefix.
  final String heading;

  /// The stage the scan has reached in [log]: the last heading printed, or
  /// null before the first one.
  static TermuxStorageScanStage? reached(String log) {
    TermuxStorageScanStage? last;
    for (final raw in log.split('\n')) {
      final line = raw.trim();
      if (!line.startsWith('[oc] ')) continue;
      final heading = line.substring(5);
      for (final stage in values) {
        if (stage.heading == heading) last = stage;
      }
    }
    return last;
  }
}

/// The cheap answer for the settings row: last total and when it was taken.
class TermuxStorageSummary {
  const TermuxStorageSummary({
    required this.state,
    required this.totalBytes,
    required this.scannedAtEpochSeconds,
  });

  final TermuxStorageScanState state;
  final int? totalBytes;
  final int? scannedAtEpochSeconds;

  static TermuxStorageSummary parse(String raw) {
    final values = <String, String>{};
    for (final line in raw.split('\n')) {
      final separator = line.indexOf('=');
      if (separator <= 0) continue;
      values[line.substring(0, separator).trim()] = line
          .substring(separator + 1)
          .trim();
    }
    final total = int.tryParse(values['total_bytes'] ?? '');
    final scanned = int.tryParse(values['scanned_at'] ?? '');
    return TermuxStorageSummary(
      state: switch (values['state']) {
        'running' => TermuxStorageScanState.running,
        'done' => TermuxStorageScanState.done,
        'cancelled' => TermuxStorageScanState.cancelled,
        'failed' => TermuxStorageScanState.failed,
        'stale' => TermuxStorageScanState.stale,
        _ => TermuxStorageScanState.idle,
      },
      totalBytes: total == null || total < 0 ? null : total,
      scannedAtEpochSeconds: scanned == null || scanned <= 0 ? null : scanned,
    );
  }
}

class TermuxStorageRefusal {
  const TermuxStorageRefusal({
    required this.path,
    required this.reason,
    this.processes = const [],
  });
  final String path;
  final String reason;
  final List<String> processes;

  bool get inUse => reason == 'in_use';
}

class TermuxStorageCleanResult {
  const TermuxStorageCleanResult({
    required this.freedBytes,
    required this.removed,
    required this.refused,
    this.rescanRequired = false,
  });

  final bool rescanRequired;
  final int freedBytes;
  final List<TermuxStoragePath> removed;
  final List<TermuxStorageRefusal> refused;

  TermuxStorageRefusal? get inUse {
    for (final r in refused) {
      if (r.inUse) return r;
    }
    return null;
  }

  static TermuxStorageCleanResult parse(String json) {
    final decoded = jsonDecode(json.trim());
    if (decoded is! Map) {
      throw const TermuxBridgeException(
        'Could not read the clean result.',
        code: 'invalid_clean_result',
      );
    }
    return TermuxStorageCleanResult(
      freedBytes: _int(decoded['freed_bytes']),
      rescanRequired: decoded['rescan_required'] == true,
      removed: [
        for (final raw in decoded['removed'] as List? ?? const [])
          if (raw is Map)
            TermuxStoragePath(
              path: raw['path']?.toString() ?? '',
              bytes: _int(raw['bytes']),
            ),
      ],
      refused: [
        for (final raw in decoded['refused'] as List? ?? const [])
          if (raw is Map)
            TermuxStorageRefusal(
              path: raw['path']?.toString() ?? '',
              reason: raw['reason']?.toString() ?? '',
              processes: [
                for (final p in raw['processes'] as List? ?? const [])
                  p.toString(),
              ],
            ),
      ],
    );
  }
}

/// Runs the storage verbs of `~/.oc/tools.sh`.
class TermuxStorage {
  const TermuxStorage._();

  /// Starts a background scan; a scan already running is left alone.
  static Future<void> startScan() async {
    final out = await TermuxBridge.runTool('storage-scan');
    if (!RegExp(
      r'(^|\n)tools-(started|already-running):[0-9]+',
    ).hasMatch(out.trim())) {
      throw const TermuxBridgeException(
        'The storage scan did not start.',
        code: 'scan_not_started',
      );
    }
  }

  static Future<TermuxStorageScanStatus> status() async =>
      TermuxStorageScanStatus.parse(
        await TermuxBridge.runTool('storage-status'),
      );

  static Future<TermuxStorageSummary> summary() async =>
      TermuxStorageSummary.parse(
        await TermuxBridge.runTool(
          'storage-summary',
          timeout: const Duration(seconds: 10),
        ),
      );

  static Future<void> cancelScan() => TermuxBridge.runTool('storage-cancel');

  static Future<TermuxStorageCleanResult> clean(String category) async =>
      TermuxStorageCleanResult.parse(
        await TermuxBridge.runTool(
          'storage-clean',
          argument: category,
          timeout: const Duration(minutes: 5),
        ),
      );
}

int _int(Object? value) => switch (value) {
  int v => v,
  num v => v.toInt(),
  String v => int.tryParse(v) ?? 0,
  _ => 0,
};

/// "11.6 GB", "812 MB", "3 KB": one decimal above a gigabyte, none below.
/// Locale-neutral digits; the screen wraps the unit through l10n.
({String value, TermuxByteUnit unit}) splitBytes(int bytes) {
  const gb = 1024 * 1024 * 1024;
  const mb = 1024 * 1024;
  if (bytes >= gb) {
    final tenths = (bytes * 10 / gb).round();
    return (
      value: tenths % 10 == 0
          ? '${tenths ~/ 10}'
          : '${tenths ~/ 10}.${tenths % 10}',
      unit: TermuxByteUnit.gb,
    );
  }
  if (bytes >= mb) return (value: '${bytes ~/ mb}', unit: TermuxByteUnit.mb);
  if (bytes >= 1024) {
    return (value: '${bytes ~/ 1024}', unit: TermuxByteUnit.kb);
  }
  return (value: '$bytes', unit: TermuxByteUnit.b);
}

enum TermuxByteUnit { b, kb, mb, gb }

/// Shortens a phone path for display: the Ubuntu rootfs becomes `ubuntu:`,
/// Termux's prefix `termux:` and its home `~`.
String displayTermuxPath(String path) {
  const prefix = '/data/data/com.termux/files/usr';
  const home = TermuxBridge.termuxHome;
  final rootfs = RegExp(
    r'^/data/data/com\.termux/files/usr/var/lib/proot-distro/(?:containers/opencode-ubuntu/rootfs|installed-rootfs/opencode-ubuntu)',
  );
  final match = rootfs.firstMatch(path);
  if (match != null) return 'ubuntu:${path.substring(match.end)}';
  if (path.startsWith('$home/')) return '~${path.substring(home.length)}';
  if (path.startsWith('$prefix/')) {
    return 'termux:${path.substring(prefix.length)}';
  }
  return path;
}
