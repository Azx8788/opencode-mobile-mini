import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'custom_provider_ids.dart';
export 'custom_provider_ids.dart';

const customProviderPackage = '@opencode/ai/providers/openai-compatible';

class CustomProviderException implements Exception {
  const CustomProviderException(this.code, {this.status});
  final String code;
  final int? status;
  @override
  String toString() => 'CustomProviderException($code)';
}

enum CustomProviderKeyMode { keep, replace, clear }

String customProviderSlug(String name) {
  final slug = name.trim().toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp('^-+|-+\$'), '');
  if (slug.isEmpty) {
    return 'provider-${sha256.convert(utf8.encode(name)).toString().substring(0, 8)}';
  }
  return slug.substring(0, slug.length > 64 ? 64 : slug.length);
}

void validateCustomProviderId(String id, {Set<String> additionalReserved = const {}}) {
  if (!RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(id)) {
    throw const CustomProviderException('invalid_id');
  }
  if (reservedCustomProviderIds.contains(id) || additionalReserved.contains(id)) {
    throw const CustomProviderException('reserved_id');
  }
}

String normalizeCustomProviderUrl(String input) {
  var value = input.trim().replaceAll(RegExp(r'/+$'), '');
  if (value.endsWith('/chat/completions')) {
    value = value.substring(0, value.length - '/chat/completions'.length)
        .replaceAll(RegExp(r'/+$'), '');
  }
  final uri = Uri.tryParse(value);
  if (uri == null || !const {'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasQuery ||
      uri.hasFragment || value.length > 2048 ||
      RegExp(r'[\s\x00-\x1f\x7f\\]').hasMatch(value) ||
      (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
    throw const CustomProviderException('invalid_url');
  }
  return uri.toString();
}

List<String> customModelsEndpoints(String input) {
  final base = normalizeCustomProviderUrl(input);
  return ['$base/models', if (!Uri.parse(base).path.endsWith('/v1')) '$base/v1/models'];
}

List<String> normalizeCustomModelIds(Iterable<String> input) {
  final values = input.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
  if (values.length > 5000) throw const CustomProviderException('too_large');
  if (values.any((e) => e.length > 512 || RegExp(r'[\x00-\x1f\x7f#]').hasMatch(e))) {
    throw const CustomProviderException('invalid_models');
  }
  return values.toList()..sort();
}

List<String> parseCustomModelsResponse(Object? value) {
  final rows = value is List ? value : value is Map ? value['data'] ?? value['models'] : null;
  if (rows is! List) throw const CustomProviderException('invalid_response');
  return normalizeCustomModelIds([
    for (final row in rows)
      if (row is String) row
      else if (row is Map && (row['id'] ?? row['name']) is String)
        (row['id'] ?? row['name']) as String,
  ]);
}

/// Deliberately no apiKey field. A persisted key stays in the guest helper.
class CustomProviderSummary {
  const CustomProviderSummary({required this.id, required this.name,
    required this.baseUrl, required this.models, required this.hasKey,
    required this.revision});
  final String id;
  final String name;
  final String baseUrl;
  final List<String> models;
  final bool hasKey;
  final String revision;
  factory CustomProviderSummary.fromJson(Map<String, dynamic> json) => CustomProviderSummary(
    id: json['id'] as String,
    name: json['name'] is String ? json['name'] as String : json['id'] as String,
    baseUrl: json['baseURL'] as String,
    models: (json['models'] as List).cast<String>(),
    hasKey: json['hasKey'] == true,
    revision: json['revision'] as String,
  );
}

class CustomProviderListing {
  const CustomProviderListing(this.providers, this.ids);
  final List<CustomProviderSummary> providers;
  final Set<String> ids;
}

class CustomProviderFetch {
  const CustomProviderFetch(this.baseUrl, this.models);
  final String baseUrl;
  final List<String> models;
}

/// Receipt contains no credentials; used to verify eventual server reload.
class CustomProviderChange {
  const CustomProviderChange({required this.id, this.name, this.baseUrl,
    this.models = const [], this.deleted = false});
  final String id;
  final String? name;
  final String? baseUrl;
  final List<String> models;
  final bool deleted;
}
