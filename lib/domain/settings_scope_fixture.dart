import 'dart:async';
import 'dart:collection';

import 'settings_scope.dart';

typedef _Key = (String, SettingsTarget);

/// Deterministic scenes for UI builders. Values exist only when supplied;
/// metadata never creates a fabricated preference or remote write capability.
class MemorySettingsAccess implements SettingsAccess {
  MemorySettingsAccess({Iterable<EffectiveSetting> initial = const []}) {
    for (final value in initial) {
      publish(value);
    }
  }

  final Map<_Key, EffectiveSetting> _values = {};
  final Map<_Key, Set<MultiStreamController<EffectiveSetting>>> _watches = {};
  final Set<SettingsEditToken> _issued = HashSet.identity();
  final Map<SettingsTarget, int> _generations = {};
  bool _disposed = false;

  void _checkOpen() {
    if (_disposed) throw const SettingsFailure(SettingsFailureReason.disposed);
  }

  void _checkTarget(SettingsTarget target) {
    if (target.ownerId.isEmpty ||
        target.profileId == '' ||
        target.projectId == '' ||
        target.sessionId == '') {
      throw const SettingsFailure(SettingsFailureReason.invalidValue);
    }
  }

  EffectiveSetting _read(String id, SettingsTarget target) {
    _checkOpen();
    _checkTarget(target);
    return _values[(id, target)] ??
        EffectiveSetting(
          id: id,
          target: target,
          state: SettingValueState.unsupported,
          reason: SettingsFailureReason.unsupported,
        );
  }

  @override
  Future<EffectiveSetting> readSetting(
    String id,
    SettingsTarget target,
  ) async => _read(id, target);

  @override
  Stream<EffectiveSetting> watchSetting(String id, SettingsTarget target) =>
      Stream<EffectiveSetting>.multi((controller) {
        try {
          final initial = _read(id, target);
          final key = (id, target);
          final watchers = _watches.putIfAbsent(key, () => {});
          watchers.add(controller);
          controller.onCancel = () {
            watchers.remove(controller);
            if (watchers.isEmpty) _watches.remove(key);
          };
          // Enrol before delivering the initial value, so no publish is lost.
          controller.add(initial);
        } on SettingsFailure catch (error, stack) {
          controller.addError(error, stack);
          controller.close();
        }
      }, isBroadcast: true);

  String _fingerprint(SettingsTarget target) =>
      'fixture:${target.kind.index}:${_generations[target] ?? 0}';

  void _checkWritable(EffectiveSetting setting) {
    if (setting.state == SettingValueState.stale) {
      throw const SettingsFailure(SettingsFailureReason.staleTarget);
    }
    if (setting.state != SettingValueState.known || !setting.writable) {
      throw SettingsFailure(
        setting.reason ?? SettingsFailureReason.unsupported,
      );
    }
    final device = setting.target.kind == SettingOwnerKind.device;
    final supported = device
        ? const {
            'appearance',
            'themePack',
            'locale',
            'reasoningExpanded',
            'timestampsVisible',
            'effects',
          }.contains(setting.id)
        : setting.target.kind == SettingOwnerKind.connection &&
              setting.id == 'shareReadState';
    if (!supported || setting.authority != SettingAuthority.localPreference) {
      throw const SettingsFailure(SettingsFailureReason.unsupported);
    }
  }

  @override
  Future<SettingsEditToken> beginEdit(String id, SettingsTarget target) async {
    final before = _read(id, target);
    _checkWritable(before);
    final token = SettingsEditToken(
      before: before,
      ownerFingerprint: _fingerprint(target),
    );
    _issued.add(token);
    return token;
  }

  @override
  Future<SettingsReceipt> writeSetting(
    SettingsEditToken edit,
    Object? value,
  ) async {
    _checkOpen();
    if (!_issued.contains(edit)) {
      throw const SettingsFailure(SettingsFailureReason.staleTarget);
    }
    final before = edit.before;
    if (edit.ownerFingerprint != _fingerprint(before.target)) {
      throw const SettingsFailure(SettingsFailureReason.staleTarget);
    }
    final current = _read(before.id, before.target);
    _checkWritable(current);
    if (current.revision != before.revision) {
      throw const SettingsFailure(SettingsFailureReason.conflict);
    }
    if (!_validValue(before.id, value)) {
      throw const SettingsFailure(SettingsFailureReason.invalidValue);
    }
    final confirmed = _snapshot(
      EffectiveSetting(
        id: current.id,
        target: current.target,
        value: value,
        authority: current.authority,
        origin: SettingOriginKind.explicitValue,
        revision: current.revision + 1,
        writable: true,
      ),
    );
    _issued.remove(edit);
    // Memory is the fixture's persistence; publish only after committing it.
    _values[(confirmed.id, confirmed.target)] = confirmed;
    _emit(confirmed);
    return SettingsReceipt(confirmed: confirmed);
  }

  /// Publishes a new observation. Revisions never decrease, including when a
  /// caller supplies a replacement scene using its default revision of zero.
  /// A stale scene also invalidates issued tokens for the target's other rows.
  void publish(EffectiveSetting value) {
    _checkOpen();
    _checkTarget(value.target);
    if (value.id.isEmpty || value.revision < 0) {
      throw const SettingsFailure(SettingsFailureReason.invalidValue);
    }
    final key = (value.id, value.target);
    final previous = _values[key];
    final revision = previous != null && value.revision <= previous.revision
        ? previous.revision + 1
        : value.revision;
    final observed = _snapshot(value, revision: revision);
    if (observed.state == SettingValueState.stale) {
      _generations[value.target] = (_generations[value.target] ?? 0) + 1;
    }
    _values[key] = observed;
    _emit(observed);
  }

  void _emit(EffectiveSetting value) {
    for (final watcher
        in _watches[(value.id, value.target)]?.toList() ??
            <MultiStreamController<EffectiveSetting>>[]) {
      watcher.add(value);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _issued.clear();
    for (final watchers in _watches.values.toList()) {
      for (final watcher in watchers.toList()) {
        watcher.close();
      }
    }
    _watches.clear();
    _values.clear();
    _generations.clear();
  }
}

EffectiveSetting _snapshot(EffectiveSetting value, {int? revision}) =>
    EffectiveSetting(
      id: value.id,
      target: value.target,
      value: _freeze(value.value),
      state: value.state,
      authority: value.authority,
      origin: value.origin,
      revision: revision ?? value.revision,
      writable: value.writable,
      reason: value.reason,
    );

Object? _freeze(Object? value) => switch (value) {
  Map value => Map.unmodifiable({
    for (final entry in value.entries) entry.key: _freeze(entry.value),
  }),
  List value => List.unmodifiable(value.map(_freeze)),
  Set value => Set.unmodifiable(value.map(_freeze)),
  _ => value,
};

// Wire names intentionally remain independent of Flutter/state enum imports.
// The frozen contract's domain tests cover the supported production names.
bool _validValue(String id, Object? value) => switch (id) {
  'appearance' => const {'system', 'light', 'dark'}.contains(value),
  'themePack' => const {
    'opencode',
    'catppuccin',
    'gruvbox',
    'solarized',
    'dracula',
    'nord',
    'tokyoNight',
    'oneDark',
    'monokai',
    'rosePine',
    'everforest',
    'kanagawa',
    'ayu',
    'nightOwl',
    'github',
    'palenight',
    'synthwave',
    'cobalt',
    'midnight',
    'paper',
    'forest',
    'ocean',
    'sunset',
    'sakura',
    'lavender',
    'mint',
    'coffee',
    'slate',
    'amber',
    'highContrast',
    'dynamic',
  }.contains(value),
  'locale' =>
    value == null ||
        const {'ar', 'en', 'es', 'ja', 'pt', 'ru', 'zh'}.contains(value),
  'reasoningExpanded' ||
  'timestampsVisible' ||
  'shareReadState' => value is bool,
  'effects' =>
    value is Map &&
        value.length == 5 &&
        const {'full', 'calm', 'off'}.contains(value['motion']) &&
        value['activityGlow'] is bool &&
        const {'classic', 'softRing'}.contains(value['glowStyle']) &&
        const {'one', 'two'}.contains(value['glowColours']) &&
        const {'slow', 'normal', 'fast'}.contains(value['glowSpeed']),
  _ => false,
};
