/// AI Team on this phone (TEAM-301): the Dart side of `~/.oc/aiteam.sh`.
///
/// [TermuxTeamRuntime] runs the script's verbs through the Termux bridge
/// (the same exec path the OpenCode manager uses: the bridge rewrites the
/// script, queues the verb and launches it detached in its own process
/// group), reads `aiteam.sh status` back as a [TeamRuntimeStatus], and
/// builds the [OrchestrationConfig] the Termux profile gets once the city
/// is ready (loopback, no front — `X-GC-Request` alone is trusted there).
///
/// The team runs inside Termux's managed Ubuntu from the upstream builds
/// the in-app Ubuntu uses ([AiTeamPins]); lib/termux/team_scripts.dart
/// says how.
///
/// Verb contract (what `aiteam.sh` accepts and writes; TEAM-302 drives it):
///
/// | Verb | Args | Phases written |
/// |---|---|---|
/// | `install` | — | downloading → verifying → installing-packages → installed; `failed:checksum-mismatch <name>` (exit 65, before anything is unpacked), `failed:unsupported-arch`, `failed:no-ubuntu`, `failed:pins`, `failed:download <kind> <host> <code>` (see [TeamDownloadFailure]), `failed:no-space`, `failed:packages`, `failed:blocked-syscall` (Android stopped a program: SIGSYS), `failed:runs-here`, `failed:unpack` |
/// | `init` | `<project path> [--city n] [--rig n]` | creating-city → city-ready; `failed:not-installed`, `failed:project-*`, `failed:rig-script`, `failed:gc-*` |
/// | `start` | — | starting → ready (health ok within 360 s); `failed:no-city`, `failed:supervisor-exited`, `failed:health-timeout` |
/// | `stop` | — | stopping → stopped |
/// | `remove` | — | removing → (state gone; `status.removed` lists what went) |
/// | `status` | — | inline JSON, see [TeamRuntimeStatus.parse] |
/// | `log` | — | inline: the live log path |
///
/// A verb that stops without writing a terminal phase is reported by the
/// next `status` as `failed` with `last_error` "… stopped unexpectedly".
library;

import 'dart:async';
import 'dart:convert';

import '../builtin/setup/aiteam_scripts.dart';
import '../domain/workspace_paths.dart'
    show managedProjectsDirectory, projectFolderNameProblem;
import '../state/profiles.dart'
    show
        OrchestrationConfig,
        OrchestrationHostKind,
        OrchestrationHostMode,
        OrchestrationProvider;
import 'bridge.dart';

/// Runs one bridge script and answers its stdout; throws
/// [TermuxBridgeException] on a non-zero exit. Injected in tests.
typedef TeamScriptRunner =
    Future<String> Function(String script, {Duration timeout});

/// The phases `aiteam.sh` writes, in the order a full setup passes them.
enum TeamRuntimePhase {
  /// No state file: nothing was ever installed (or it was removed).
  idle,

  /// A verb was dispatched and has not written its first phase yet.
  queued,
  downloading,
  verifying,
  installingPackages,

  /// `install` finished; no city yet.
  installed,
  creatingCity,

  /// `init` finished; the supervisor is not running.
  cityReady,
  starting,

  /// The supervisor answered the city health check.
  ready,
  stopping,
  stopped,
  removing,
  failed,

  /// A phase this build does not know (a newer script).
  unknown;

  /// True while a verb is expected to be running.
  bool get isTransient => switch (this) {
    queued ||
    downloading ||
    verifying ||
    installingPackages ||
    creatingCity ||
    starting ||
    stopping ||
    removing => true,
    _ => false,
  };

  static TeamRuntimePhase parse(String? raw) => switch (raw?.trim()) {
    null || '' || 'idle' => idle,
    'queued' => queued,
    'downloading' => downloading,
    'verifying' => verifying,
    'installing-packages' => installingPackages,
    'installed' => installed,
    'creating-city' => creatingCity,
    'city-ready' => cityReady,
    'starting' => starting,
    'ready' => ready,
    'stopping' => stopping,
    'stopped' => stopped,
    'removing' => removing,
    final other when other == 'failed' || other.startsWith('failed:') => failed,
    _ => unknown,
  };
}

/// One `aiteam.sh status` answer.
class TeamRuntimeStatus {
  const TeamRuntimeStatus({
    required this.phase,
    this.rawPhase = '',
    this.reason,
    this.message = '',
    this.verb = '',
    this.installed = false,
    this.versions = const {},
    this.busy = false,
    this.pid,
    this.supervisorPid,
    this.health,
    this.agents,
    this.city = '',
    this.rig = '',
    this.project = '',
    this.url = TermuxBridge.aiteamSupervisorUrl,
    this.lastError,
    this.killedByAndroid = false,
    this.removed = const [],
    this.logPath = '',
    this.updatedAt,
  });

  /// What an unreadable answer parses to, so a caller always has a phase.
  static const unreadable = TeamRuntimeStatus(
    phase: TeamRuntimePhase.unknown,
    lastError: 'status output was not JSON',
  );

  final TeamRuntimePhase phase;

  /// The phase as the state file spells it (`failed:checksum-mismatch gc`
  /// keeps its reason here; [reason] is that token alone and [lastError]
  /// the message).
  final String rawPhase;

  /// The failure token after `failed:` — `checksum-mismatch <name>`,
  /// `unsupported-arch`, `health-timeout`, `interrupted`, … — or null.
  final String? reason;
  final String message;

  /// The verb that wrote the phase (`install`, `init`, …).
  final String verb;

  /// gc, bd and dolt are unpacked in the managed Ubuntu (`/opt/aiteam`).
  final bool installed;

  /// `gc`, `bd`, `dolt` → the version installed (absent when not
  /// installed).
  final Map<String, String> versions;

  /// A verb is running right now (poll again).
  final bool busy;

  /// The running verb's pid, when [busy].
  final int? pid;

  /// The supervisor's pid, when alive.
  final int? supervisorPid;

  /// The city health status (`ok`), `unreachable`, or null when the
  /// supervisor is not running.
  final String? health;

  /// Agents the supervisor lists for the city, when it answered.
  final int? agents;
  final String city;
  final String rig;
  final String project;

  /// The loopback supervisor URL.
  final String url;

  /// The reason of the last failure, when [phase] is [TeamRuntimePhase.failed].
  final String? lastError;

  /// The state said `ready` but no supervisor process is alive: Android
  /// killed the tree while the app was away (spike §3g).
  final bool killedByAndroid;

  /// Paths the last `remove` deleted (cleared by the next install).
  final List<String> removed;
  final String logPath;
  final DateTime? updatedAt;

  bool get isReady =>
      phase == TeamRuntimePhase.ready && !killedByAndroid && health == 'ok';

  /// A city exists: `init` succeeded at some point and `remove` has not run.
  bool get hasCity => city.isNotEmpty;

  /// The `checksum-mismatch <name>` refusal of `install`.
  bool get checksumMismatch => reason?.startsWith('checksum-mismatch') ?? false;

  /// Why a download of `install` failed, or null when [reason] is not a
  /// download failure.
  TeamDownloadFailure? get downloadFailure => TeamDownloadFailure.parse(reason);

  /// Parses the `aiteam.sh status` JSON line; [unreadable] when it is not
  /// JSON so a UI still has a phase to show.
  factory TeamRuntimeStatus.parse(String raw) {
    final trimmed = raw.trim();
    final start = trimmed.indexOf('{');
    if (start < 0) return unreadable;
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed.substring(start));
    } on FormatException {
      return unreadable;
    }
    if (decoded is! Map) return unreadable;
    final map = decoded.cast<String, Object?>();
    final phase = map['phase']?.toString() ?? '';
    final rawPhase = map['state_phase']?.toString() ?? phase;
    final reason =
        map['reason']?.toString() ??
        (rawPhase.startsWith('failed:')
            ? rawPhase.substring('failed:'.length)
            : null);
    final versionsRaw = map['versions'];
    final versions = <String, String>{};
    if (versionsRaw is Map) {
      for (final entry in versionsRaw.entries) {
        final value = entry.value;
        if (value is String && value.isNotEmpty) {
          versions[entry.key.toString()] = value;
        }
      }
    }
    final removedRaw = map['removed'];
    final updated = _int(map['updated_at']);
    return TeamRuntimeStatus(
      phase: TeamRuntimePhase.parse(phase),
      rawPhase: rawPhase,
      reason: reason,
      message: map['message']?.toString() ?? '',
      verb: map['verb']?.toString() ?? '',
      installed: map['installed'] == true,
      versions: Map.unmodifiable(versions),
      busy: map['busy'] == true,
      pid: _int(map['pid']),
      supervisorPid: _int(map['supervisor_pid']),
      health: map['health']?.toString(),
      agents: _int(map['agents']),
      city: map['city']?.toString() ?? '',
      rig: map['rig']?.toString() ?? '',
      project: map['project']?.toString() ?? '',
      url: map['url']?.toString() ?? TermuxBridge.aiteamSupervisorUrl,
      lastError: map['last_error']?.toString(),
      killedByAndroid: map['killed_by_android'] == true,
      removed: removedRaw is List
          ? List.unmodifiable(removedRaw.map((e) => e.toString()))
          : const [],
      logPath: map['log']?.toString() ?? '',
      updatedAt: updated == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(updated * 1000, isUtc: true),
    );
  }

  static int? _int(Object? value) => switch (value) {
    final int i => i,
    final num n => n.toInt(),
    final String s => int.tryParse(s),
    _ => null,
  };

  @override
  String toString() =>
      'TeamRuntimeStatus(${phase.name}${busy ? ' busy' : ''}'
      '${killedByAndroid ? ' killed' : ''}'
      '${lastError == null ? '' : ' error=$lastError'})';
}

/// What kind of network trouble stopped a download (`aiteam.sh` maps
/// curl's exit code onto these).
enum TeamDownloadFailureKind {
  /// The host name did not resolve (curl 6).
  dns,

  /// Nothing answered on the host (curl 7).
  connect,

  /// The host took too long (curl 28).
  timeout,

  /// The secure connection failed: often a wrong clock or a proxy.
  tls,

  /// The server answered with an HTTP error status.
  http,

  /// The connection dropped mid-file.
  interrupted,

  /// The file could not be written on the phone.
  write,

  /// Anything else, or an older script that gave no detail.
  other,
}

/// The `download <kind> <host> <code>` reason of a failed `install`: the
/// kind of failure, the host that was asked, and the HTTP status (for
/// [TeamDownloadFailureKind.http]) or curl's exit code.
class TeamDownloadFailure {
  const TeamDownloadFailure({required this.kind, this.host = '', this.code});

  final TeamDownloadFailureKind kind;
  final String host;
  final int? code;

  /// Null when [reason] is not a download failure; a bare `download` (no
  /// detail) parses to [TeamDownloadFailureKind.other].
  static TeamDownloadFailure? parse(String? reason) {
    final parts = (reason ?? '').trim().split(RegExp(r'\s+'));
    if (parts.first != 'download') return null;
    final kind = parts.length > 1
        ? TeamDownloadFailureKind.values.firstWhere(
            (k) => k.name == parts[1],
            orElse: () => TeamDownloadFailureKind.other,
          )
        : TeamDownloadFailureKind.other;
    return TeamDownloadFailure(
      kind: kind,
      host: parts.length > 2 ? parts[2] : '',
      code: parts.length > 3 ? int.tryParse(parts[3]) : null,
    );
  }
}

/// What setting up the team downloads: the pinned upstream builds for the
/// phone's CPU ([TeamRuntimeManifest.pinned]). [parse] reads the schema-1
/// manifests of the earlier native layout (`assets/aiteam/manifest*.json`),
/// which nothing downloads from any more.
class TeamRuntimeManifest {
  const TeamRuntimeManifest({
    required this.json,
    required this.arch,
    required this.gascity,
    required this.beads,
    required this.dolt,
    required this.baseUrl,
    this.totalBytes = 0,
  });

  /// The manifest as JSON (for a pinned one, what [pinned] describes).
  final String json;
  final String arch;
  final String gascity;
  final String beads;
  final String dolt;
  final String baseUrl;

  /// The declared size of every file the install downloads, summed; 0 when
  /// the manifest declares none (the onboarding copy then falls back to
  /// the spike's estimate).
  final int totalBytes;

  /// The pinned upstream [downloads] for [arch] (`arm64` or `x86_64`), plus
  /// the few Ubuntu packages (about 3 MB).
  factory TeamRuntimeManifest.pinned(
    String arch,
    List<AiTeamDownload> downloads,
  ) => TeamRuntimeManifest(
    json: jsonEncode({
      'schema': 2,
      'source': 'upstream',
      'arch': arch,
      'gascity': AiTeamPins.gascity,
      'beads': AiTeamPins.beads,
      'dolt': AiTeamPins.dolt,
      'files': {
        for (final download in downloads)
          download.tool: {
            'url': download.url,
            'bytes': download.bytes,
            'sha256': download.sha256,
          },
      },
    }),
    arch: arch,
    gascity: AiTeamPins.gascity,
    beads: AiTeamPins.beads,
    dolt: AiTeamPins.dolt,
    baseUrl: '',
    totalBytes: AiTeamPins.bytesFor(downloads) + 3000000,
  );

  /// Null for a manifest this build cannot use (not JSON, not schema 1, no
  /// files).
  static TeamRuntimeManifest? parse(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final map = decoded.cast<String, Object?>();
    if (map['schema'] != 1) return null;
    final files = map['files'];
    if (files is! Map ||
        !{'gc', 'bd', 'dolt', 'wrapper'}.every(files.containsKey)) {
      return null;
    }
    var totalBytes = 0;
    for (final file in files.values) {
      if (file is Map) {
        final bytes = file['bytes'];
        if (bytes is num) totalBytes += bytes.toInt();
      }
    }
    return TeamRuntimeManifest(
      json: raw,
      arch: map['arch']?.toString() ?? '',
      gascity: map['gascity']?.toString() ?? '',
      beads: map['beads']?.toString() ?? '',
      dolt: map['dolt']?.toString() ?? '',
      baseUrl: map['base_url']?.toString() ?? '',
      totalBytes: totalBytes,
    );
  }
}

/// The managed Gas City runtime on this phone.
class TermuxTeamRuntime {
  /// [manifestLoader], when given, replaces the pinned downloads with a
  /// manifest's JSON (tests; null means none).
  TermuxTeamRuntime({
    TeamScriptRunner? runner,
    Future<String?> Function()? manifestLoader,
    Future<String?> Function()? archProbe,
    this.pollInterval = const Duration(seconds: 5),
    this.verbTimeout = const Duration(minutes: 30),
  }) : _runner = runner ?? _bridgeRunner,
       _manifestLoader = manifestLoader,
       _archProbe = archProbe ?? _bridgeArch;

  /// The earlier native layout's manifests (Android builds from a release
  /// of this project that was never published, issue #87). Still shipped
  /// and still checked by test/shipped_download_urls_test.dart; nothing
  /// reads them.
  static const manifestAsset = 'assets/aiteam/manifest.json';
  static const manifestAssetX86 = 'assets/aiteam/manifest-x86_64.json';

  final TeamScriptRunner _runner;
  final Future<String?> Function()? _manifestLoader;
  final Future<String?> Function() _archProbe;

  /// How often [statusStream] polls while a verb runs.
  final Duration pollInterval;

  /// How long a verb may stay busy before its poll gives up.
  final Duration verbTimeout;

  Future<TeamRuntimeManifest?>? _manifest;
  Future<bool>? _arm64;

  static Future<String> _bridgeRunner(
    String script, {
    Duration timeout = const Duration(seconds: 30),
  }) async => (await TermuxBridge.run(script, timeout: timeout)).stdout;

  static Future<String?> _bridgeArch() async {
    try {
      return (await TermuxBridge.run('uname -m')).stdout;
    } on TermuxBridgeException {
      return null;
    }
  }

  /// What setting up downloads, once: the pinned upstream builds for this
  /// phone's CPU (arm64 unless Termux reports x86_64, the emulator).
  Future<TeamRuntimeManifest?> manifest() => _manifest ??= _loadManifest();

  Future<TeamRuntimeManifest?> _loadManifest() async {
    final loader = _manifestLoader;
    if (loader != null) {
      final raw = await loader();
      return raw == null ? null : TeamRuntimeManifest.parse(raw);
    }
    return await isX86_64
        ? TeamRuntimeManifest.pinned('x86_64', AiTeamPins.x64)
        : TeamRuntimeManifest.pinned('arm64', AiTeamPins.arm64);
  }

  /// The Termux side reports a 64-bit ARM machine (`uname -m`), once.
  Future<bool> get isArm64 => _arm64 ??= _archProbe().then((arch) {
    final value = arch?.trim().toLowerCase() ?? '';
    return value == 'aarch64' || value == 'arm64';
  });

  /// The optional onboarding block may be shown: the device is 64-bit ARM
  /// (or x86, the emulator) and there are downloads for it
  /// (03-onboarding §2).
  Future<bool> get supportsAiTeam async {
    final manifest = await this.manifest();
    if (manifest == null) return false;
    if (manifest.arch == 'x86_64') return isX86_64;
    if (manifest.arch != 'arm64') return false;
    return isArm64;
  }

  Future<bool>? _x86;

  /// The Termux side reports a 64-bit x86 machine (the emulator), once.
  Future<bool> get isX86_64 => _x86 ??= _archProbe().then((arch) {
    final value = arch?.trim().toLowerCase() ?? '';
    return value == 'x86_64' || value == 'amd64';
  });

  /// Why [supportsAiTeam] is false, for the Settings line; null when it is
  /// true.
  Future<String?> get unsupportedReason async {
    final manifest = await this.manifest();
    if (manifest == null ||
        (manifest.arch != 'arm64' && manifest.arch != 'x86_64')) {
      return 'this build ships no AI Team runtime for the phone';
    }
    if (manifest.arch == 'x86_64') {
      return await isX86_64 ? null : 'the manifest is for x86_64 devices';
    }
    if (!await isArm64) return 'the phone is not a 64-bit ARM device';
    return null;
  }

  /// One `status` read.
  Future<TeamRuntimeStatus> status() async =>
      TeamRuntimeStatus.parse(await _runner(TermuxBridge.aiteamStatusScript()));

  /// The live log path (`~/.oc/aiteam/aiteam.log`).
  Future<String> logPath() async =>
      (await _runner(TermuxBridge.aiteamLogPathScript())).trim();

  /// The last [lines] of the live log, for the setup screen's output panel
  /// (the same text `aiteam.sh` mirrors into the OpenCode install log).
  /// Empty when nothing has run yet or the bridge fails: the panel then
  /// shows its "waiting for output" state rather than an error.
  Future<String> logTail({int lines = 200}) async {
    try {
      return await _runner(TermuxBridge.aiteamLogTailScript(lines: lines));
    } on TermuxBridgeException {
      return '';
    }
  }

  /// The managed server's project folders as the server names them
  /// (`/root/projects/<name>`), for the onboarding step's default project.
  /// Empty when the rootfs has none or cannot be read.
  Future<List<String>> managedProjects() async {
    String output;
    try {
      output = await _runner(TermuxBridge.aiteamProjectsScript());
    } on TermuxBridgeException {
      return const [];
    }
    return [
      for (final line in output.split('\n'))
        if (line.trim().isNotEmpty && !line.contains('/'))
          '$managedProjectsDirectory/${line.trim()}',
    ];
  }

  /// Status every [pollInterval] while a verb runs; the last event is the
  /// first non-busy status (or the status at [verbTimeout]).
  Stream<TeamRuntimeStatus> statusStream() async* {
    final deadline = DateTime.now().add(verbTimeout);
    while (true) {
      final current = await status();
      yield current;
      if (!current.busy || DateTime.now().isAfter(deadline)) return;
      await Future<void>.delayed(pollInterval);
    }
  }

  /// Creates `/root/projects/<name>` on the managed server for the
  /// onboarding step when it has no project yet, and returns that path.
  /// Throws [TermuxBridgeException] for a bad name or a folder that did not
  /// appear.
  Future<String> createManagedProject(String name) async {
    final problem = projectFolderNameProblem(name);
    if (problem != null) {
      throw TermuxBridgeException(problem, code: 'invalid_folder_name');
    }
    final folder = name.trim();
    final output = await _runner(
      TermuxBridge.createProjectFolderScript(folder),
      timeout: const Duration(seconds: 45),
    );
    final path = output.trim().split('\n').last.trim();
    if (path != '$managedProjectsDirectory/$folder') {
      throw const TermuxBridgeException(
        'The folder could not be created in the managed server.',
        code: 'folder_not_created',
      );
    }
    return path;
  }

  /// Downloads the pinned upstream gc, bd and dolt (checked against their
  /// SHA-256 before anything is unpacked) and installs them in the managed
  /// Ubuntu with the packages the team needs. Does nothing more when they
  /// are installed at the pinned versions already.
  Future<TeamRuntimeStatus> install() => _dispatch('install');

  /// Makes the team's store once and adds [projectPath] (a path inside the
  /// managed Ubuntu) to it, with an origin on the phone
  /// (`/root/aiteam/origins`) when the project has none.
  Future<TeamRuntimeStatus> init(
    String projectPath, {
    String? city,
    String? rig,
  }) => _dispatch(
    'init',
    args: [
      projectPath,
      if (city != null) ...['--city', city],
      if (rig != null) ...['--rig', rig],
    ],
  );

  Future<TeamRuntimeStatus> start() => _dispatch('start');

  Future<TeamRuntimeStatus> stop() => _dispatch('stop');

  /// Stops the team and deletes the programs, the team's store and its
  /// settings; the project and its phone-side origin stay.
  Future<TeamRuntimeStatus> remove() => _dispatch('remove');

  /// Runs `install`, `init` and `start` in turn, stopping at the first
  /// phase that is not the expected outcome.
  Future<TeamRuntimeStatus> setUp(
    String projectPath, {
    String? city,
    String? rig,
  }) async {
    var status = await install();
    if (status.phase != TeamRuntimePhase.installed) return status;
    status = await init(projectPath, city: city, rig: rig);
    if (status.phase != TeamRuntimePhase.cityReady) return status;
    return start();
  }

  /// The AI Team plugin config for the Termux profile once [status] is
  /// ready: Gas City on loopback, this phone as host, no front (03 §3).
  OrchestrationConfig phoneOrchestrationConfig(
    TeamRuntimeStatus status, {
    DateTime? enabledAt,
  }) => OrchestrationConfig(
    provider: OrchestrationProvider.gascity,
    url: status.url.isEmpty ? TermuxBridge.aiteamSupervisorUrl : status.url,
    city: status.city,
    hostMode: OrchestrationHostMode.phone,
    hostKind: OrchestrationHostKind.phone,
    front: false,
    enabledAt: enabledAt ?? DateTime.now(),
  );

  Future<TeamRuntimeStatus> _dispatch(
    String verb, {
    List<String> args = const [],
  }) async {
    final output = await _runner(
      TermuxBridge.aiteamVerbScript(verb, args: args),
      timeout: const Duration(seconds: 30),
    );
    if (!RegExp(r'(^|\n)aiteam-started:[0-9]+\s*$').hasMatch(output.trim())) {
      throw TermuxBridgeException(
        'The AI Team $verb did not start: ${output.trim()}',
        code: 'aiteam_dispatch_failed',
      );
    }
    return statusStream().last;
  }
}
