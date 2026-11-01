/// Where the space of the app's own Linux goes, and the cleanups that give
/// it back.
///
/// Pure Dart: the paths of each category, the `du` script and its parser,
/// and the cleanup actions with the rule that keeps them away from
/// projects and credentials. A cleanup may only name a path from
/// [_allowedRoots]; [linuxCleanupPathIsSafe] refuses anything that is, or
/// holds, a protected path. Tests check every action against that rule.
library;

/// A slice of the disk, in the words the page uses.
enum LinuxStorageCategory {
  /// Ubuntu itself: /usr, /etc and the package database.
  base,

  /// Downloaded packages and package lists.
  packages,

  /// Node, npm and download caches.
  tools,

  /// OpenCode, Paseo, Claude Code, AI Team and their saved settings.
  agents,

  /// Your projects.
  projects,

  /// Temporary files and logs.
  temp,
}

/// What each category measures. Disjoint on purpose: the figures add up.
const linuxCategoryPaths = <LinuxStorageCategory, List<String>>{
  LinuxStorageCategory.base: ['/usr', '/etc', '/var/lib/dpkg'],
  LinuxStorageCategory.packages: ['/var/cache/apt', '/var/lib/apt'],
  LinuxStorageCategory.tools: [
    '/opt/node',
    '/root/.npm',
    '/root/.cache',
    '/var/cache/oc-setup',
    '/home/oc/.cache',
  ],
  LinuxStorageCategory.agents: [
    '/opt/opencode',
    '/opt/opencode2',
    '/opt/oc2',
    '/opt/oc-claude',
    '/opt/aiteam',
    '/root/aiteam',
    '/root/.gc',
    '/root/.oc-opencode2',
    '/home/oc/.local',
    '/home/oc/.oc-profiles',
  ],
  LinuxStorageCategory.projects: ['/root/projects'],
  LinuxStorageCategory.temp: ['/tmp', '/var/tmp', '/var/log'],
};

/// The only places a cleanup may touch.
const _allowedRoots = <String>[
  '/var/cache/apt',
  '/root/.npm/_cacache',
  '/root/.npm/_logs',
  '/root/.cache',
  '/var/cache/oc-setup',
  '/home/oc/.cache',
  '/tmp',
  '/var/tmp',
  '/var/log',
  '/home/oc/.local/share/oc-paseo',
];

/// Never touched, nor any folder that holds one of these: projects, every
/// sign-in and credential store, settings, and the saved server data.
const linuxProtectedPaths = <String>[
  '/root/projects',
  '/root/.oc-builtin',
  '/root/.oc-opencode2',
  '/root/.claude',
  '/root/.codex',
  '/root/.config',
  '/root/.ssh',
  '/root/.gc',
  '/root/aiteam',
  '/root/.local',
  '/home/oc/.oc-profiles',
  '/home/oc/.claude',
  '/home/oc/.codex',
  '/home/oc/.config',
  '/home/oc/.ssh',
  '/home/oc/.paseo',
  '/opt',
  '/etc',
  '/usr',
];

final _plainPath = RegExp(r'^/[A-Za-z0-9_./-]+$');

bool _within(String path, String root) =>
    path == root || path.startsWith('$root/');

/// Whether a cleanup may remove things under [path]: an absolute plain path
/// (no spaces, quotes, globs or `..`), under one of the allowed roots, and
/// neither inside a protected path nor holding one.
bool linuxCleanupPathIsSafe(String path) {
  if (!_plainPath.hasMatch(path) || path.contains('..') || path.endsWith('/')) {
    return false;
  }
  if (!_allowedRoots.any((root) => _within(path, root))) return false;
  for (final protected in linuxProtectedPaths) {
    if (_within(path, protected) || _within(protected, path)) return false;
  }
  return true;
}

/// A safe way to give space back.
enum LinuxCleanupId { aptCache, toolCaches, tempFiles, oldAgentVersions }

class LinuxCleanupAction {
  const LinuxCleanupAction._({
    required this.id,
    required this.paths,
    required this.script,
    required this.measureScript,
    this.reads = const [],
  });

  final LinuxCleanupId id;

  /// Every path the script removes things under.
  final List<String> paths;

  /// Paths the script only reads (to decide what to keep).
  final List<String> reads;

  /// Removes. Run alone by the app, never built from text a person typed.
  final String script;

  /// Prints `::du <kb> <path>` for what [script] would remove, so the space
  /// freed is the difference of two readings.
  final String measureScript;

  static const _duLine = r'''
oc_du() { for p in "$@"; do [ -e "$p" ] && printf '::du %s %s\n' "$(du -sk -x "$p" 2>/dev/null | cut -f1)" "$p"; done; }
''';

  static String _measure(List<String> paths) =>
      '$_duLine\noc_du ${paths.join(' ')}\nexit 0\n';

  /// `apt-get clean`: the downloaded .deb files. Package lists stay.
  static final aptCache = LinuxCleanupAction._(
    id: LinuxCleanupId.aptCache,
    paths: const ['/var/cache/apt'],
    script: 'DEBIAN_FRONTEND=noninteractive apt-get clean\nexit 0\n',
    measureScript: _measure(const ['/var/cache/apt']),
  );

  /// npm's download cache and the setup downloads (the setup downloads them
  /// again if it ever needs them).
  static final toolCaches = LinuxCleanupAction._(
    id: LinuxCleanupId.toolCaches,
    paths: const [
      '/root/.npm/_cacache',
      '/root/.npm/_logs',
      '/root/.cache',
      '/var/cache/oc-setup',
      '/home/oc/.cache',
    ],
    script: [
      for (final p in const [
        '/root/.npm/_cacache',
        '/root/.npm/_logs',
        '/root/.cache',
        '/var/cache/oc-setup',
        '/home/oc/.cache',
      ])
        '[ -d $p ] && find $p -mindepth 1 -delete 2>/dev/null',
      'exit 0',
    ].join('\n'),
    measureScript: _measure(const [
      '/root/.npm/_cacache',
      '/root/.npm/_logs',
      '/root/.cache',
      '/var/cache/oc-setup',
      '/home/oc/.cache',
    ]),
  );

  /// Files in /tmp and /var/tmp untouched for a day, and logs older than a
  /// week. A file in use today is never removed.
  static final tempFiles = LinuxCleanupAction._(
    id: LinuxCleanupId.tempFiles,
    paths: const ['/tmp', '/var/tmp', '/var/log'],
    script: [
      'find /tmp /var/tmp -mindepth 1 -mtime +1 -delete 2>/dev/null',
      "find /var/log -type f -mtime +7 -delete 2>/dev/null",
      'exit 0',
    ].join('\n'),
    measureScript:
        '$_duLine\n'
        'for d in /tmp /var/tmp; do [ -d "\$d" ] && printf "::du %s %s\\n" '
        '"\$(find "\$d" -mindepth 1 -mtime +1 -type f -printf "%k\\n" 2>/dev/null | '
        'awk \'{s+=\$1} END {print s+0}\')" "\$d"; done\n'
        'printf "::du %s /var/log\\n" "\$(find /var/log -type f -mtime +7 '
        '-printf "%k\\n" 2>/dev/null | awk \'{s+=\$1} END {print s+0}\')"\n'
        'exit 0\n',
  );

  /// Paseo versions the current link does not point at. Nothing is removed
  /// when the current version cannot be read.
  static const _paseoDir = '/home/oc/.local/share/oc-paseo';
  static const _paseoLink = '/home/oc/.local/bin/paseo';
  static const _oldPaseo = r'''
cur=$(readlink -f /home/oc/.local/bin/paseo 2>/dev/null)
[ -n "$cur" ] && [ -d /home/oc/.local/share/oc-paseo ] || exit 0
case "$cur" in /home/oc/.local/share/oc-paseo/*) ;; *) exit 0 ;; esac
for d in /home/oc/.local/share/oc-paseo/*; do
  [ -d "$d" ] || continue
  case "$cur" in "$d"/*) continue ;; esac
''';
  static final oldAgentVersions = LinuxCleanupAction._(
    id: LinuxCleanupId.oldAgentVersions,
    paths: const [_paseoDir],
    reads: const [_paseoLink],
    script: '$_oldPaseo  rm -rf -- "\$d"\ndone\nexit 0\n',
    measureScript:
        '$_oldPaseo  printf "::du %s %s\\n" "\$(du -sk -x "\$d" 2>/dev/null | '
        'cut -f1)" "\$d"\ndone\nexit 0\n',
  );

  static final all = [aptCache, toolCaches, tempFiles, oldAgentVersions];
}

/// Kilobytes by path from `::du` lines.
Map<String, int> parseLinuxDu(String output) {
  final out = <String, int>{};
  for (final line in output.split('\n')) {
    if (!line.startsWith('::du ')) continue;
    final rest = line.substring(5).trim();
    final space = rest.indexOf(' ');
    if (space < 0) continue;
    final kb = int.tryParse(rest.substring(0, space));
    final path = rest.substring(space + 1).trim();
    if (kb == null || kb < 0 || path.isEmpty) continue;
    out[path] = kb;
  }
  return out;
}

/// Bytes removed between two readings of a cleanup's measure script. Never
/// negative: files written meanwhile are not "freed space".
int linuxFreedBytes(Map<String, int> before, Map<String, int> after) {
  var kb = 0;
  for (final entry in before.entries) {
    final left = after[entry.key] ?? 0;
    if (entry.value > left) kb += entry.value - left;
  }
  return kb * 1024;
}

/// The measure script for every category path.
final String linuxStorageScript = () {
  final paths = [for (final list in linuxCategoryPaths.values) ...list];
  return '${LinuxCleanupAction._duLine}\noc_du ${paths.join(' ')}\nexit 0\n';
}();

/// How a storage reading adds up.
class LinuxStorageReport {
  const LinuxStorageReport(this.bytes);

  /// Bytes by category. A category whose paths were not there is 0.
  final Map<LinuxStorageCategory, int> bytes;

  int get total => bytes.values.fold(0, (a, b) => a + b);

  int of(LinuxStorageCategory category) => bytes[category] ?? 0;

  factory LinuxStorageReport.parse(String output) {
    final du = parseLinuxDu(output);
    return LinuxStorageReport({
      for (final entry in linuxCategoryPaths.entries)
        entry.key:
            entry.value.fold<int>(0, (sum, path) => sum + (du[path] ?? 0)) *
            1024,
    });
  }
}
