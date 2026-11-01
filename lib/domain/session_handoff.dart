/// Session handoff between the phone and a computer (backlog F4).
///
/// Two pure builders live here so they can be unit-tested without Flutter:
///
/// * [SessionResumeCommand] renders the terminal command that resumes a
///   session on the computer that hosts the server. OpenCode sessions are
///   location-scoped, so every command changes into the session's project
///   directory first. The CLI flags were verified against the installed
///   binaries (see docs/qa/f4-session-handoff/README.md for the exact
///   `--help` output):
///
///   - OpenCode 2 (`opencode2 v0.0.0-beta-19086` and `beta-19242`, identical):
///     `opencode2 <subcommand> [flags] [<directory>]` with
///     `--session, -s string  Session ID to continue`.
///
/// * [SessionLink] encodes and decodes the `opencode-mobile://session` deep
///   link that opens the same session on another phone. It carries route
///   identifiers only: a saved-server (profile) id and a session id. Never
///   content, never credentials, never a server address.
library;

/// Which command-line product resumes the session. Mirrors the server's
/// product generation; a server that has no CLI counterpart (for example a
/// Codex backend) is not offered a command at all.
enum SessionResumeCli { openCode2 }

/// Why a resume command could not be built. Each reason maps to honest copy
/// in the sheet rather than a guessed command.
enum SessionResumeUnavailable {
  /// The server did not report a project directory for this session, so the
  /// command cannot `cd` anywhere meaningful.
  missingDirectory,

  /// The directory contains control characters or is otherwise unsafe to
  /// place in a shell command.
  unsafeDirectory,

  /// The session id is not a plain identifier.
  invalidSessionID,

  /// The session lives in a managed workspace (OpenCode 2 `wrk_…`). Its
  /// directory belongs to the workspace host, not necessarily to the
  /// computer the user sits at, so a plain `cd` would mislead.
  managedWorkspace,
}

/// The resume command for one session, or the reason there is none.
class SessionResumeCommand {
  const SessionResumeCommand._(this.command, this.unavailable, this.cli);

  /// The full shell command, POSIX-quoted, or null when [unavailable] is set.
  final String? command;
  final SessionResumeUnavailable? unavailable;
  final SessionResumeCli cli;

  bool get available => command != null;

  /// The binary name the user will type, for copy that names the product.
  String get binary => binaryFor(cli);

  static String binaryFor(SessionResumeCli cli) => switch (cli) {
    SessionResumeCli.openCode2 => 'opencode2',
  };

  /// Builds `cd '<directory>' && <binary> --session '<id>'`.
  ///
  /// The directory is quoted as a single POSIX word so spaces, `$`, backticks
  /// and single quotes survive. The session id is validated to a plain
  /// identifier that cannot start with `-`, so it can never be read as a
  /// flag by either CLI. [workspaceID] is the OpenCode 2 managed-workspace
  /// id; a non-empty value makes the command unavailable rather than wrong.
  /// A git worktree session is an ordinary directory on disk and resumes
  /// by changing into that worktree.
  factory SessionResumeCommand.build({
    required SessionResumeCli cli,
    required String sessionID,
    required String? directory,
    String? workspaceID,
  }) {
    if (workspaceID != null && workspaceID.isNotEmpty) {
      return SessionResumeCommand._(
        null,
        SessionResumeUnavailable.managedWorkspace,
        cli,
      );
    }
    if (!isSafeIdentifier(sessionID)) {
      return SessionResumeCommand._(
        null,
        SessionResumeUnavailable.invalidSessionID,
        cli,
      );
    }
    final dir = directory?.trim() ?? '';
    if (dir.isEmpty) {
      return SessionResumeCommand._(
        null,
        SessionResumeUnavailable.missingDirectory,
        cli,
      );
    }
    if (_hasControl(dir)) {
      return SessionResumeCommand._(
        null,
        SessionResumeUnavailable.unsafeDirectory,
        cli,
      );
    }
    final command =
        'cd ${shellQuote(dir)} && ${binaryFor(cli)} --session ${shellQuote(sessionID)}';
    return SessionResumeCommand._(command, null, cli);
  }

  /// Single-quotes [value] for a POSIX shell. A literal `'` becomes `'\''`.
  static String shellQuote(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";

  /// Plain identifier: ASCII letters, digits, `_`, `-`, `.`; must start with
  /// a letter or digit so it can never be parsed as a flag; bounded length.
  static bool isSafeIdentifier(String value) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(value);

  static bool _hasControl(String value) =>
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
}

/// The phone-to-phone deep link. Route identifiers only.
///
/// Shape: `opencode-mobile://session?profile=<profileID>&session=<sessionID>`.
/// Both ids are validated with [SessionResumeCommand.isSafeIdentifier]; any
/// other scheme, host, missing or malformed parameter makes [parse] return
/// null so the receiver ignores the link safely.
class SessionLink {
  const SessionLink({required this.profileID, required this.sessionID});

  static const scheme = 'opencode-mobile';
  static const host = 'session';
  static const profileParameter = 'profile';
  static const sessionParameter = 'session';

  /// The saved-server id on the *sending* phone. Profile ids are minted per
  /// phone (a timestamp at save time) and never derived from the server, so
  /// the receiver resolves it only when it holds a saved entry with the same
  /// id; otherwise it shows its "server not saved" state. Carrying anything
  /// that identifies the server itself would need a privacy review first.
  final String profileID;
  final String sessionID;

  /// Builds the link, or null when either id is not a safe identifier.
  static SessionLink? tryCreate({
    required String? profileID,
    required String? sessionID,
  }) {
    if (profileID == null ||
        sessionID == null ||
        !SessionResumeCommand.isSafeIdentifier(profileID) ||
        !SessionResumeCommand.isSafeIdentifier(sessionID)) {
      return null;
    }
    return SessionLink(profileID: profileID, sessionID: sessionID);
  }

  Uri get uri => Uri(
    scheme: scheme,
    host: host,
    queryParameters: {profileParameter: profileID, sessionParameter: sessionID},
  );

  @override
  String toString() => uri.toString();

  /// Parses a received link. Returns null for anything that is not exactly
  /// this link shape: wrong scheme or host, a path, a fragment, missing or
  /// repeated parameters, unsafe ids, or text that is not a URI at all.
  static SessionLink? parse(Object? raw) {
    if (raw is! String) return null;
    final text = raw.trim();
    if (text.isEmpty || text.length > 1024) return null;
    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    if (uri.scheme.toLowerCase() != scheme) return null;
    if (uri.host.toLowerCase() != host) return null;
    if (uri.userInfo.isNotEmpty || uri.hasPort || uri.hasFragment) return null;
    if (uri.path.isNotEmpty && uri.path != '/') return null;
    final Map<String, List<String>> query;
    try {
      query = uri.queryParametersAll;
    } on FormatException {
      return null;
    }
    final profile = query[profileParameter];
    final session = query[sessionParameter];
    if (profile == null ||
        session == null ||
        profile.length != 1 ||
        session.length != 1) {
      return null;
    }
    return tryCreate(profileID: profile.single, sessionID: session.single);
  }

  @override
  bool operator ==(Object other) =>
      other is SessionLink &&
      other.profileID == profileID &&
      other.sessionID == sessionID;

  @override
  int get hashCode => Object.hash(profileID, sessionID);
}
