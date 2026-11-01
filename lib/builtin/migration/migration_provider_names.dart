import 'dart:convert';
import 'dart:io';

const _maximumConfigBytes = 1024 * 1024;
const _maximumProviders = 64;
const _providerLabels = <String, String>{
  'anthropic': 'Anthropic',
  'openai': 'OpenAI',
  'google': 'Google',
  'google-vertex': 'Google Vertex AI',
  'amazon-bedrock': 'Amazon Bedrock',
  'azure': 'Azure',
  'azure-cognitive-services': 'Azure',
  'github-copilot': 'GitHub Copilot',
  'github-copilot-enterprise': 'GitHub Copilot',
  'opencode': 'OpenCode',
  'openrouter': 'OpenRouter',
  'deepseek': 'DeepSeek',
  'groq': 'Groq',
  'mistral': 'Mistral',
  'xai': 'xAI',
  'ollama': 'Ollama',
  'lmstudio': 'LM Studio',
};
const _configPaths = <String>[
  '.config/opencode/opencode.json',
  '.config/opencode/opencode.jsonc',
  '.oc-opencode2/config/opencode/opencode.json',
  '.oc-opencode2/config/opencode/opencode.jsonc',
];

/// Reads labels from an already verified, app-private config item export.
///
/// The caller must verify its migration receipt before passing its directory.
/// That verification owns the trusted-support-to-export path check. This reader
/// rejects links at the export root and below; platform aliases above it are
/// allowed (for example Android's app-private storage parent aliases).
/// This never reads authentication files, session databases or a live server.
/// Labels indicate configuration only, not a working connection or sign-in.
/// Missing, malformed, oversized or unsafe files produce no names. Unknown
/// providers and user-supplied display names are omitted: every returned string
/// is a fixed label above, even when the configuration contains credentials.
Future<List<String>> readMigrationProviderNames(
  Directory verifiedConfigExport,
) async {
  final labels = <String>{};
  for (final relative in _configPaths) {
    RandomAccessFile? input;
    try {
      final file = File('${verifiedConfigExport.absolute.path}/$relative');
      if (!await _regularFileInsideExport(verifiedConfigExport, relative)) {
        continue;
      }
      input = await file.open();
      if (await input.length() > _maximumConfigBytes) continue;
      final bytes = await input.read(_maximumConfigBytes + 1);
      if (bytes.length > _maximumConfigBytes ||
          !await _regularFileInsideExport(verifiedConfigExport, relative)) {
        continue;
      }
      labels.addAll(parseMigrationProviderNames(utf8.decode(bytes)));
    } catch (_) {
      // Filesystem/parser exceptions may embed confidential paths or contents.
    } finally {
      try {
        await input?.close();
      } catch (_) {
        // Never expose a close error or its private source path.
      }
    }
  }
  return List.unmodifiable(labels.toList()..sort());
}

/// Parses JSON/JSONC without reflecting any input key, value or error text.
/// Top-level `provider` IDs and `model` / `small_model` provider prefixes can
/// supply fixed labels. No model identifier or custom name is returned.
List<String> parseMigrationProviderNames(String jsonOrJsonc) {
  try {
    if (jsonOrJsonc.length > _maximumConfigBytes ||
        utf8.encode(jsonOrJsonc).length > _maximumConfigBytes) {
      return const [];
    }
    final clean = _withoutComments(jsonOrJsonc);
    if (clean == null) return const [];
    final decoded = jsonDecode(_withoutTrailingCommas(clean));
    if (decoded is! Map<String, dynamic>) return const [];
    final providers = decoded.containsKey('provider')
        ? decoded['provider']
        : <String, dynamic>{};
    if (providers is! Map<String, dynamic> ||
        providers.length > _maximumProviders ||
        providers.values.any((value) => value is! Map<String, dynamic>)) {
      return const [];
    }
    final labels = <String>{};
    for (final entry in providers.entries) {
      final label = _providerLabels[entry.key];
      if (label != null) labels.add(label);
    }
    for (final field in const ['model', 'small_model']) {
      final model = decoded[field];
      if (model is! String) continue;
      final slash = model.indexOf('/');
      if (slash <= 0 || slash == model.length - 1) continue;
      final label = _providerLabels[model.substring(0, slash)];
      if (label != null) labels.add(label);
    }
    return List.unmodifiable(labels.toList()..sort());
  } catch (_) {
    return const [];
  }
}

Future<bool> _regularFileInsideExport(Directory root, String relative) async {
  var path = root.absolute.path;
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path.split('/').any((part) => part == '.' || part == '..') ||
      await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.directory) {
    return false;
  }
  final components = relative.split('/');
  if (components.any((part) => part.isEmpty || part == '.' || part == '..')) {
    return false;
  }
  for (var i = 0; i < components.length; i++) {
    path = '$path/${components[i]}';
    final type = await FileSystemEntity.type(path, followLinks: false);
    final expected = i == components.length - 1
        ? FileSystemEntityType.file
        : FileSystemEntityType.directory;
    if (type != expected) return false;
  }
  return components.isNotEmpty;
}

String? _withoutComments(String text) {
  final result = StringBuffer();
  var quoted = false;
  var escaped = false;
  var depth = 0;
  for (var i = 0; i < text.length; i++) {
    final character = text[i];
    if (quoted) {
      result.write(character);
      if (escaped) {
        escaped = false;
      } else if (character == r'\') {
        escaped = true;
      } else if (character == '"') {
        quoted = false;
      }
      continue;
    }
    if (character == '"') {
      quoted = true;
    } else if (character == '{' || character == '[') {
      if (++depth > 64) return null;
    } else if (character == '}' || character == ']') {
      if (--depth < 0) return null;
    } else if (character == '/' && i + 1 < text.length) {
      if (text[i + 1] == '/') {
        result.write(' ');
        i += 2;
        while (i < text.length && text[i] != '\n' && text[i] != '\r') {
          i++;
        }
        if (i < text.length) result.write(text[i]);
        continue;
      }
      if (text[i + 1] == '*') {
        final end = text.indexOf('*/', i + 2);
        if (end < 0) return null;
        result.write(' ');
        i = end + 1;
        continue;
      }
    }
    result.write(character);
  }
  return quoted || depth != 0 ? null : result.toString();
}

String _withoutTrailingCommas(String text) {
  final result = StringBuffer();
  var quoted = false;
  var escaped = false;
  for (var i = 0; i < text.length; i++) {
    final character = text[i];
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (character == r'\') {
        escaped = true;
      } else if (character == '"') {
        quoted = false;
      }
    } else if (character == '"') {
      quoted = true;
    } else if (character == ',') {
      var next = i + 1;
      while (next < text.length && ' \t\r\n'.contains(text[next])) {
        next++;
      }
      if (next < text.length && (text[next] == '}' || text[next] == ']')) {
        continue;
      }
    }
    result.write(character);
  }
  return result.toString();
}
