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
    env['ANTHROPIC_BASE_URL'] = endpoint.baseUrl;

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
      env[defaultModel] = model;
      if (isCatalogModel(model)) {
        // Its own tier entries are more accurate than this file's.
        for (final name in tierVariables) {
          env.remove(name);
        }
        next.remove('modelPicker');
      } else {
        for (final name in tierVariables) {
          env[name] = model;
        }
        // Without this, Claude Code says the name "isn't described by this
        // version's model catalog" and assumes a 200k window anyway. The row
        // makes the assumption explicit and names the entry it borrows.
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
            ? <String, Object?>{..._object(value), 'hasTrustDialogAccepted': true}
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
