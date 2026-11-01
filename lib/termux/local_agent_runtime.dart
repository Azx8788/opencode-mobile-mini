/// Claude Code on this phone: the Dart side of `~/.oc/claude.sh`.
///
/// [LocalAgentRuntime] runs the script's verbs through the Termux bridge
/// (the bridge rewrites the script and its pins, queues a long verb and
/// launches it detached in its own process group) and reads
/// `claude.sh status` back as a [LocalAgentStatus].
///
/// Verb contract (what `claude.sh` accepts and writes):
///
/// | Verb | Runs | Phases |
/// |---|---|---|
/// | `install` | detached | installing (step node → paseo → claude) → installed; failed with `needs_ubuntu`, `no_space`, `download`, `checksum`, `native_build`, `npm`, `unsupported_arch`, `pins` |
/// | `start` | detached | starting → ready (health ok within 120 s); failed with `not_installed`, `port_in_use`, `daemon_exited`, `timeout` |
/// | `restart` | detached | starting → ready |
/// | `stop` | inline | stopping → installed |
/// | `remove [--forget-signin]` | detached | removing → (state gone: absent) |
/// | `status` | inline | `key=value`, see [LocalAgentStatus.parse] |
/// | `password` | inline | the daemon password and nothing else |
/// | `signin-status` | inline | `signed_in=yes|no|unknown` |
/// | `projects` | inline | `project=<path inside Ubuntu>` per folder |
/// | `ensure-project <path>` | inline | creates the folder inside Ubuntu |
///
/// `absent` and `needs_ubuntu` are never written to the state file; status
/// derives them. `ready` is only ever reported after a live health probe.
library;

import 'dart:async';

import 'bridge.dart';

/// Runs one bridge script and answers its stdout; throws
/// [TermuxBridgeException] on a non-zero exit. Injected in tests.
typedef LocalAgentScriptRunner =
    Future<String> Function(String script, {Duration timeout});

/// Opens a visible Termux terminal running the given command.
typedef LocalAgentTerminalOpener = Future<bool> Function(String command);

enum LocalAgentPhase {
  /// Ubuntu is there; Claude Code is not installed.
  absent,

  /// The app-managed Ubuntu is missing: the normal phone setup comes first.
  needsUbuntu,
  installing,

  /// Installed and not running.
  installed,
  starting,

  /// The daemon answered its health check when status was read.
  ready,
  stopping,
  removing,
  failed,

  /// A phase this build does not know (a newer script) or unreadable output.
  unknown;

  bool get isTransient => switch (this) {
    installing || starting || stopping || removing => true,
    _ => false,
  };

  static LocalAgentPhase parse(String? raw) => switch (raw?.trim()) {
    'absent' => absent,
    'needs_ubuntu' => needsUbuntu,
    'installing' => installing,
    'installed' => installed,
    'starting' => starting,
    'ready' => ready,
    'stopping' => stopping,
    'removing' => removing,
    'failed' => failed,
    _ => unknown,
  };
}

/// Why a verb failed, from the script's `failure_kind`.
enum LocalAgentFailureKind {
  needsUbuntu,
  noSpace,
  download,
  checksum,
  nativeBuild,
  portInUse,
  timeout,

  /// The bridge itself failed (Termux missing, permission, dispatch).
  bridge,
  notInstalled,
  unsupportedArch,

  /// A verb stopped without finishing (Android killed it).
  interrupted,

  /// The daemon process exited or stopped answering.
  daemon,

  /// npm failed for a reason that is not a native build (usually network).
  packages,
  other;

  static LocalAgentFailureKind? parse(String? raw) => switch (raw?.trim()) {
    null || '' => null,
    'needs_ubuntu' => needsUbuntu,
    'no_space' => noSpace,
    'download' => download,
    'checksum' => checksum,
    'native_build' => nativeBuild,
    'port_in_use' => portInUse,
    'timeout' => timeout,
    'not_installed' => notInstalled,
    'unsupported_arch' => unsupportedArch,
    'interrupted' => interrupted,
    'daemon_exited' || 'unhealthy' => daemon,
    'npm' => packages,
    _ => other,
  };
}

/// The install step a status belongs to.
enum LocalAgentStep {
  node,
  paseo,
  claude;

  static LocalAgentStep? parse(String? raw) => switch (raw?.trim()) {
    'node' => node,
    'paseo' => paseo,
    'claude' => claude,
    _ => null,
  };
}

enum LocalAgentSignIn {
  yes,
  no,
  unknown;

  static LocalAgentSignIn parse(String? raw) => switch (raw?.trim()) {
    'yes' => yes,
    'no' => no,
    _ => unknown,
  };
}

/// A verb that failed, typed for the UI.
class LocalAgentFailure implements Exception {
  const LocalAgentFailure(this.kind, this.message);

  final LocalAgentFailureKind kind;
  final String message;

  @override
  String toString() => message;
}

/// One `claude.sh status` answer.
class LocalAgentStatus {
  const LocalAgentStatus({
    required this.phase,
    this.message = '',
    this.busy = false,
    this.verb = '',
    this.step,
    this.installed = false,
    this.nodeVersion = '',
    this.paseoVersion = '',
    this.claudeVersion = '',
    this.pid,
    this.port = TermuxBridge.localAgentsPort,
    this.signedIn = LocalAgentSignIn.unknown,
    this.failureKind,
    this.killedByAndroid = false,
    this.updatedAt,
  });

  static const unreadable = LocalAgentStatus(phase: LocalAgentPhase.unknown);

  final LocalAgentPhase phase;
  final String message;

  /// A verb is running right now (poll again).
  final bool busy;
  final String verb;
  final LocalAgentStep? step;

  /// Node, Paseo and Claude Code are all present in Ubuntu.
  final bool installed;
  final String nodeVersion;
  final String paseoVersion;
  final String claudeVersion;

  /// The daemon runner's pid, when alive.
  final int? pid;
  final int port;
  final LocalAgentSignIn signedIn;
  final LocalAgentFailureKind? failureKind;

  /// The state said `ready` but the daemon was gone: Android stopped it
  /// while the app was away.
  final bool killedByAndroid;
  final DateTime? updatedAt;

  bool get isReady => phase == LocalAgentPhase.ready;

  /// The typed failure of a `failed` status, or null.
  LocalAgentFailure? get failure => phase == LocalAgentPhase.failed
      ? LocalAgentFailure(failureKind ?? LocalAgentFailureKind.other, message)
      : null;

  /// Parses `key=value` lines; unknown keys are ignored and a missing
  /// `phase` reads as [unreadable], so a UI always has a phase to show.
  factory LocalAgentStatus.parse(String raw) {
    final values = <String, String>{};
    for (final line in raw.split('\n')) {
      final separator = line.indexOf('=');
      if (separator <= 0) continue;
      values[line.substring(0, separator).trim()] = line
          .substring(separator + 1)
          .trimRight();
    }
    if (!values.containsKey('phase')) return unreadable;
    final updated = int.tryParse(values['updated_at'] ?? '');
    final phase = LocalAgentPhase.parse(values['phase']);
    return LocalAgentStatus(
      phase: phase,
      message: values['message'] ?? '',
      busy: values['busy'] == 'yes',
      verb: values['verb'] ?? '',
      step: LocalAgentStep.parse(values['step']),
      installed: values['installed'] == 'yes',
      nodeVersion: values['node_version'] ?? '',
      paseoVersion: values['paseo_version'] ?? '',
      claudeVersion: values['claude_version'] ?? '',
      pid: int.tryParse(values['pid'] ?? ''),
      port: int.tryParse(values['port'] ?? '') ?? TermuxBridge.localAgentsPort,
      signedIn: LocalAgentSignIn.parse(values['signed_in']),
      failureKind: phase == LocalAgentPhase.failed
          ? (LocalAgentFailureKind.parse(values['failure_kind']) ??
                LocalAgentFailureKind.other)
          : null,
      killedByAndroid: values['killed'] == 'yes',
      updatedAt: updated == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(updated * 1000, isUtc: true),
    );
  }

  @override
  String toString() =>
      'LocalAgentStatus(${phase.name}${busy ? ' busy' : ''}'
      '${failureKind == null ? '' : ' ${failureKind!.name}'})';
}

/// The Paseo daemon and Claude Code in the app-managed Ubuntu.
class LocalAgentRuntime {
  LocalAgentRuntime({
    LocalAgentScriptRunner? runner,
    LocalAgentTerminalOpener? terminalOpener,
    this.pollInterval = const Duration(seconds: 3),
    this.verbTimeout = const Duration(minutes: 40),
  }) : _runner = runner ?? _bridgeRunner,
       _terminalOpener = terminalOpener ?? TermuxBridge.openTerminalSession;

  final LocalAgentScriptRunner _runner;
  final LocalAgentTerminalOpener _terminalOpener;

  /// How often [statusStream] polls while a verb runs.
  final Duration pollInterval;

  /// How long a verb may stay busy before its poll gives up.
  final Duration verbTimeout;

  static Future<String> _bridgeRunner(
    String script, {
    Duration timeout = const Duration(seconds: 30),
  }) async => (await TermuxBridge.run(script, timeout: timeout)).stdout;

  Future<String> _run(String script, {required Duration timeout}) async {
    try {
      return await _runner(script, timeout: timeout);
    } on TermuxBridgeException catch (error) {
      throw LocalAgentFailure(LocalAgentFailureKind.bridge, error.message);
    }
  }

  /// One `status` read.
  Future<LocalAgentStatus> status() async => LocalAgentStatus.parse(
    await _run(
      TermuxBridge.localAgentsVerbScript('status'),
      // A health probe that has to time out twice still fits.
      timeout: const Duration(seconds: 40),
    ),
  );

  /// The last [lines] of the install log; empty when nothing ran yet or the
  /// bridge failed, so the panel shows "waiting" rather than an error.
  Future<String> logTail({int lines = 200}) async {
    try {
      return await _runner(
        TermuxBridge.localAgentsLogTailScript(lines: lines),
        timeout: const Duration(seconds: 15),
      );
    } on TermuxBridgeException {
      return '';
    }
  }

  /// Status every [pollInterval] while a verb runs; the last event is the
  /// first non-busy status (or the status at [verbTimeout]).
  Stream<LocalAgentStatus> statusStream() async* {
    final deadline = DateTime.now().add(verbTimeout);
    while (true) {
      final current = await status();
      yield current;
      if (!current.busy || DateTime.now().isAfter(deadline)) return;
      await Future<void>.delayed(pollInterval);
    }
  }

  /// Installs Node.js, Paseo and Claude Code. Throws [LocalAgentFailure]
  /// when the install ends in `failed`.
  Future<LocalAgentStatus> install() => _dispatch('install');

  Future<LocalAgentStatus> start() => _dispatch('start');

  Future<LocalAgentStatus> restart() => _dispatch('restart');

  Future<LocalAgentStatus> stop() async {
    await _run(
      TermuxBridge.localAgentsVerbScript('stop'),
      timeout: const Duration(seconds: 60),
    );
    return _settled(await status(), 'stop');
  }

  /// Removes the daemon, Node and the packages. The person's Claude sign-in
  /// (`~/.claude` in Ubuntu) stays unless [forgetSignIn].
  Future<LocalAgentStatus> remove({bool forgetSignIn = false}) =>
      _dispatch('remove', args: [if (forgetSignIn) '--forget-signin']);

  /// The daemon password. It goes into the saved server's secure storage
  /// and nowhere else: never log or display it.
  Future<String> password() async {
    final output = await _run(
      TermuxBridge.localAgentsVerbScript('password'),
      timeout: const Duration(seconds: 20),
    );
    final value = output.trim();
    if (!RegExp(r'^[0-9a-f]{48}$').hasMatch(value)) {
      throw const LocalAgentFailure(
        LocalAgentFailureKind.other,
        'The daemon password on this phone is missing. Start Claude Code '
        'again.',
      );
    }
    return value;
  }

  Future<LocalAgentSignIn> signInStatus() async {
    final output = await _run(
      TermuxBridge.localAgentsVerbScript('signin-status'),
      timeout: const Duration(seconds: 20),
    );
    final match = RegExp(
      r'(^|\n)signed_in=(yes|no|unknown)\s*($|\n)',
    ).firstMatch(output);
    return LocalAgentSignIn.parse(match?[2]);
  }

  /// Opens a Termux terminal running Claude's own sign-in. The app never
  /// sees the credential; it re-reads [signInStatus] when the person
  /// returns. False when Termux could not be opened.
  Future<bool> openSignIn() async {
    // The terminal command only names the script, so make sure this build's
    // copy is on disk first.
    await signInStatus();
    try {
      return await _terminalOpener(TermuxBridge.localAgentsSignInCommand);
    } on TermuxBridgeException catch (error) {
      throw LocalAgentFailure(LocalAgentFailureKind.bridge, error.message);
    }
  }

  /// Project folders under `~/projects` as Ubuntu sees them. The script
  /// creates `my-first-project` (with `git init`) when there are none.
  Future<List<String>> projects() async {
    final output = await _run(
      TermuxBridge.localAgentsVerbScript('projects'),
      timeout: const Duration(seconds: 60),
    );
    return [
      for (final line in output.split('\n'))
        if (line.startsWith('project=/'))
          line.substring('project='.length).trim(),
    ];
  }

  /// Creates [path] (absolute, inside Ubuntu) when it does not exist yet.
  Future<String> ensureProject(String path) async {
    final output = await _run(
      TermuxBridge.localAgentsVerbScript('ensure-project', args: [path]),
      timeout: const Duration(seconds: 60),
    );
    if (!output.split('\n').any((line) => line.trim() == 'project=$path')) {
      throw const LocalAgentFailure(
        LocalAgentFailureKind.other,
        'The folder could not be created in Ubuntu.',
      );
    }
    return path;
  }

  Future<LocalAgentStatus> _dispatch(
    String verb, {
    List<String> args = const [],
  }) async {
    final output = await _run(
      TermuxBridge.localAgentsVerbScript(verb, args: args),
      timeout: const Duration(seconds: 30),
    );
    if (!RegExp(r'(^|\n)claude-started:[0-9]+\s*$').hasMatch(output.trim())) {
      throw LocalAgentFailure(
        LocalAgentFailureKind.bridge,
        'Claude Code $verb did not start: ${output.trim()}',
      );
    }
    return _settled(await statusStream().last, verb);
  }

  LocalAgentStatus _settled(LocalAgentStatus status, String verb) {
    final failure = status.failure;
    if (failure != null) throw failure;
    if (status.busy) {
      throw LocalAgentFailure(
        LocalAgentFailureKind.timeout,
        'Claude Code $verb is still running. Check again in a moment.',
      );
    }
    return status;
  }
}
