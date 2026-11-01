import 'setup_assistant.dart';

/// A read-only setup suggestion: what a person could change on the server,
/// derived from a redacted [SetupSnapshot]. It carries no edit, no action
/// and no copy; the UI words each [kind] (review only, 2026-09-28: nothing
/// here applies, proposes to the server or undoes a change).
enum SetupSuggestionKind {
  /// A tool server is waiting for its sign-in (needs_auth or
  /// needs_client_registration).
  signInTool,

  /// A tool server failed to start or connect.
  fixTool,

  /// The effective configuration names no model, so new conversations use
  /// the server's default choice. Only for a merged effective view.
  chooseModel,

  /// No tool servers are connected or defined.
  addTools,
}

class SetupSuggestion {
  const SetupSuggestion(this.kind, {this.subject});

  final SetupSuggestionKind kind;

  /// The (already redacted) tool server name the suggestion is about.
  final String? subject;

  @override
  bool operator ==(Object other) =>
      other is SetupSuggestion &&
      other.kind == kind &&
      other.subject == subject;

  @override
  int get hashCode => Object.hash(kind, subject);
}

/// The urgency order the page lists tool servers in: what needs the person
/// first, what is fine last. Unknown statuses sort with waiting ones.
int setupToolUrgency(String status) => switch (status) {
  'needs_auth' || 'needs_client_registration' => 0,
  'failed' => 1,
  'pending' || 'unknown' => 2,
  'disabled' => 3,
  _ => 4,
};

/// Whether [config] is OpenCode 2's ordered source list, which the app shows
/// as it is and never merges into an invented effective view.
bool setupConfigIsLayered(Map<String, Object?> config) =>
    config.containsKey('sources');

/// Suggestions, most urgent first. Only states that data proves: nothing
/// is suggested about a layered source list's effective values.
List<SetupSuggestion> setupSuggestions(SetupSnapshot snapshot) {
  final servers = [...snapshot.servers]
    ..sort(
      (a, b) =>
          setupToolUrgency(a.status).compareTo(setupToolUrgency(b.status)),
    );
  final config = snapshot.config;
  final definedTools = config['mcp'];
  return [
    for (final server in servers)
      if (setupToolUrgency(server.status) == 0)
        SetupSuggestion(SetupSuggestionKind.signInTool, subject: server.name)
      else if (server.status == 'failed')
        SetupSuggestion(SetupSuggestionKind.fixTool, subject: server.name),
    if (!setupConfigIsLayered(config) && !config.containsKey('model'))
      const SetupSuggestion(SetupSuggestionKind.chooseModel),
    if (servers.isEmpty && (definedTools is! Map || definedTools.isEmpty))
      const SetupSuggestion(SetupSuggestionKind.addTools),
  ];
}
