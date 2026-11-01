import 'dart:convert';

import '../ui/kit/kit_redact.dart';
import 'setup_assistant.dart';

/// Structured local guidance, not a model or a server agent session.
enum SetupIntent {
  chooseModel,
  defaultAgent,
  permission,
  connectRemoteMcp,
  addLocalMcp,
  removeMcp,
  configureProvider,
  configureAgent,
  configureCommand,
}

enum SetupPlannerState { needsInput, proposed, unsupported }

/// All copy is fixed and redacted; user questions are never retained or echoed.
/// Edits use the OC1 configuration vocabulary and still require gateway
/// validation, a review, and explicit Apply. A proposal is never a server write.
final class SetupPlannerReply {
  SetupPlannerReply._({
    required this.sessionId,
    required this.state,
    required String guidance,
    List<String> requiredInputs = const [],
    List<SetupEdit> edits = const [],
  }) : guidance = KitRedact.text(guidance),
       requiredInputs = List.unmodifiable(requiredInputs),
       edits = List.unmodifiable(edits);

  final String sessionId;
  final SetupPlannerState state;
  final String guidance;
  final List<String> requiredInputs;
  final List<SetupEdit> edits;
}

/// Memory-only guided sessions. No network, persistence, credentials or tools.
///
/// [question] is deliberately ignored: the UI must request an explicit intent
/// and structured inputs, and label this mode "Guided setup (on this device)".
/// Sessions are bounded to eight; starting a ninth discards the oldest.
/// Dispose the planner on profile switch/deletion; it must not be a singleton.
final class SetupPlanner {
  final Map<String, _PlannerSession> _sessions = {};
  int _nextId = 0;

  SetupPlannerReply start({
    required SetupIntent intent,
    String? question,
    Map<String, Object?> inputs = const {},
  }) {
    if (_sessions.length >= 8) _sessions.remove(_sessions.keys.first);
    final id = 'setup-${++_nextId}';
    _sessions[id] = _PlannerSession(intent);
    return continueSession(sessionId: id, inputs: inputs);
  }

  SetupPlannerReply continueSession({
    required String sessionId,
    String? question,
    Map<String, Object?> inputs = const {},
  }) {
    final session = _sessions[sessionId];
    if (session == null) {
      return SetupPlannerReply._(
        sessionId: '',
        state: SetupPlannerState.unsupported,
        guidance: 'This guided setup session has ended. Start a new one.',
      );
    }
    final fields = _fields(session.intent);
    if (fields == null) {
      return SetupPlannerReply._(
        sessionId: sessionId,
        state: SetupPlannerState.unsupported,
        guidance: switch (session.intent) {
          SetupIntent.configureProvider =>
            'Provider setup requires a separate secure sign-in flow. Do not enter credentials in the setup assistant.',
          SetupIntent.configureAgent =>
            'Creating or editing agents is not available in guided setup. Choose an existing default agent or use the server configuration tools.',
          _ =>
            'Creating or editing commands is not available in guided setup. Use the server configuration tools.',
        },
      );
    }
    if (inputs.keys.any((key) => !fields.contains(key)) ||
        inputs.entries.any((entry) => !_valid(entry.key, entry.value))) {
      return SetupPlannerReply._(
        sessionId: sessionId,
        state: SetupPlannerState.needsInput,
        guidance:
            'Use the requested fields without credentials. URLs must not contain a password, query, or fragment. No change has been proposed.',
        requiredInputs: fields,
      );
    }
    session.inputs.addAll({
      for (final entry in inputs.entries)
        entry.key: entry.value is List
            ? List<String>.unmodifiable((entry.value as List).cast<String>())
            : entry.value,
    });
    final missing = fields
        .where((field) => !session.inputs.containsKey(field))
        .toList();
    if (missing.isNotEmpty) {
      return SetupPlannerReply._(
        sessionId: sessionId,
        state: SetupPlannerState.needsInput,
        guidance:
            'Choose the requested values to prepare a proposed change. Guided setup runs on this device and does not interpret free-form questions.',
        requiredInputs: missing,
      );
    }
    return SetupPlannerReply._(
      sessionId: sessionId,
      state: SetupPlannerState.proposed,
      guidance:
          'Review this proposed change. Nothing has been applied. Applying requires server support and your confirmation. MCP proposals start disabled. Local MCP commands run on your server when enabled.',
      edits: [_edit(session)],
    );
  }

  void closeSession(String sessionId) => _sessions.remove(sessionId);

  void dispose() => _sessions.clear();

  static List<String>? _fields(SetupIntent intent) => switch (intent) {
    SetupIntent.chooseModel => const ['model'],
    SetupIntent.defaultAgent => const ['agent'],
    SetupIntent.permission => const ['tool', 'effect'],
    SetupIntent.connectRemoteMcp => const ['name', 'url'],
    SetupIntent.addLocalMcp => const ['name', 'command'],
    SetupIntent.removeMcp => const ['name'],
    _ => null,
  };

  static bool _valid(String field, Object? value) {
    if (field == 'command') {
      if (value is! List || value.isEmpty || value.length > 32) return false;
      if (value.any((part) => part is! String || !_safeText(part))) {
        return false;
      }
      // Prevent positional secret flags which ordinary text redaction cannot
      // reliably recognise once split into argv elements.
      final encoded = jsonEncode(value);
      if (KitRedact.containsSecret(encoded)) return false;
      return !value.cast<String>().any(
        (part) => RegExp(
          r'(?:token|password|passwd|secret|api[_-]?key|authorization|bearer)',
          caseSensitive: false,
        ).hasMatch(part),
      );
    }
    if (value is! String || !_safeText(value)) return false;
    if (field == 'url') {
      final uri = Uri.tryParse(value);
      if (uri == null ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        return false;
      }
      return uri.scheme == 'https' ||
          (uri.scheme == 'http' &&
              const {'localhost', '127.0.0.1', '::1'}.contains(uri.host));
    }
    if (field == 'effect') {
      return const {'allow', 'ask', 'deny'}.contains(value);
    }
    if (field == 'tool') {
      return const {
        '*',
        'read',
        'edit',
        'bash',
        'glob',
        'grep',
        'list',
        'task',
        'webfetch',
        'websearch',
        'external_directory',
        'doom_loop',
      }.contains(value);
    }
    return RegExp(
      field == 'model'
          ? r'^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_./:#-]+$'
          : r'^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$',
    ).hasMatch(value);
  }

  static bool _safeText(String value) =>
      value.isNotEmpty &&
      value.length <= 2048 &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value) &&
      !KitRedact.containsSecret(value) &&
      !value.contains(KitRedact.mask);

  static SetupEdit _edit(_PlannerSession session) {
    final input = session.inputs;
    return switch (session.intent) {
      SetupIntent.chooseModel => SetupEdit(
        path: const ['model'],
        value: input['model'],
      ),
      SetupIntent.defaultAgent => SetupEdit(
        path: const ['default_agent'],
        value: input['agent'],
      ),
      SetupIntent.permission => SetupEdit(
        path: List.unmodifiable(['permission', input['tool']! as String]),
        value: input['effect'],
      ),
      SetupIntent.connectRemoteMcp => SetupEdit(
        path: List.unmodifiable(['mcp', input['name']! as String]),
        value: Map<String, Object?>.unmodifiable({
          'type': 'remote',
          'url': input['url'],
          'enabled': false,
        }),
      ),
      SetupIntent.addLocalMcp => SetupEdit(
        path: List.unmodifiable(['mcp', input['name']! as String]),
        value: Map<String, Object?>.unmodifiable({
          'type': 'local',
          'command': input['command'],
          'enabled': false,
        }),
      ),
      SetupIntent.removeMcp => SetupEdit(
        path: List.unmodifiable(['mcp', input['name']! as String]),
        remove: true,
      ),
      _ => throw StateError('Unsupported guided setup intent'),
    };
  }
}

final class _PlannerSession {
  _PlannerSession(this.intent);
  final SetupIntent intent;
  final Map<String, Object?> inputs = {};
}
