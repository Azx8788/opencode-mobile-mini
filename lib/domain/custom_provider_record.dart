/// Reads `opencode.json` back into records the form can edit.
///
/// Writing a provider was the only direction the app supported: a saved
/// entry could be added but never changed, because nothing turned the file
/// back into the form's model. This file is that direction, and it is pure —
/// given a parsed document it returns records, so every shape the config can
/// take is checkable without a server.
///
/// Two rules:
///
///  * An entry this file does not understand is counted, never guessed at.
///    The list shows "unreadable" and offers nothing that would rewrite it.
///  * The key is reported as a reference, not a value, when it lives on the
///    server. Reading the file itself is a separate, explicit step.
library;

import 'custom_provider.dart';

/// One provider entry as the form edits it.
class CustomProviderRecord {
  const CustomProviderRecord({
    required this.id,
    required this.name,
    required this.protocol,
    required this.baseUrl,
    required this.keyMode,
    required this.format,
    this.apiKey,
    this.secretPath,
    this.keyPlaceholder,
    this.models = const [],
    this.headers = const [],
  });

  /// The key this provider has in the config's provider map.
  final String id;

  final String name;
  final ProviderProtocol protocol;
  final String baseUrl;
  final ProviderKeyMode keyMode;

  /// Which dialect the entry was read from, so an edit writes it back the
  /// same way.
  final ProviderConfigFormat format;

  /// Present for [ProviderKeyMode.plaintext]: the key as the file holds it.
  final String? apiKey;

  /// Present for [ProviderKeyMode.secretFile]: the path inside the server.
  final String? secretPath;

  /// Present for [ProviderKeyMode.external]: the `{env:…}`-style reference
  /// the entry used, so an edit can write it back unchanged.
  final String? keyPlaceholder;

  final List<CustomProviderModel> models;

  /// Extra headers the entry sends with every request.
  final List<CustomProviderHeader> headers;

  /// The draft the form starts from. The key is not resolved here — a
  /// missing key file must not block editing the rest of the entry — so the
  /// caller passes what it read, if anything.
  CustomProviderDraft toDraft({String? withKey}) => CustomProviderDraft(
    name: name,
    id: id,
    protocol: protocol,
    baseUrl: baseUrl,
    apiKey: withKey ?? apiKey,
    keyMode: keyMode,
    keyPlaceholder: keyPlaceholder,
    models: models,
    headers: headers,
  );

  /// The protocol a package name implies. OpenCode picks the wire format by
  /// package, so this is the same decision the writer makes, read backwards.
  static ProviderProtocol protocolOf(String? package) {
    final value = (package ?? '').toLowerCase();
    if (value.contains('anthropic')) return ProviderProtocol.anthropic;
    // `openai-compatible` also contains `openai`: compatible gateways speak
    // Chat Completions, while the bare package is the Responses one.
    if (value.contains('openai') && !value.contains('compatible')) {
      return ProviderProtocol.responses;
    }
    if (value.contains('google') || value.contains('gemini')) {
      return ProviderProtocol.google;
    }
    return ProviderProtocol.chatCompletions;
  }
}

/// What one read of the config found.
class CustomProviderCatalogue {
  const CustomProviderCatalogue({
    required this.records,
    required this.unreadable,
  });

  final List<CustomProviderRecord> records;

  /// Entries whose shape this app does not understand. Counted so the list
  /// can say "1 entry can only be edited on the server" instead of hiding
  /// them.
  final int unreadable;

  static const empty = CustomProviderCatalogue(
    records: <CustomProviderRecord>[],
    unreadable: 0,
  );

  bool get isEmpty => records.isEmpty && unreadable == 0;
}

/// Every entry in [document] this app can describe.
CustomProviderCatalogue readCustomProviders(
  Map<String, Object?>? document,
  ProviderConfigFormat format,
) {
  if (document == null) return CustomProviderCatalogue.empty;
  final root = document[_rootKey(format)];
  if (root is! Map) return CustomProviderCatalogue.empty;
  final records = <CustomProviderRecord>[];
  var unreadable = 0;
  for (final entry in root.entries) {
    final value = entry.value;
    final record = value is Map
        ? _recordFrom('${entry.key}', value, format)
        : null;
    if (record == null) {
      unreadable++;
    } else {
      records.add(record);
    }
  }
  records.sort((a, b) => a.id.compareTo(b.id));
  return CustomProviderCatalogue(records: records, unreadable: unreadable);
}

String _rootKey(ProviderConfigFormat format) =>
    format == ProviderConfigFormat.v1 ? 'provider' : 'providers';

CustomProviderRecord? _recordFrom(
  String id,
  Map entry,
  ProviderConfigFormat format,
) {
  if (id.trim().isEmpty) return null;
  final settings = format == ProviderConfigFormat.v1
      ? entry['options']
      : entry['settings'];
  if (settings is! Map) return null;
  final baseUrl = settings['baseURL'] ?? settings['baseUrl'];
  if (baseUrl is! String || baseUrl.trim().isEmpty) return null;

  final models = _modelsFrom(entry['models']);
  if (models == null) return null;

  final package = format == ProviderConfigFormat.v1
      ? entry['npm']
      : entry['package'];
  // A provider with no package is a server built-in whose config was
  // overridden; the form cannot re-emit it faithfully.
  if (package is! String || package.trim().isEmpty) return null;

  final name = entry['name'];
  final key = _keyFrom(settings['apiKey']);
  return CustomProviderRecord(
    id: id,
    name: name is String && name.trim().isNotEmpty ? name.trim() : id,
    protocol: CustomProviderRecord.protocolOf(package),
    baseUrl: baseUrl.trim(),
    keyMode: key.mode,
    format: format,
    apiKey: key.plaintext,
    secretPath: key.path,
    keyPlaceholder: key.placeholder,
    models: models,
    headers: readProviderHeaders(settings['headers']),
  );
}

/// Null when `models` is present but not a map of models; empty when absent.
List<CustomProviderModel>? _modelsFrom(Object? raw) {
  if (raw == null) return const [];
  if (raw is! Map) return null;
  final models = <CustomProviderModel>[];
  for (final entry in raw.entries) {
    final id = '${entry.key}'.trim();
    if (id.isEmpty) continue;
    final data = entry.value;
    final name = data is Map ? data['name'] : null;
    models.add(
      CustomProviderModel(
        id: id,
        name: name is String && name.trim().isNotEmpty ? name.trim() : null,
      ),
    );
  }
  return models;
}

({
  ProviderKeyMode mode,
  String? plaintext,
  String? path,
  String? placeholder,
})
_keyFrom(Object? raw) {
  const none = (
    mode: ProviderKeyMode.external,
    plaintext: null,
    path: null,
    placeholder: null,
  );
  if (raw is! String) return none;
  final value = raw.trim();
  if (value.isEmpty) return none;
  final file = RegExp(r'^\{file:(.+)\}$').firstMatch(value);
  if (file != null) {
    return (
      mode: ProviderKeyMode.secretFile,
      plaintext: null,
      path: file.group(1)?.trim(),
      placeholder: null,
    );
  }
  // `{env:...}` and any other placeholder mean "the server provides this";
  // the form must not turn one into a literal key — or drop it.
  if (value.startsWith('{')) {
    return (
      mode: ProviderKeyMode.external,
      plaintext: null,
      path: null,
      placeholder: value,
    );
  }
  return (
    mode: ProviderKeyMode.plaintext,
    plaintext: value,
    path: null,
    placeholder: null,
  );
}
