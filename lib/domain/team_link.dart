import 'session_handoff.dart';

/// What an AI Team deep link names: a gate (the Gate sheet) or a run (the
/// run screen, for a completed run).
enum TeamLinkKind {
  gate('gate'),
  run('run');

  const TeamLinkKind(this.segment);

  /// The first path segment of the link.
  final String segment;

  static TeamLinkKind? fromSegment(String value) {
    for (final kind in values) {
      if (kind.segment == value) return kind;
    }
    return null;
  }
}

/// The AI Team deep link (TEAM-203, 02-ux §6): what a notification tap
/// opens, and what another app may hand over. Route identifiers only.
///
/// Shapes:
///
/// * `opencode-mobile://team/gate/<profileId>/<gateId>` — the Gate sheet
///   of that gate on that saved server.
/// * `opencode-mobile://team/run/<profileId>/<runId>` — the run screen.
///
/// Both ids are validated with [isSafeId]; a gate id may carry the `:`
/// the mapper uses (`bead:…`, `run:…`, `review:…`). Any other scheme,
/// host, path shape, a query or a fragment makes [parse] return null so
/// the receiver ignores the link safely. A link never carries a title, a
/// prompt or anything the host said: those are read from the snapshot
/// once the sheet opens.
class TeamLink {
  const TeamLink({
    required this.kind,
    required this.profileId,
    required this.id,
  });

  static const scheme = SessionLink.scheme;
  static const host = 'team';

  final TeamLinkKind kind;

  /// The saved-server id on this phone (minted locally, never derived
  /// from the server), as [SessionLink.profileID].
  final String profileId;

  /// The gate id or run id.
  final String id;

  /// A route id: a safe identifier in the [SessionLink] sense, plus `:`
  /// between segments (`bead:w-1`).
  static bool isSafeId(String value) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value) &&
      !value.endsWith(':');

  /// Builds a link, or null when either id is not safe.
  static TeamLink? tryCreate({
    required TeamLinkKind kind,
    required String? profileId,
    required String? id,
  }) {
    if (profileId == null ||
        id == null ||
        !SessionResumeCommand.isSafeIdentifier(profileId) ||
        !isSafeId(id)) {
      return null;
    }
    return TeamLink(kind: kind, profileId: profileId, id: id);
  }

  Uri get uri => Uri(
    scheme: scheme,
    host: host,
    pathSegments: [kind.segment, profileId, id],
  );

  @override
  String toString() => uri.toString();

  /// Parses a received link; null for anything that is not exactly one of
  /// the two shapes above.
  static TeamLink? parse(Object? raw) {
    if (raw is! String) return null;
    final text = raw.trim();
    if (text.isEmpty || text.length > 1024) return null;
    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    if (uri.scheme.toLowerCase() != scheme) return null;
    if (uri.host.toLowerCase() != host) return null;
    if (uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasFragment ||
        uri.hasQuery) {
      return null;
    }
    final List<String> segments;
    try {
      segments = uri.pathSegments;
    } on FormatException {
      return null;
    }
    if (segments.length != 3) return null;
    final kind = TeamLinkKind.fromSegment(segments[0]);
    if (kind == null) return null;
    return tryCreate(kind: kind, profileId: segments[1], id: segments[2]);
  }

  @override
  bool operator ==(Object other) =>
      other is TeamLink &&
      other.kind == kind &&
      other.profileId == profileId &&
      other.id == id;

  @override
  int get hashCode => Object.hash(kind, profileId, id);
}
