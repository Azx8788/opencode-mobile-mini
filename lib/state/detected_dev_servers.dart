import 'dart:math';

import 'package:flutter/foundation.dart';

import '../domain/ansi_text.dart';
import '../domain/listening_ports.dart';
import '../domain/managed_shell.dart';

/// Where a detected dev server was found.
enum DetectedSource {
  /// A program listening on a port in the in-app Linux (any starter).
  process,

  /// A command the connected server is running as a managed shell (the agent
  /// started it, or another app).
  shell,
}

/// A dev server this project did not save as a command: found running.
@immutable
class DetectedServer {
  const DetectedServer({
    required this.id,
    required this.source,
    required this.name,
    required this.command,
    required this.ports,
    this.pid = 0,
    this.shellId,
    this.cwd,
    this.logPath,
    this.loopbackOnly = true,
  });

  final String id;
  final DetectedSource source;
  final String name;
  final String command;
  final List<int> ports;
  final int pid;
  final String? shellId;
  final String? cwd;
  final String? logPath;
  final bool loopbackOnly;

  bool get hasLogs => source == DetectedSource.shell || logPath != null;
  bool get canStop => source == DetectedSource.shell || pid > 0;
  bool get canSave => command.trim().isNotEmpty;
  int? get firstPort => ports.isEmpty ? null : ports.first;

  /// A short title from a command line: `node …/vite --port 5173` is "vite",
  /// `npm run dev` stays whole.
  static String nameFor(String command) {
    final tokens = command
        .trim()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return '';
    const runners = {'npm', 'yarn', 'pnpm', 'bun', 'npx', 'uv', 'cargo', 'go'};
    const interpreters = {
      'node',
      'python',
      'python3',
      'ruby',
      'bash',
      'sh',
      'php',
      'java',
      'deno',
      'dart',
      'flutter',
    };
    String base(String t) => t.split('/').last;
    if (runners.contains(base(tokens.first))) {
      return tokens.take(3).join(' ');
    }
    final head = base(tokens.first);
    if (head.startsWith('python') && tokens.length > 2 && tokens[1] == '-m') {
      return tokens[2];
    }
    var i = 0;
    while (i < tokens.length - 1 &&
        (interpreters.contains(base(tokens[i])) || tokens[i].startsWith('-'))) {
      i++;
    }
    final name = base(tokens[i]);
    if (name.isEmpty) return tokens.take(3).join(' ');
    return name.length > 40 ? name.substring(0, 40) : name;
  }
}

typedef PhoneRunResult = ({int exitCode, String output});

/// Finds, reads and stops dev servers the saved commands do not own.
///
/// Two sources, either may be missing: the in-app Linux ([runOnPhone] is set
/// only when the connected server is the phone itself) and the connected
/// server's managed shells ([resolveGateway]).
class DetectedDevServers extends ChangeNotifier {
  DetectedDevServers({
    required this.directory,
    required this.resolveGateway,
    required this.isCurrent,
    this.runOnPhone,
    this.ownedShellIds,
    this.now = DateTime.now,
  });

  final String directory;
  final Future<ManagedShellGateway?> Function() resolveGateway;
  final bool Function() isCurrent;

  /// Runs a bash script in the in-app Linux; null when the server is not
  /// the phone, where listening ports cannot be read.
  final Future<PhoneRunResult> Function(String script)? runOnPhone;

  /// Shell ids that saved commands own; they are not listed here but their
  /// ports are still found ([portsForShell]).
  final Set<String> Function()? ownedShellIds;
  final DateTime Function() now;

  List<DetectedServer> servers = const [];

  /// True once a scan finished, even an empty one.
  bool scanned = false;
  bool scanning = false;
  Object? error;
  bool _disposed = false;
  int _generation = 0;

  /// Stops in progress, and a count that moves whenever one starts or ends.
  /// A look at the phone that overlaps its own stop can fail (the phone is
  /// busy ending the program): that failure is the stop's doing, so the last
  /// list stays and no failure is reported for it.
  int _stopping = 0;
  int _stopEpoch = 0;

  /// Ports found in each shell's own output, and when that was last read.
  final Map<String, List<int>> _shellPorts = {};
  final Map<String, DateTime> _shellScanned = {};

  bool get canScanProcesses => runOnPhone != null;

  List<int> portsForShell(String id) => _shellPorts[id] ?? const [];

  DetectedServer? forPort(int port) {
    for (final server in servers) {
      if (server.ports.contains(port)) return server;
    }
    return null;
  }

  /// Every port of every detected server, for the conversation menu.
  List<int> get allPorts =>
      {for (final server in servers) ...server.ports}.toList()..sort();

  void invalidate() {
    _generation++;
    servers = const [];
    scanned = false;
    scanning = false;
    _shellPorts.clear();
    _shellScanned.clear();
    _notify();
  }

  bool _ok(int generation) =>
      !_disposed && isCurrent() && generation == _generation;

  Future<void> refresh() async {
    if (scanning || _disposed || !isCurrent()) return;
    final generation = ++_generation;
    final epoch = _stopEpoch;
    scanning = true;
    Object? failure;
    final found = <DetectedServer>[];
    try {
      final owned = ownedShellIds?.call() ?? const <String>{};
      final shellPortSet = <int>{};
      final gateway = await resolveGateway();
      if (!_ok(generation)) return;
      if (gateway != null) {
        try {
          final list = await gateway.loadRunningShells();
          if (!_ok(generation)) return;
          var scans = 0;
          final live = <String>{};
          for (final shell in list.shells.where((s) => s.running)) {
            live.add(shell.id);
            var ports = _shellPorts[shell.id];
            final last = _shellScanned[shell.id];
            final stale =
                ports == null ||
                (ports.isEmpty &&
                    last != null &&
                    now().difference(last) > const Duration(seconds: 20));
            if (stale && scans < 6) {
              scans++;
              ports = await _portsInShell(gateway, shell.id);
              if (!_ok(generation)) return;
              _shellPorts[shell.id] = ports;
              _shellScanned[shell.id] = now();
            }
            ports ??= const [];
            shellPortSet.addAll(ports);
            if (owned.contains(shell.id)) continue;
            found.add(
              DetectedServer(
                id: 'shell:${shell.id}',
                source: DetectedSource.shell,
                name: DetectedServer.nameFor(shell.command),
                command: shell.command,
                ports: ports,
                shellId: shell.id,
                cwd: shell.directory,
              ),
            );
          }
          _shellPorts.removeWhere((id, _) => !live.contains(id));
          _shellScanned.removeWhere((id, _) => !live.contains(id));
        } catch (e) {
          failure = e;
        }
      }
      final run = runOnPhone;
      if (run != null) {
        try {
          final result = await run(ListeningPorts.script());
          if (!_ok(generation)) return;
          for (final p in ListeningPorts.parse(result.output)) {
            // The same program is already listed as the shell that runs it,
            // or as a saved command.
            if (p.ports.any(shellPortSet.contains)) continue;
            final name = p.hasProcess ? DetectedServer.nameFor(p.command) : '';
            found.add(
              DetectedServer(
                id: p.hasProcess ? 'pid:${p.pid}' : 'port:${p.ports.first}',
                source: DetectedSource.process,
                name: name,
                command: p.command,
                ports: p.ports,
                pid: p.pid,
                cwd: p.cwd,
                logPath: p.logPath,
                loopbackOnly: p.loopbackOnly,
              ),
            );
          }
        } catch (e) {
          failure ??= e;
        }
      }
      if (failure != null && (_stopping > 0 || epoch != _stopEpoch)) {
        // Keep what was shown; the stop ends with a fresh look.
        return;
      }
      found.sort((a, b) {
        final ap = _inProject(a) ? 0 : 1;
        final bp = _inProject(b) ? 0 : 1;
        if (ap != bp) return ap - bp;
        return (a.firstPort ?? 0).compareTo(b.firstPort ?? 0);
      });
      servers = found;
      error = failure;
      scanned = true;
    } catch (e) {
      if (_ok(generation)) error = e;
    } finally {
      if (generation == _generation) scanning = false;
      _notify();
    }
  }

  bool _inProject(DetectedServer s) {
    final cwd = s.cwd;
    if (cwd == null || directory.isEmpty) return false;
    return cwd == directory || cwd.startsWith('$directory/');
  }

  Future<List<int>> _portsInShell(
    ManagedShellGateway gateway,
    String id,
  ) async {
    try {
      final head = await gateway.readManagedShellOutput(
        id,
        cursor: 0,
        limit: 1,
      );
      final start = max(0, head.size - 16384);
      final tail = await gateway.readManagedShellOutput(
        id,
        cursor: start,
        limit: 16384,
      );
      return ListeningPorts.portsInOutput(withoutTerminalCodes(tail.text));
    } catch (_) {
      return const [];
    }
  }

  /// The end of [server]'s output as plain text (at most 64 KB).
  Future<String> readLog(DetectedServer server) async {
    final generation = _generation;
    if (server.source == DetectedSource.shell) {
      final gateway = await resolveGateway();
      if (gateway == null || server.shellId == null) {
        throw StateError('The server is not reachable');
      }
      final head = await gateway.readManagedShellOutput(
        server.shellId!,
        cursor: 0,
        limit: 1,
      );
      final start = max(0, head.size - 65536);
      final tail = await gateway.readManagedShellOutput(
        server.shellId!,
        cursor: start,
        limit: 65536,
      );
      var text = withoutTerminalCodes(tail.text);
      if (text.length > 65536) text = text.substring(text.length - 65536);
      return text;
    }
    final run = runOnPhone;
    final path = server.logPath;
    if (run == null || path == null) {
      throw StateError('This program does not write to a file');
    }
    final result = await run(ListeningPorts.tailScript(path));
    if (generation != _generation && _disposed) return '';
    if (result.exitCode != 0) throw StateError('The log could not be read');
    return withoutTerminalCodes(result.output);
  }

  /// Stops [server]. A shell asks the connected server to end it; a program
  /// is sent TERM (then KILL) only while its command line is unchanged.
  Future<void> stop(DetectedServer server) async {
    if (!isCurrent()) throw StateError('The project changed');
    _stopping++;
    _stopEpoch++;
    try {
      await _stop(server);
    } finally {
      _stopping--;
      _stopEpoch++;
    }
    servers = [
      for (final s in servers)
        if (s.id != server.id) s,
    ];
    _notify();
    _shellPorts.remove(server.shellId);
    await refresh();
  }

  Future<void> _stop(DetectedServer server) async {
    if (server.source == DetectedSource.shell) {
      final gateway = await resolveGateway();
      final id = server.shellId;
      if (gateway == null || id == null) {
        throw StateError('The server is not reachable');
      }
      await gateway.stopManagedShell(id);
      if (await gateway.getManagedShell(id) != null) {
        throw StateError('The server has not confirmed the stop');
      }
    } else {
      final run = runOnPhone;
      if (run == null || server.pid <= 0) {
        throw StateError('This program cannot be stopped from here');
      }
      final result = await run(
        ListeningPorts.stopScript(server.pid, server.command),
      );
      if (result.exitCode != 0) {
        throw StateError('The program did not stop (exit ${result.exitCode})');
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
