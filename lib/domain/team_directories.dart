/// Which folders belong to the AI Team rather than to the person.
///
/// The team's agents are `opencode acp` processes that talk to the same
/// OpenCode server as the app, so every patrol, merge and polecat run is an
/// ordinary OpenCode session there, in a folder the team made for itself.
/// The server lists them with the person's own conversations; the app does
/// not. The AI Team screen is where the team's work is shown; the Work tab,
/// the project lists, All conversations and the other-projects badges are the
/// person's.
///
/// The rule, in one place: a folder is the team's when it is
/// - the team's home, [aiTeamHome], or anything inside it (the in-app team,
///   and the Termux proot spike before it, keep their city, the agents' work
///   folders and the stand-in `origin` repositories there); or
/// - inside a Gas City state folder, `.gc` (an agent's work folder is
///   `<city>/.gc/worktrees/<rig>/<agent>`, wherever the city lives: a
///   Termux-native city under `~/.oc/aiteam`, a PC city); or
/// - inside the Termux-native team home, `.oc/aiteam`.
///
/// The person's project that the team works on (a rig such as
/// `/root/projects/my-app`) is not the team's: it matches none of these.
library;

import 'server_gateway.dart' show GlobalSessionResult;

/// The in-app AI Team's home in the Linux container (`BuiltinTeam.home`).
/// The Termux proot spike used the same path.
const aiTeamHome = '/root/aiteam';

/// True when [directory] is one of the AI Team's own folders (see the
/// library comment for the rule). Null or empty is not.
bool isAiTeamDirectory(String? directory) {
  final segments = _segments(directory);
  if (segments == null || segments.isEmpty) return false;
  // The team's home and below.
  final home = _segments(aiTeamHome)!;
  if (segments.length >= home.length &&
      Iterable.generate(home.length).every((i) => segments[i] == home[i])) {
    return true;
  }
  for (var i = 0; i < segments.length; i++) {
    // Gas City's own state and agent work folders.
    if (segments[i] == '.gc') return true;
    // The Termux-native team home, ~/.oc/aiteam.
    if (segments[i] == '.oc' &&
        i + 1 < segments.length &&
        segments[i + 1] == 'aiteam') {
      return true;
    }
  }
  return false;
}

/// True when an all-projects search result is one of the team's sessions.
/// Judged by the conversation's own folder, which is where it runs; the
/// project's folder only when the server names no other, so a person's
/// conversation in the team's rig is never taken for the team's.
bool isAiTeamConversation(GlobalSessionResult result) =>
    isAiTeamDirectory(result.session.directory ?? result.projectDirectory);

/// Path segments with `.` dropped and `..` applied, so `/root/./aiteam/`
/// and `/root/projects/../aiteam` read as the team's home. Null when there
/// is no path.
List<String>? _segments(String? directory) {
  final value = directory?.trim().replaceAll('\\', '/');
  if (value == null || value.isEmpty) return null;
  final out = <String>[];
  for (final part in value.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(part);
  }
  return out;
}
