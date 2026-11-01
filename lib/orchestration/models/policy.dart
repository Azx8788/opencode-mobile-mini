/// The host's supervision policy (TEAM-207, 02-ux §7): what the host
/// front's `/front/policy` said about a rig — the supervision level its
/// owner set for the agents and the boundaries the host applies
/// ("Never merge without approval"). Read-only on the phone: the app shows
/// the host's rules, never edits or invents them.
///
/// Lenient like the merge model: unknown keys are kept in [raw], a
/// missing field is its default, nothing here throws on odd JSON.
library;

/// The supervision level a host reports. Mirrors the Start-a-run choices
/// (`TeamSupervision`) but lives in the model layer so the adapter and
/// the scripts stay free of state imports.
enum OrchestrationSupervision {
  high,
  balanced,
  autonomous;

  /// `high` / `balanced` / `autonomous`, case-insensitive; anything else
  /// (including null) is [balanced], the host's own default.
  static OrchestrationSupervision parse(Object? value) {
    if (value is! String) return balanced;
    final word = value.trim().toLowerCase();
    for (final level in values) {
      if (level.name == word) return level;
    }
    return balanced;
  }
}

/// One boundary the host applies, with the wording it uses.
class PolicyBoundary {
  const PolicyBoundary({required this.key, required this.text});

  /// `require_approval`, `require_tests`, `allowed_logins`, `extra-1`, …
  final String key;

  /// The host's wording ("Never merge without approval").
  final String text;

  static PolicyBoundary? fromJson(Object? json) {
    if (json is! Map) return null;
    final key = _text(json['key']);
    if (key == null) return null;
    return PolicyBoundary(key: key, text: _text(json['text']) ?? key);
  }

  Map<String, Object?> toJson() => {'key': key, 'text': text};

  @override
  bool operator ==(Object other) =>
      other is PolicyBoundary && other.key == key && other.text == text;

  @override
  int get hashCode => Object.hash(key, text);

  @override
  String toString() => 'PolicyBoundary($key: $text)';
}

/// The front's policy document for one rig.
class OrchestrationPolicy {
  const OrchestrationPolicy({
    this.rig,
    this.supervision = OrchestrationSupervision.balanced,
    this.boundaries = const [],
    this.raw = const {},
  });

  /// The rig the document describes; null or empty when the city has none.
  final String? rig;
  final OrchestrationSupervision supervision;
  final List<PolicyBoundary> boundaries;

  /// Untouched host payload.
  final Map<String, Object?> raw;

  /// Decodes the front's document; null when [json] carries neither
  /// `supervision` nor `boundaries` (not a policy document).
  static OrchestrationPolicy? fromJson(Object? json) {
    if (json is! Map) return null;
    if (!json.containsKey('supervision') && !json.containsKey('boundaries')) {
      return null;
    }
    final rawBoundaries = json['boundaries'];
    return OrchestrationPolicy(
      rig: _text(json['rig']),
      supervision: OrchestrationSupervision.parse(json['supervision']),
      boundaries: [
        if (rawBoundaries is List)
          for (final boundary in rawBoundaries)
            ?PolicyBoundary.fromJson(boundary),
      ],
      raw: {for (final entry in json.entries) '${entry.key}': entry.value},
    );
  }

  Map<String, Object?> toJson() => {
    if (rig != null) 'rig': rig,
    'supervision': supervision.name,
    'boundaries': [for (final boundary in boundaries) boundary.toJson()],
  };

  @override
  String toString() =>
      'OrchestrationPolicy(${rig ?? '-'}, ${supervision.name}, '
      '${boundaries.length} boundaries)';
}

String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
