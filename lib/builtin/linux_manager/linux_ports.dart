/// Which ports have something listening inside the app's own Linux.
///
/// Android hides `/proc/net/tcp` from apps on recent versions, so the script
/// does not rely on it. It collects candidate ports (from `/proc/net/tcp`
/// when it can be read, from the numbers running commands, their `PORT`
/// variables and their logs name, and the usual dev-server ports; the
/// detection is shared with Development services, `listening_ports.dart`)
/// and then tries to connect to each one on the phone's own loopback, the
/// same way the dev preview will. A port is reported only when that
/// connection succeeded, so a listing is a fact, not a guess. What owns a
/// port is the process that named it; when none does, the owner is unknown
/// and is said so.
library;

import '../../domain/listening_ports.dart'
    show commonDevPorts, loopbackProbeShell, namedPortsShell, portsNamedIn;
import 'linux_processes.dart';

export '../../domain/listening_ports.dart' show portsNamedIn;

/// One port with something listening.
class LinuxPort {
  const LinuxPort({required this.port, this.owner, this.allInterfaces});

  final int port;

  /// The process whose command names this port, when there is one.
  final LinuxProcess? owner;

  /// True when it listens on every address, false when only on the phone
  /// itself, null when the kernel's table could not be read.
  final bool? allInterfaces;

  /// What the page calls the owner, or null when nothing names it.
  LinuxProcessKind? get kind {
    if (port == 4097) return LinuxProcessKind.openCodeServer;
    return owner?.kind;
  }

  /// Dev servers and anything unknown can be previewed. The OpenCode server
  /// and Paseo speak their own protocol, not web pages.
  bool get canPreview => switch (kind) {
    LinuxProcessKind.openCodeServer || LinuxProcessKind.paseo => false,
    _ => true,
  };
}

/// Ports the script always tries in addition to the ones it finds.
const linuxUsualPorts = <int>[...commonDevPorts, 4097];

/// The probe script. [candidates] are extra ports to try (from the commands
/// of [LinuxProcessScan]); the usual ones and those the socket-holding
/// processes name are added here.
String linuxPortScript(Iterable<int> candidates) {
  final ports = <int>{
    ...linuxUsualPorts,
    for (final p in candidates)
      if (p >= 1024 && p <= 65535) p,
  }.toList()..sort();
  return '''# oc-linux-ports
for f in /proc/net/tcp /proc/net/tcp6; do
  [ -r "\$f" ] || continue
  while read -r oc_sl oc_local oc_rem oc_st oc_rest; do
    [ "\$oc_st" = 0A ] || continue
    printf '::listen %s %s\\n' "\${oc_local%%:*}" "\${oc_local##*:}"
  done < "\$f"
done 2>/dev/null
oc_named=
for p in \$(ls -ld /proc/[0-9]*/fd/* 2>/dev/null | grep -F 'socket:[' | sed -n 's#^.* /proc/\\([0-9]*\\)/fd/.*#\\1#p' | sort -un); do
$namedPortsShell
done
${loopbackProbeShell(ports, marker: '::open ')}
exit 0
''';
}

/// The ports found by [linuxPortScript], matched to [scan]'s processes.
List<LinuxPort> parseLinuxPorts(String output, LinuxProcessScan scan) {
  final open = <int>{};
  final wide = <int, bool>{};
  final named = <int, Set<int>>{}; // port -> pids that name it
  for (final line in output.split('\n')) {
    if (line.startsWith('::n ')) {
      final parts = line.substring(4).trim().split(' ');
      if (parts.length != 2) continue;
      final pid = int.tryParse(parts[0]);
      final port = int.tryParse(parts[1]);
      if (pid != null && port != null) {
        named.putIfAbsent(port, () => {}).add(pid);
      }
    } else if (line.startsWith('::open ')) {
      final p = int.tryParse(line.substring(7).trim());
      if (p != null && p >= 1 && p <= 65535) open.add(p);
    } else if (line.startsWith('::listen ')) {
      final parts = line.substring(9).trim().split(' ');
      if (parts.length != 2) continue;
      final p = int.tryParse(parts[1], radix: 16);
      if (p == null) continue;
      // 0.0.0.0 / :: are all zeros; 127.0.0.1 is 0100007F.
      final any = RegExp(r'^0+$').hasMatch(parts[0]);
      wide[p] = (wide[p] ?? false) || any;
    }
  }
  // A listener the kernel table shows but the probe could not reach is not
  // offered: it is not reachable the way the preview connects.
  final ports = open.toList()..sort();
  return [
    for (final port in ports)
      LinuxPort(
        port: port,
        owner: _ownerOf(port, scan, named[port] ?? const {}),
        allInterfaces: wide.isEmpty ? null : (wide[port] ?? false),
      ),
  ];
}

LinuxProcess? _ownerOf(int port, LinuxProcessScan scan, Set<int> namers) {
  LinuxProcess? best;
  for (final p in scan.processes) {
    if (!namers.contains(p.pid) && !portsNamedIn(p.cmd).contains(port)) {
      continue;
    }
    // The newest process naming it (the child that does the listening).
    if (best == null || p.startTicks > best.startTicks) best = p;
  }
  return best;
}
