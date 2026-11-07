import '../domain/models.dart' show ModelRef;
import '../domain/provider_balance.dart';
import '../domain/server_trust.dart' show normalizeCertificateFingerprint;

/// Personal model shortcuts for one server. These never choose a model for
/// another session; selection remains the connection controller's job.
///
/// [disabled] is the local "only these models" subset: a provider may serve
/// four hundred models, and the picker is not a catalog to scroll. It is a
/// list of what the person turned off, so an empty list keeps the old
/// behaviour — everything the server reports is shown.
///
/// [hiddenProviders] is the provider-level switch: hiding one takes all its
/// models out of the picker without touching the server's config.
/// [balances] holds each provider's optional balance endpoint; it never
/// leaves this phone.
class ModelLibrary {
  static const recentLimit = 8;

  final List<ModelRef> favorites;
  final List<ModelRef> recent;
  final List<ModelRef> disabled;
  final Set<String> hiddenProviders;
  final Map<String, ProviderBalance> balances;

  /// Certificates the person checked and accepted, keyed by origin
  /// (`https://gw.example.com:443`) and stored as a SHA-256 fingerprint.
  ///
  /// A provider endpoint with a self-signed certificate or an incomplete
  /// chain cannot be verified, so the model list used to stop there. Trust
  /// is per origin and per certificate: a different certificate is refused
  /// again, which is what makes this a check rather than a switch.
  final Map<String, String> trustedOrigins;

  const ModelLibrary({
    this.favorites = const [],
    this.recent = const [],
    this.disabled = const [],
    this.hiddenProviders = const {},
    this.balances = const {},
    this.trustedOrigins = const {},
  });

  static bool sameModel(ModelRef? a, ModelRef? b) =>
      a != null &&
      b != null &&
      a.normalized.providerID == b.normalized.providerID &&
      a.normalized.modelID == b.normalized.modelID;

  bool isFavorite(ModelRef model) =>
      favorites.any((item) => sameModel(item, model));

  /// Absent from [disabled] means shown: the picker starts with everything.
  bool isEnabled(ModelRef model) =>
      !disabled.any((item) => sameModel(item, model));

  ModelLibrary toggleFavorite(ModelRef model) => ModelLibrary(
    favorites: List.unmodifiable(
      isFavorite(model)
          ? favorites.where((item) => !sameModel(item, model))
          : [...favorites, model.normalized],
    ),
    recent: recent,
    disabled: disabled,
    hiddenProviders: hiddenProviders,
    balances: balances,
    trustedOrigins: trustedOrigins,
  );

  /// Turns a model on or off in this phone's picker. This does not touch the
  /// server: another client still sees every model the provider serves.
  ModelLibrary withEnabled(ModelRef model, bool enabled) => ModelLibrary(
    favorites: favorites,
    recent: recent,
    disabled: List.unmodifiable(
      enabled
          ? disabled.where((item) => !sameModel(item, model))
          : [...disabled, model.normalized],
    ),
    hiddenProviders: hiddenProviders,
    balances: balances,
    trustedOrigins: trustedOrigins,
  );

  /// One provider's tick set in a single step: [enabled] is shown, [disabled]
  /// is not, and every other model keeps whatever it had.
  ///
  /// The provider form saves the same ticks twice — into the server's config
  /// and into this list — because the picker answers to this phone. A server
  /// that never re-reads its config cannot put back a model that was turned
  /// off here.
  ModelLibrary withEnabledSet(
    String providerID, {
    required Iterable<String> enabled,
    required Iterable<String> disabled,
  }) {
    final provider = providerID.trim();
    if (provider.isEmpty) return this;
    var next = this;
    for (final raw in enabled) {
      final id = raw.trim();
      if (id.isEmpty) continue;
      next = next.withEnabled(
        ModelRef(providerID: provider, modelID: id).normalized,
        true,
      );
    }
    for (final raw in disabled) {
      final id = raw.trim();
      if (id.isEmpty) continue;
      next = next.withEnabled(
        ModelRef(providerID: provider, modelID: id).normalized,
        false,
      );
    }
    return next;
  }

  /// Whether the provider's models are hidden from the picker. A local
  /// preference, like [disabled], one level up.
  bool isProviderHidden(String providerID) =>
      hiddenProviders.contains(providerID.trim());

  ModelLibrary withProviderHidden(String providerID, bool hidden) {
    final id = providerID.trim();
    if (id.isEmpty) return this;
    final next = {...hiddenProviders};
    if (hidden) {
      next.add(id);
    } else {
      next.remove(id);
    }
    return ModelLibrary(
      favorites: favorites,
      recent: recent,
      disabled: disabled,
      hiddenProviders: Set.unmodifiable(next),
      balances: balances,
      trustedOrigins: trustedOrigins,
    );
  }

  ProviderBalance? balanceFor(String providerID) => balances[providerID.trim()];

  ModelLibrary withBalance(String providerID, ProviderBalance balance) {
    final id = providerID.trim();
    if (id.isEmpty) return this;
    final next = {...balances};
    if (!balance.enabled && !balance.isConfigured) {
      next.remove(id);
    } else {
      next[id] = balance;
    }
    return ModelLibrary(
      favorites: favorites,
      recent: recent,
      disabled: disabled,
      hiddenProviders: hiddenProviders,
      balances: Map.unmodifiable(next),
      trustedOrigins: trustedOrigins,
    );
  }

  /// The certificate fingerprint this origin was trusted with, or null.
  String? providerTrustFor(String origin) => trustedOrigins[origin.trim()];

  /// Trusts one certificate for one origin, or forgets it when
  /// [fingerprintSha256] is null.
  ModelLibrary withProviderTrust(String origin, String? fingerprintSha256) {
    final key = origin.trim();
    if (key.isEmpty) return this;
    final next = {...trustedOrigins};
    final value = fingerprintSha256?.trim() ?? '';
    if (value.isEmpty) {
      next.remove(key);
    } else {
      next[key] = normalizeCertificateFingerprint(value);
    }
    return ModelLibrary(
      favorites: favorites,
      recent: recent,
      disabled: disabled,
      hiddenProviders: hiddenProviders,
      balances: balances,
      trustedOrigins: Map.unmodifiable(next),
    );
  }

  ModelLibrary remember(ModelRef model) => ModelLibrary(
    favorites: favorites,
    recent: List.unmodifiable(
      [
        model.normalized,
        ...recent.where((item) => !sameModel(item, model)),
      ].take(recentLimit),
    ),
    disabled: disabled,
    hiddenProviders: hiddenProviders,
    balances: balances,
    trustedOrigins: trustedOrigins,
  );

  /// Only call after a successful catalog refresh. A failed request must
  /// never erase the user's saved shortcuts.
  ModelLibrary retainWhere(bool Function(ModelRef) available) => ModelLibrary(
    favorites: List.unmodifiable(favorites.where(available)),
    recent: List.unmodifiable(recent.where(available)),
    disabled: List.unmodifiable(disabled.where(available)),
    hiddenProviders: hiddenProviders,
    balances: balances,
    trustedOrigins: trustedOrigins,
  );

  ModelRef? next(
    ModelRef? current, {
    bool reverse = false,
    bool favoritesOnly = false,
    required bool Function(ModelRef) available,
  }) {
    final models = (favoritesOnly ? favorites : recent)
        .where(available)
        .toList();
    if (models.isEmpty) return null;
    final index = models.indexWhere((model) => sameModel(model, current));
    final nextIndex = index < 0
        ? (reverse ? models.length - 1 : 0)
        : (index + (reverse ? -1 : 1)) % models.length;
    final next = models[nextIndex];
    return sameModel(next, current) ? null : next;
  }

  Map<String, Object> toJson() => {
    'favorites': favorites.map((model) => model.toJson()).toList(),
    'recent': recent.map((model) => model.toJson()).toList(),
    if (disabled.isNotEmpty)
      'disabled': disabled.map((model) => model.toJson()).toList(),
    if (hiddenProviders.isNotEmpty)
      'hiddenProviders': hiddenProviders.toList()..sort(),
    if (balances.isNotEmpty)
      'balances': {
        for (final entry in balances.entries)
          if (entry.value.enabled || entry.value.isConfigured)
            entry.key: entry.value.toJson(),
      },
    if (trustedOrigins.isNotEmpty) 'trustedOrigins': trustedOrigins,
  };

  factory ModelLibrary.fromJson(Object? value) {
    if (value is! Map) return const ModelLibrary();
    List<ModelRef> read(Object? raw, {int? limit}) {
      if (raw is! List) return const [];
      final result = <ModelRef>[];
      final seen = <(String, String)>{};
      for (final item in raw) {
        if (item is! Map) continue;
        final provider = item['providerID'];
        final id = item['modelID'];
        if (provider is! String || id is! String) continue;
        if (provider.trim().isEmpty || id.trim().isEmpty) continue;
        final model = ModelRef(providerID: provider, modelID: id).normalized;
        if (seen.add((model.providerID, model.modelID))) result.add(model);
        if (limit != null && result.length >= limit) break;
      }
      return List.unmodifiable(result);
    }

    final hidden = <String>{};
    final rawHidden = value['hiddenProviders'];
    if (rawHidden is List) {
      for (final item in rawHidden) {
        if (item is String && item.trim().isNotEmpty) hidden.add(item.trim());
      }
    }
    final balances = <String, ProviderBalance>{};
    final rawBalances = value['balances'];
    if (rawBalances is Map) {
      for (final entry in rawBalances.entries) {
        final id = '${entry.key}'.trim();
        if (id.isEmpty) continue;
        final balance = ProviderBalance.fromJson(entry.value);
        if (balance.enabled || balance.isConfigured) balances[id] = balance;
      }
    }
    final trustedOrigins = <String, String>{};
    final rawTrust = value['trustedOrigins'];
    if (rawTrust is Map) {
      for (final entry in rawTrust.entries) {
        final origin = '${entry.key}'.trim();
        final fingerprint = entry.value;
        if (origin.isEmpty || fingerprint is! String) continue;
        try {
          trustedOrigins[origin] = normalizeCertificateFingerprint(fingerprint);
        } on FormatException {
          // A malformed pin is dropped rather than allowed to make every
          // handshake fail: the person is asked once more instead.
        }
      }
    }

    return ModelLibrary(
      favorites: read(value['favorites']),
      recent: read(value['recent'], limit: recentLimit),
      disabled: read(value['disabled']),
      hiddenProviders: Set.unmodifiable(hidden),
      balances: Map.unmodifiable(balances),
      trustedOrigins: Map.unmodifiable(trustedOrigins),
    );
  }
}
