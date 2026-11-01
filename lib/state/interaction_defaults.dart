import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/server_gateway.dart';
import '../ui/kit/kit_redact.dart';
import '../voice/model_manifest.dart';
import '../voice/read_aloud.dart';

/// Stable notice identities; translate these at the presentation boundary.
enum DefaultKind { project, model, voicePack, voice, delivery, review }

enum DefaultReason {
  explicitChoice,
  onlyOption,
  lastUsed,
  firstProject,
  serverDefault,
  deviceMemory,
  locale,
  queue,
  changedScope,
  unresolved,
}

enum DefaultReviewScope { session, workingTree, branch }

/// A selection, not an instruction to perform an action or open a picker.
/// [label] is safe presentation data. Values remain intact for gateway calls.
class DefaultChoice<T> {
  DefaultChoice({
    required this.value,
    required String label,
    required this.reason,
    required this.optionCount,
  }) : label = KitRedact.text(label);

  final T? value;
  final String label;
  final DefaultReason reason;
  final int optionCount;

  /// Zero options must show unavailable/create state, never an empty picker.
  bool get skipPicker => optionCount <= 1 || value != null;
  bool get canChange => optionCount > 1;
  bool get isAutomatic =>
      value != null && reason != DefaultReason.explicitChoice;
}

/// A missing [project] means a proposed creation name, not an existing project.
class DefaultProject {
  const DefaultProject({required this.name, this.project});
  final String name;
  final WorkspaceProject? project;
  bool get needsCreation => project == null;
}

/// Pure defaults policy. Pass fresh, capability-filtered options and existing
/// explicit settings; this class performs no I/O and never changes a setting.
abstract final class InteractionDefaults {
  static DefaultChoice<T> picker<T>(
    List<T> options, {
    required String Function(T) label,
    T? explicitChoice,
  }) {
    if (explicitChoice != null && options.contains(explicitChoice)) {
      return _choice(
        explicitChoice,
        label,
        DefaultReason.explicitChoice,
        options,
      );
    }
    if (options.length == 1) {
      return _choice(options.single, label, DefaultReason.onlyOption, options);
    }
    return _choice(null, label, DefaultReason.unresolved, options);
  }

  static DefaultChoice<DefaultProject> project(
    List<WorkspaceProject> projects, {
    String? lastUsedID,
    String? explicitID,
  }) {
    if (projects.isEmpty) {
      return DefaultChoice(
        value: const DefaultProject(name: 'my-app'),
        label: 'my-app',
        reason: DefaultReason.firstProject,
        optionCount: 0,
      );
    }
    final explicit = _find(projects, (p) => p.id == explicitID);
    final last = _find(projects, (p) => p.id == lastUsedID);
    final selected =
        explicit ?? (projects.length == 1 ? projects.single : last);
    return DefaultChoice(
      value: selected == null
          ? null
          : DefaultProject(name: selected.name, project: selected),
      label: selected?.name ?? '',
      reason: explicit != null
          ? DefaultReason.explicitChoice
          : projects.length == 1
          ? DefaultReason.onlyOption
          : last != null
          ? DefaultReason.lastUsed
          : DefaultReason.unresolved,
      optionCount: projects.length,
    );
  }

  /// Invoke after sign-in/catalog loading. Match server IDs, display the name;
  /// never guess a model by a potentially ambiguous human-readable name.
  static DefaultChoice<CatalogModel> model(
    List<CatalogModel> models, {
    required bool signedIn,
    String? serverProviderID,
    String? serverModelID,
    CatalogModel? explicitChoice,
  }) {
    final options = signedIn
        ? models.where((m) => m.enabled).toList()
        : <CatalogModel>[];
    final explicit = _find(
      options,
      (m) =>
          m.providerID == explicitChoice?.providerID &&
          m.id == explicitChoice?.id,
    );
    if (explicit != null || options.length <= 1) {
      return picker(options, label: (m) => m.name, explicitChoice: explicit);
    }
    return _choice(
      _find(
        options,
        (m) => m.providerID == serverProviderID && m.id == serverModelID,
      ),
      (m) => m.name,
      DefaultReason.serverDefault,
      options,
    );
  }

  /// Use physical RAM, never Android's heap memoryClass. Choose the largest
  /// eligible pack; unknown RAM gets the smallest eligible fallback. Filter
  /// ABI/storage through VoiceModelManager.supportFor before passing packs.
  static DefaultChoice<VoiceModelPack> voicePack({
    required int? totalMemoryMb,
    required List<VoiceModelPack> supportedPacks,
    String? explicitID,
  }) {
    final options =
        supportedPacks
            .where(
              (p) =>
                  totalMemoryMb == null || p.minimumMemoryMb <= totalMemoryMb,
            )
            .toList()
          ..sort((a, b) {
            final comparison = a.minimumMemoryMb.compareTo(b.minimumMemoryMb);
            return comparison == 0 ? a.id.compareTo(b.id) : comparison;
          });
    final explicit = _find(options, (p) => p.id == explicitID);
    if (explicit != null || options.length <= 1) {
      return picker(options, label: (p) => p.label, explicitChoice: explicit);
    }
    return _choice(
      totalMemoryMb == null ? options.first : options.last,
      (p) => p.label,
      DefaultReason.deviceMemory,
      options,
    );
  }

  /// Voices must come from ReadAloudController.voices (available offline
  /// voices). Prefer exact locale, then language. No foreign-language guess.
  static DefaultChoice<ReadAloudVoice> voice(
    List<ReadAloudVoice> voices, {
    required String locale,
    String? explicitID,
  }) {
    final explicit = _find(voices, (v) => v.id == explicitID);
    if (explicit != null || voices.length <= 1) {
      return picker(voices, label: (v) => v.label, explicitChoice: explicit);
    }
    String normalize(String value) => value.replaceAll('_', '-').toLowerCase();
    final target = normalize(locale);
    final selected =
        _find(voices, (v) => normalize(v.locale) == target) ??
        _find(
          voices,
          (v) =>
              normalize(v.locale).split('-').first == target.split('-').first,
        );
    return _choice(selected, (v) => v.label, DefaultReason.locale, voices);
  }

  static DefaultChoice<PromptDelivery> delivery({
    PromptDelivery? explicitChoice,
  }) => _choice(
    explicitChoice ?? PromptDelivery.queue,
    (d) => d.name,
    explicitChoice == null ? DefaultReason.queue : DefaultReason.explicitChoice,
    PromptDelivery.values,
  );

  /// Null count means unknown/loading, zero means confirmed empty. When more
  /// than one scope has changes, prefer session, working tree, then branch.
  /// Include only scopes supported by the current gateway/session.
  static DefaultChoice<DefaultReviewScope> review(
    Map<DefaultReviewScope, int?> changeCounts, {
    DefaultReviewScope? explicitChoice,
  }) {
    final options = DefaultReviewScope.values
        .where(changeCounts.containsKey)
        .toList();
    if (explicitChoice != null && options.contains(explicitChoice)) {
      return picker(
        options,
        label: (s) => s.name,
        explicitChoice: explicitChoice,
      );
    }
    final changed = _find(options, (s) => (changeCounts[s] ?? 0) > 0);
    return _choice(changed, (s) => s.name, DefaultReason.changedScope, options);
  }

  static T? _find<T>(Iterable<T> values, bool Function(T) matches) {
    for (final value in values) {
      if (matches(value)) return value;
    }
    return null;
  }

  static DefaultChoice<T> _choice<T>(
    T? value,
    String Function(T) label,
    DefaultReason reason,
    List<T> options,
  ) => DefaultChoice(
    value: value,
    label: value == null ? '' : label(value),
    reason: value == null ? DefaultReason.unresolved : reason,
    optionCount: options.length,
  );
}

/// One shared writer per preference store and profile. The profile deletion
/// sweep stops admission and drains this owner before discovering its keys.
class InteractionDefaultsStore {
  factory InteractionDefaultsStore(
    SharedPreferences preferences, {
    required String profileID,
  }) {
    if (profileID.isEmpty || KitRedact.containsSecret(profileID)) {
      throw ArgumentError('A non-secret profile identifier is required');
    }
    final owners = _shared[preferences] ??= {};
    return owners[profileID] ??= InteractionDefaultsStore._(
      preferences,
      profileID,
    );
  }

  InteractionDefaultsStore._(this.preferences, this.profileID);

  static final _shared = Expando<Map<String, InteractionDefaultsStore>>();

  /// Keeps the closed owner registered: a new screen must not reopen admission
  /// between the preference sweep and the profile row's removal.
  static Future<void> closeProfile(SharedPreferences preferences, String id) {
    final owner = InteractionDefaultsStore(preferences, profileID: id);
    owner._closed = true;
    return owner.drain();
  }

  final SharedPreferences preferences;
  final String profileID;
  Future<void> _pending = Future<void>.value();
  bool _closed = false;

  bool get _present {
    try {
      final raw = preferences.getString('oc.profiles');
      if (raw == null) return false;
      final profiles = jsonDecode(raw);
      return profiles is List &&
          profiles.any((p) => p is Map && p['id'] == profileID);
    } catch (_) {
      return false;
    }
  }

  void _checkAdmission() {
    if (_closed || !_present) {
      throw StateError('Server defaults are unavailable');
    }
  }

  String get _projectKey => 'oc.defaultProject.$profileID';
  String get _noticesKey => 'oc.defaultNotices.$profileID';

  String? get lastProjectID {
    final value = preferences.getString(_projectKey);
    return value == null || KitRedact.containsSecret(value) ? null : value;
  }

  /// Call only after successfully opening/creating a project. Reject sensitive
  /// IDs instead of persisting a redacted ID that could target another project.
  Future<void> rememberProject(String id) => _serialize(() async {
    if (id.isEmpty || KitRedact.containsSecret(id)) {
      throw ArgumentError('A non-secret project identifier is required');
    }
    await _save(() => preferences.setString(_projectKey, KitRedact.text(id)));
  });

  /// Call at the visible point of use, not during builds or background probes.
  /// Returns a safe label once per kind/profile, across restarts. The UI uses
  /// kind + label for localized copy. Failure throws and does not claim success.
  /// Concurrent calls on this instance are serialized. Explicit choices and
  /// unresolved defaults never consume the notice.
  Future<String?> takeAnnouncement<T>(
    DefaultKind kind,
    DefaultChoice<T> choice,
  ) => _serialize(() async {
    if (!choice.isAutomatic) return null;
    final seen = preferences.getStringList(_noticesKey) ?? <String>[];
    if (seen.contains(kind.name)) return null;
    await _save(
      () => preferences.setStringList(
        _noticesKey,
        [...seen, kind.name].map(KitRedact.text).toList(),
      ),
    );
    return choice.label;
  });

  /// Drain before profile deletion, then discard this instance. The existing
  /// ProfileStore.removeScopedPreferences sweep removes both keys.
  Future<void> drain() => _pending;

  Future<void> _save(Future<bool> Function() write) async {
    try {
      if (await write()) return;
    } catch (_) {
      // Platform failures may include payloads; expose only a fixed message.
    }
    // SharedPreferences mutates its cache before the platform acknowledges a
    // write. Reload so a refused notice does not look consumed on the retry.
    await preferences.reload();
    throw StateError('Could not save interaction defaults');
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    // Check both at admission and when queued work actually starts.
    try {
      _checkAdmission();
    } catch (error, stack) {
      return Future<T>.error(error, stack);
    }
    final result = _pending.then((_) {
      _checkAdmission();
      return action();
    });
    _pending = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
