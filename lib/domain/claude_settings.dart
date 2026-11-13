/// The two files Claude Code reads before it will use a third-party gateway.
///
/// Claude Code 2.1 reads `$CLAUDE_CONFIG_DIR/settings.json` for the endpoint
/// and `$CLAUDE_CONFIG_DIR/.claude.json` for whether its first run ever
/// finished. Writing only the first is why a saved gateway still landed on
/// the sign-in screen: the settings named a gateway, and the onboarding state
/// said nobody had set the app up yet.
///
/// Everything here is a pure function over already-decoded JSON, so the rules
/// can be pinned by tests without a phone: what a save adds, what a clear
/// removes, and which model names Claude Code already knows.
library;

import 'dart:convert';

import 'agent_endpoint.dart';
import 'server_gateway/value_types_catalog.dart' show ProductException;

abstract final class ClaudeSettings {
  /// Both paths are relative to the profile's own folder, for the native
  /// write channel that checks each segment.
  static const settingsFile = 'claude/settings.json';
  static const onboardingFile = 'claude/.claude.json';

  /// The model a session uses by default.
  static const defaultModel = 'ANTHROPIC_MODEL';

  /// The three tiers Claude Code picks per task, plus the small model it uses
  /// for titles and summaries. A gateway serves one model, so all four point
  /// at it — otherwise a session asks for `claude-haiku-…` and gets a 404 the
  /// gateway cannot explain.
  static const tierVariables = <String>[
    'ANTHROPIC_DEFAULT_SONNET_MODEL',
    'ANTHROPIC_DEFAULT_OPUS_MODEL',
    'ANTHROPIC_DEFAULT_HAIKU_MODEL',
    'ANTHROPIC_SMALL_FAST_MODEL',
  ];

  static const modelVariables = <String>[defaultModel, ...tierVariables];

  /// Long enough for a gateway that holds a response until it is complete.
  /// Measured: `new.maoyu.cfd` answered a one-token prompt in 71 seconds.
  static const apiTimeoutMs = 600000;
  static const firstByteTimeoutMs = 180000;

  /// The catalog entry a custom model name behaves as: sonnet's 200k window
  /// and its place in the picker. Pinned because this is the entry Claude Code
  /// itself offered when a name was unknown.
  static const behavesAs = 'claude-sonnet-4-6';

  /// Every variable a saved gateway owns, so a clear removes exactly those.
  static const gatewayVariables = <String>[
    'ANTHROPIC_BASE_URL',
    'ANTHROPIC_AUTH_TOKEN',
    'ANTHROPIC_API_KEY',
    'API_TIMEOUT_MS',
    'CLAUDE_STREAM_FIRST_BYTE_TIMEOUT_MS',
    ...modelVariables,
  ];

  /// Claude Code's own catalog already describes a `claude-…` name: its
  /// window, its picker row and its place in the tier list. Mapping one of
  /// those would replace a correct entry with a guess.
  ///
  /// Kept for the picker's display decision only. The merge below does not
  /// branch on it: a gateway's own catalog is the only list that matters, and
  /// `claude-opus-4-7` is a name this build does not know even though it
  /// starts with `claude-`.
  static bool isCatalogModel(String model) =>
      model.toLowerCase().startsWith('claude-');

  /// The settings file after saving [endpoint] over [current].
  ///
  /// [useApiKeyHeader] is the probe's answer: a gateway that rejected
  /// `Authorization: Bearer` and accepted `x-api-key` gets
  /// `ANTHROPIC_API_KEY`, which is the variable Claude Code sends that header
  /// for. Only one of the two is ever written, so a request cannot carry both
  /// and leave the gateway to pick.
  ///
  /// A null [AgentEndpoint.apiKey] keeps the key already in the file, and is
  /// refused when there is none: an endpoint with no key would fail at the
  /// first turn with a message about a missing credential.
  static Map<String, Object?> merge(
    Map<String, Object?> current,
    AgentEndpoint endpoint, {
    required bool useApiKeyHeader,
  }) {
    final next = <String, Object?>{...current};
    final env = _object(next['env']);
    // Claude Code appends `/v1/messages` itself. A provider's saved address
    // keeps its own version segment (`https://agentrouter.org/v1`), and
    // writing that through verbatim turns every request into
    // `/v1/v1/messages` — a 404 the gateway cannot explain. The strip is
    // idempotent, so a value read back from this file is safe to merge again.
    env['ANTHROPIC_BASE_URL'] = AgentEndpoint.claudeCodeBaseUrl(
      endpoint.baseUrl,
    );

    final key = endpoint.apiKey;
    if (key == null) {
      final saved = env['ANTHROPIC_AUTH_TOKEN'] ?? env['ANTHROPIC_API_KEY'];
      if (saved is! String || saved.trim().isEmpty) {
        throw const ProductException('This endpoint has no saved key yet');
      }
    } else if (useApiKeyHeader) {
      env['ANTHROPIC_API_KEY'] = key;
      env.remove('ANTHROPIC_AUTH_TOKEN');
    } else {
      env['ANTHROPIC_AUTH_TOKEN'] = key;
      env.remove('ANTHROPIC_API_KEY');
    }

    env['API_TIMEOUT_MS'] = '$apiTimeoutMs';
    env['CLAUDE_STREAM_FIRST_BYTE_TIMEOUT_MS'] = '$firstByteTimeoutMs';

    final model = endpoint.model;
    if (model == null) {
      for (final name in modelVariables) {
        env.remove(name);
      }
      next.remove('modelPicker');
    } else {
      // Every tier points at the one name the gateway lists. Claude Code
      // chooses a tier per task — a title, a subagent, the main loop — and a
      // tier left at its built-in name is a request for a model the gateway
      // never had, which comes back as the 404 that reads like a broken
      // endpoint. `claude-opus-4-7` starts with `claude-` and is still not a
      // name this build knows, so the tier list cannot be decided by that
      // prefix; one name everywhere is right for a gateway's own name and
      // for a real Claude one alike.
      for (final name in modelVariables) {
        env[name] = model;
      }
      // Without this, Claude Code says the name "isn't described by this
      // version's model catalog" and assumes a window anyway. The row makes
      // the assumption explicit and names the entry it borrows.
      next['modelPicker'] = <String, Object?>{
        'replaceBuiltInOptions': true,
        'options': <Object?>[
          <String, Object?>{
            'model': model,
            'label': model,
            'behavesAs': behavesAs,
          },
        ],
      };
    }
    next['env'] = env;
    return next;
  }

  /// The settings file after removing the gateway: only the variables this
  /// app writes, so a person's other settings and other `env` entries stay.
  static Map<String, Object?> clear(Map<String, Object?> current) {
    final next = <String, Object?>{...current};
    final raw = next['env'];
    if (raw is Map) {
      final env = _object(raw);
      for (final name in gatewayVariables) {
        env.remove(name);
      }
      if (env.isEmpty) {
        next.remove('env');
      } else {
        next['env'] = env;
      }
    }
    next.remove('modelPicker');
    return next;
  }

  /// The onboarding file after marking the first run finished.
  ///
  /// `hasCompletedOnboarding` is the flag that decides between the setup
  /// screen and the chat; `hasTrustDialogAccepted` is per folder and is set
  /// on the folders this file already names, because those are the ones a
  /// session actually opens. Nothing is invented for a folder no session has
  /// used.
  static Map<String, Object?> onboarding(Map<String, Object?> current) {
    final next = <String, Object?>{...current};
    next['hasCompletedOnboarding'] = true;
    final projects = next['projects'];
    if (projects is Map) {
      final copy = <String, Object?>{};
      for (final entry in projects.entries) {
        final value = entry.value;
        copy['${entry.key}'] = value is Map
            ? <String, Object?>{
                ..._object(value),
                'hasTrustDialogAccepted': true,
              }
            : value;
      }
      next['projects'] = copy;
    }
    return next;
  }

  /// Decoded JSON, or an empty object for an empty file.
  ///
  /// A file with comments is refused rather than rewritten: the app cannot
  /// re-emit comments it never parsed, and dropping them silently is worse
  /// than asking the person to remove them.
  static Map<String, Object?> decode(String raw, String what) {
    if (raw.trim().isEmpty) return {};
    final Object? value;
    try {
      value = jsonDecode(raw);
    } on FormatException {
      throw ProductException('$what is not valid JSON');
    }
    if (value is! Map) {
      throw ProductException('$what is not a JSON object');
    }
    return _object(value);
  }

  static String encode(Map<String, Object?> value) =>
      '${const JsonEncoder.withIndent('  ').convert(value)}\n';

  static Map<String, Object?> _object(Object? value) {
    if (value is! Map) return <String, Object?>{};
    return <String, Object?>{
      for (final entry in value.entries) '${entry.key}': entry.value,
    };
  }
}
