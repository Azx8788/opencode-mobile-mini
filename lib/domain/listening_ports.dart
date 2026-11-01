/// Dev servers that are running on the in-app Linux whoever started them:
/// the script that lists them and the parser for what it prints. Pure Dart,
/// no widgets, so the Development services screen, the dev preview, the
/// conversation menu and Linux › Ports share one reading.
///
/// Android 10+ denies apps `/proc/net/tcp{,6}` (SELinux), so the socket
/// tables are a bonus, not the source (N1-4, build 2400: a python
/// http.server on port 8765 was never listed). The script finds the
/// processes that hold a socket (`/proc/<pid>/fd/*`, readable for the app's
/// own user), collects the ports they name: numbers on their command line,
/// `PORT=`-style variables (only the number is printed, never the rest of
/// the environment) and ports their log file mentions. It then tries each
/// of those, plus [commonDevPorts], on loopback; a port is listed only when
/// that connection worked. The probe owner is the process that named it.
///
/// The script runs under `/bin/sh`, which is dash on Ubuntu: it is POSIX,
/// and only the loopback probe runs in bash (for `/dev/tcp`).
library;

import 'dev_preview.dart';

/// One listening TCP socket from a `/proc/net/tcp` table.
class ListeningSocket {
  const ListeningSocket({
    required this.port,
    required this.inode,
    required this.loopbackOnly,
  });

  final int port;
  final int inode;

  /// Bound to 127.x or ::1 only, so another machine cannot reach it.
  final bool loopbackOnly;
}

/// A program on this machine that listens on one or more ports.
class LocalServerProcess {
  const LocalServerProcess({
    required this.pid,
    required this.command,
    required this.ports,
    this.cwd,
    this.logPath,
    this.loopbackOnly = true,
  });

  /// Zero when only a connection probe found the port: no process known.
  final int pid;
  final String command;
  final List<int> ports;
  final String? cwd;

  /// The regular file this program's standard output is written to, when it
  /// is one (a server started by `cmd > file`). Null for a terminal or pipe.
  final String? logPath;
  final bool loopbackOnly;

  bool get hasProcess => pid > 0;
}

/// The usual dev-server ports, always tried: framework defaults (Vite,
/// Next, Astro, Storybook, Hugo, Flask, Django, Jupyter, live-server…).
const List<int> commonDevPorts = [
  1313,
  3000,
  3001,
  3333,
  4000,
  4173,
  4200,
  4321,
  5000,
  5001,
  5173,
  5174,
  5500,
  6006,
  7000,
  8000,
  8001,
  8008,
  8080,
  8081,
  8088,
  8888,
  9000,
  9090,
];

final _portInCommand = RegExp(
  r'(?:--port[= ]|-p[= ]?|PORT=|:)(\d{2,5})(?!\d)|(?:^| )(\d{4,5})(?= |$)',
);

/// Port numbers a command line names: `--port 5173`, `-p 3000`, `PORT=8081`,
/// `host:9229`, and a bare number as its own word (`python3 -m http.server
/// 8765`). Only 1024-65535: Android apps cannot listen below.
Set<int> portsNamedIn(String cmd) => {
  for (final m in _portInCommand.allMatches(cmd))
    if (int.parse(m.group(1) ?? m.group(2)!) case final p
        when p >= 1024 && p <= 65535)
      p,
};

/// POSIX sh that prints `::n <pid> <port>` for each port process `$p` names
/// (command line, `*PORT=` variables, the end of a log file on its standard
/// output or error) and adds them to `$oc_named`. Only numbers leave it.
const String namedPortsShell = r"""
oc_n=$( {
  tr '\000' '\n' <"/proc/$p/cmdline" 2>/dev/null | tr -c '0-9\n' '\n'
  tr '\000' '\n' <"/proc/$p/environ" 2>/dev/null | sed -n 's/^[A-Z_]*PORT=\([0-9][0-9]*\)$/\1/p'
  for oc_f in 1 2; do
    oc_t=$(readlink "/proc/$p/fd/$oc_f" 2>/dev/null)
    case "$oc_t" in
      /dev/*|/proc/*|/sys/*|*' (deleted)') ;;
      /*) [ -f "$oc_t" ] && tail -c 8192 "$oc_t" 2>/dev/null | grep -oE '(:|[Pp]ort )[0-9]+' | tr -c '0-9\n' '\n' ;;
    esac
  done
} | grep -E '^[0-9]{4,5}$' | sort -un | head -n 16)
for oc_q in $oc_n; do
  [ "$oc_q" -ge 1024 ] && [ "$oc_q" -le 65535 ] || continue
  printf '::n %s %s\n' "$p" "$oc_q"
  oc_named="$oc_named $oc_q"
done
""";

/// Bash, from sh: prints `<marker><port>` for each of [fixed] and
/// `$oc_named` that accepts a connection on loopback. No fork per port.
String loopbackProbeShell(Iterable<int> fixed, {String marker = ''}) {
  final ports = {
    for (final p in fixed)
      if (p >= 1 && p <= 65535) p,
  }.toList()..sort();
  return "bash -c 'for q in \$(printf \"%s\\n\" \"\$@\" | sort -un); do "
      ": 2>/dev/null 3<>/dev/tcp/127.0.0.1/\$q && echo \"$marker\$q\"; done' "
      'oc-ports ${ports.join(' ')} \$oc_named 2>/dev/null';
}

/// The one place that knows the script and how to read its answer.
abstract final class ListeningPorts {
  /// The in-app OpenCode server's own port: never listed as a dev server.
  static const int ownServerPort = 4097;

  /// Program names that are the machine's own plumbing, not dev servers.
  static const Set<String> _plumbing = {
    'sshd',
    'opencode',
    'paseo',
    'proot',
    'dropbear',
  };

  /// The script for the in-app Linux (POSIX sh). Prints sections the
  /// parser reads; every read is allowed to fail silently. [socketTables]
  /// exists for tests that hide them, as Android does.
  static String script({
    List<int> probe = commonDevPorts,
    List<String> socketTables = const ['/proc/net/tcp', '/proc/net/tcp6'],
  }) {
    final t4 = socketTables.isEmpty ? '/nonexistent' : socketTables.first;
    final t6 = socketTables.length < 2 ? '/nonexistent' : socketTables[1];
    return '''
echo '#T4'
grep -E '^ *[0-9]+: [0-9A-Fa-f]+:[0-9A-Fa-f]+ [0-9A-Fa-f:]+ 0A ' $t4 2>/dev/null
echo '#T6'
grep -E '^ *[0-9]+: [0-9A-Fa-f]+:[0-9A-Fa-f]+ [0-9A-Fa-f:]+ 0A ' $t6 2>/dev/null
echo '#S'
socks=\$(ls -ld /proc/[0-9]*/fd/* 2>/dev/null | grep -F 'socket:[')
printf '%s\\n' "\$socks"
echo '#C'
oc_named=
for p in \$(printf '%s\\n' "\$socks" | sed -n 's#^.* /proc/\\([0-9]*\\)/fd/.*#\\1#p' | sort -un); do
  c=\$(tr '\\000\\t\\n' '   ' </proc/\$p/cmdline 2>/dev/null | cut -c1-400)
  [ -n "\$c" ] || continue
  printf '%s\\t%s\\t%s\\t%s\\n' "\$p" "\$c" "\$(readlink /proc/\$p/cwd 2>/dev/null)" "\$(readlink /proc/\$p/fd/1 2>/dev/null)"
$namedPortsShell
done
echo '#P'
${loopbackProbeShell(probe)}
true
''';
  }

  /// A listening socket row of `/proc/net/tcp` or `tcp6`, or null.
  static ListeningSocket? parseSocketLine(String line) {
    final f = line.trim().split(RegExp(r'\s+'));
    if (f.length < 10 || f[3] != '0A') return null;
    final local = f[1];
    final colon = local.lastIndexOf(':');
    if (colon < 0) return null;
    final address = local.substring(0, colon);
    final port = int.tryParse(local.substring(colon + 1), radix: 16);
    final inode = int.tryParse(f[9]);
    if (port == null || port < 1 || port > 65535 || inode == null) {
      return null;
    }
    return ListeningSocket(
      port: port,
      inode: inode,
      loopbackOnly: _loopback(address.toUpperCase()),
    );
  }

  static bool _loopback(String hex) {
    if (hex.length == 8) return hex.endsWith('7F');
    if (hex.length == 32) {
      if (hex == '00000000000000000000000001000000') return true;
      // ::ffff:127.x.x.x
      return hex.startsWith('0000000000000000FFFF0000') && hex.endsWith('7F');
    }
    return false;
  }

  /// Reads what [script] printed. One entry per process, its ports sorted;
  /// ports found only by the probe come last with pid 0. The in-app server's
  /// port and system plumbing are left out.
  static List<LocalServerProcess> parse(String output) {
    var section = '';
    final sockets = <ListeningSocket>[];
    final owners = <int, Set<int>>{}; // inode -> pids
    final info = <int, List<String>>{}; // pid -> [cmd, cwd, out]
    final probed = <int>{};
    final named = <int, Set<int>>{}; // port -> pids that name it
    final inodePattern = RegExp(r'/proc/(\d+)/fd/\d+ -> socket:\[(\d+)\]');
    for (final raw in output.split('\n')) {
      final line = raw.trimRight();
      if (line.startsWith('#') && line.length <= 3) {
        section = line;
        continue;
      }
      if (line.isEmpty) continue;
      if (line.startsWith('::n ')) {
        final parts = line.substring(4).trim().split(' ');
        final pid = parts.length == 2 ? int.tryParse(parts[0]) : null;
        final port = parts.length == 2 ? int.tryParse(parts[1]) : null;
        if (pid != null && port != null && port > 0 && port <= 65535) {
          named.putIfAbsent(port, () => {}).add(pid);
        }
        continue;
      }
      switch (section) {
        case '#T4' || '#T6':
          final socket = parseSocketLine(line);
          if (socket != null) sockets.add(socket);
        case '#S':
          final match = inodePattern.firstMatch(line);
          if (match != null) {
            final pid = int.parse(match.group(1)!);
            final inode = int.parse(match.group(2)!);
            owners.putIfAbsent(inode, () => {}).add(pid);
          }
        case '#C':
          final parts = line.split('\t');
          final pid = int.tryParse(parts.first);
          if (pid != null && parts.length >= 2) {
            info[pid] = [
              parts[1].trim(),
              parts.length > 2 ? parts[2] : '',
              parts.length > 3 ? parts[3] : '',
            ];
          }
        case '#P':
          final port = int.tryParse(line);
          if (port != null && port > 0 && port <= 65535) probed.add(port);
      }
    }
    final byPid = <int, Set<int>>{};
    final reachable = <int, bool>{};
    final known = <int>{};
    for (final socket in sockets) {
      known.add(socket.port);
      for (final pid in owners[socket.inode] ?? const <int>{}) {
        byPid.putIfAbsent(pid, () => {}).add(socket.port);
        reachable[pid] = (reachable[pid] ?? false) || !socket.loopbackOnly;
      }
    }
    // Without the tables (Android 10+), a port that answered belongs to the
    // process that named it: the newest one, the child that listens, and
    // never a client such as curl.
    for (final port in probed) {
      if (known.contains(port) || port == ownServerPort) continue;
      final owner = _namer(named[port], info);
      if (owner == null) continue;
      known.add(port);
      byPid.putIfAbsent(owner, () => {}).add(port);
    }
    final out = <LocalServerProcess>[];
    final claimed = <int>{};
    final pids = byPid.keys.toList()..sort();
    for (final pid in pids) {
      final details = info[pid];
      if (details == null) continue;
      final ports = (byPid[pid]!.toList()..sort())
          .where((p) => p != ownServerPort)
          .toList();
      if (ports.isEmpty || _isPlumbing(details[0])) continue;
      claimed.addAll(ports);
      out.add(
        LocalServerProcess(
          pid: pid,
          command: details[0],
          ports: ports,
          cwd: details[1].isEmpty ? null : details[1],
          logPath: regularFileOrNull(details[2]),
          loopbackOnly: !(reachable[pid] ?? false),
        ),
      );
    }
    final rest = probed.where(
      (p) => p != ownServerPort && !claimed.contains(p) && !known.contains(p),
    );
    for (final port in rest.toList()..sort()) {
      out.add(LocalServerProcess(pid: 0, command: '', ports: [port]));
    }
    return out;
  }

  static const Set<String> _clients = {
    'curl',
    'wget',
    'ssh',
    'scp',
    'nc',
    'ncat',
    'telnet',
    'git',
  };

  static int? _namer(Set<int>? pids, Map<int, List<String>> info) {
    if (pids == null) return null;
    int? best;
    for (final pid in pids) {
      final details = info[pid];
      if (details == null) continue;
      final first = details[0].trim().split(' ').first.split('/').last;
      if (_clients.contains(first)) continue;
      if (best == null || pid > best) best = pid;
    }
    return best;
  }

  static bool _isPlumbing(String command) {
    final first = command.trim().split(' ').first.split('/').last;
    return _plumbing.contains(first);
  }

  /// [target] when it is an absolute path to something that can be a plain
  /// log file; null for terminals, pipes, sockets and system paths.
  static String? regularFileOrNull(String? target) {
    if (target == null) return null;
    final t = target.trim();
    if (!t.startsWith('/') || t.length > 1024 || t.contains('\n')) return null;
    for (final bad in ['/dev/', '/proc/', '/sys/']) {
      if (t.startsWith(bad)) return null;
    }
    if (t.endsWith(' (deleted)')) return null;
    return t;
  }

  static String _quote(String value) => "'${value.replaceAll("'", r"'\''")}'";

  /// Reads the end of [path] (at most 64 KB). Refuses anything that is not
  /// a plain readable file.
  static String tailScript(String path) {
    final safe = regularFileOrNull(path);
    if (safe == null) return 'exit 2';
    return '[ -f ${_quote(safe)} ] || exit 3; tail -c 65536 -- ${_quote(safe)}';
  }

  /// Signals [pid] only while its command line still starts with what the
  /// person saw, so a reused pid is never hit. TERM, then KILL if it holds
  /// on after two seconds.
  static String stopScript(int pid, String expectedCommand) {
    if (pid <= 1) return 'exit 2';
    final want = expectedCommand.length > 200
        ? expectedCommand.substring(0, 200)
        : expectedCommand;
    return '''
now=\$(tr '\\0\\t\\n' '   ' </proc/$pid/cmdline 2>/dev/null)
[ -n "\$now" ] || exit 0
case "\$now" in ${_quote(want)}*) ;; *) exit 4;; esac
kill -TERM $pid 2>/dev/null
for i in 1 2 3 4; do [ -d /proc/$pid ] || exit 0; sleep 0.5; done
kill -KILL $pid 2>/dev/null
sleep 0.3
[ -d /proc/$pid ] && exit 5
exit 0
''';
  }

  /// The ports mentioned as local links in [text] (a server's own output).
  static List<int> portsInOutput(String text) {
    final seen = <int>{};
    for (final link in DevPreviewLink.scan(text)) {
      seen.add(link.port);
    }
    return seen.toList()..sort();
  }
}
