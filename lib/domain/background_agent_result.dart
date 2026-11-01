import '../domain/models.dart';

/// Presentation of the canonical OC2 synthetic completion contract. Parsing
/// never creates a message, changes message identity, or trusts arbitrary XML.
class BackgroundAgentResult {
  const BackgroundAgentResult({
    required this.childID,
    required this.agent,
    required this.state,
    required this.description,
    required this.body,
  });

  final String childID;
  final String agent;
  final String state;
  final String description;
  final String body;

  static BackgroundAgentResult? fromPart(Part part) {
    if (part.type != 'v2:notice' || part.toolName != 'synthetic') return null;
    final metadata = part.noticeMetadata;
    if (metadata['source'] != 'subagent') return null;
    final childID = metadata['childID'];
    final agent = metadata['agent'];
    final state = metadata['state'];
    final description = part.filename;
    if (childID == null ||
        !RegExp(r'^ses_[A-Za-z0-9_-]+$').hasMatch(childID) ||
        agent == null ||
        agent.trim().isEmpty ||
        !const {'completed', 'error', 'cancelled'}.contains(state) ||
        description == null) {
      return null;
    }
    // The pinned server interpolates description verbatim. Reconstruct the
    // header with the separate canonical description instead of treating
    // quoted or multiline task names as a generic XML attribute language.
    final header =
        '<subagent sessionID="$childID" state="$state" description="$description">\n';
    const footer = '\n</subagent>';
    if (!part.text.startsWith(header) || !part.text.endsWith(footer)) {
      return null;
    }
    final end = part.text.length - footer.length;
    if (end < header.length) return null;
    return BackgroundAgentResult(
      childID: childID,
      agent: agent,
      state: state!,
      description: description,
      body: part.text.substring(header.length, end),
    );
  }

  /// Navigation is offered only after the session catalog confirms the exact
  /// child-parent relation. Missing catalog data leaves the result readable.
  bool isKnownChild(String? parentID, Map<String, Session> sessions) =>
      parentID != null &&
      parentID != childID &&
      sessions[childID]?.parentID == parentID;
}
