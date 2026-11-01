import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ui' show Locale;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show mapEquals;

import '../domain/settings_scope.dart';
import 'app_locale.dart';
import 'app_preferences.dart';
import 'effects.dart';
import 'profiles.dart';

typedef _Key = (String, SettingsTarget);

/// Local Settings access bound to explicit owners. This class never acquires a
/// gateway, connects a server, or writes remote configuration.
class ProfileSettingsAccess implements SettingsAccess {
  ProfileSettingsAccess(this._store) : _app = _store.appPreferences {
    _app.addListener(_changed);
    _store.changes.addListener(_changed);
  }

  final ProfileStore _store;
  final AppPreferencesStore _app;
  final Set<SettingsEditToken> _issued = HashSet.identity();
  final Set<_Watch> _watches = {};
  int _revision = 0;
  bool _disposed = false;

  // Token validation and persistence form one serial operation across facades
  // sharing device storage. Privacy bypasses this queue so revocation starts
  // synchronously; the consent owner's epoch serializes that acceptance.
  static final _deviceWrites = Expando<_WriteQueue>();
  static const _deviceKeys = {
    'appearance': 'oc.appearance',
    'themePack': 'oc.themePack',
    'locale': 'oc.appLocale',
    'reasoningExpanded': 'oc.transcript.reasoningExpanded',
    'timestampsVisible': 'oc.transcript.timestampsVisible',
  };
  static const _effectsKeys = {
    'oc.effectsMotion',
    'oc.effectsCelebrations',
    'oc.effectsActivityGlow',
    'oc.effectsGlowStyle',
    'oc.effectsGlowColours',
    'oc.effectsGlowSpeed',
  };

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

  ServerProfile? _profile(String id) =>
      _store.profiles.where((profile) => profile.id == id).firstOrNull;

  String? _fingerprint(SettingsTarget target) {
    if (target.kind == SettingOwnerKind.device) return 'device';
    final id = target.profileId;
    if (id == null || _app.readStateConsent.isClosed(id)) return null;
    final profile = _profile(id);
    if (profile == null) return null;
    final address = Uri.tryParse(profile.baseUrl);
    if (address == null) return null;
    // Never include passwords, bearer tokens, URI credentials or query data.
    final identity = jsonEncode([
      profile.id,
      address.scheme,
      address.host,
      address.port,
      address.path,
      profile.backend.name,
      profile.flavor.name,
      profile.username,
      profile.codexDirectory,
      identityHashCode(profile),
    ]);
    return sha256.convert(utf8.encode(identity)).toString();
  }

  EffectiveSetting _unavailable(
    String id,
    SettingsTarget target,
    SettingsFailureReason reason,
  ) => EffectiveSetting(
    id: id,
    target: target,
    revision: _revision,
    state: reason == SettingsFailureReason.staleTarget
        ? SettingValueState.stale
        : reason == SettingsFailureReason.unsupported
        ? SettingValueState.unsupported
        : SettingValueState.unknown,
    reason: reason,
  );

  EffectiveSetting _read(String id, SettingsTarget target) {
    _checkOpen();
    _checkTarget(target);
    if (target.kind == SettingOwnerKind.device) {
      final value = _app.value;
      final Object? data;
      switch (id) {
        case 'appearance':
          data = value.appearance.name;
        case 'themePack':
          data = value.themePack.name;
        case 'locale':
          data = value.locale?.languageCode;
        case 'reasoningExpanded':
          data = value.reasoningExpanded;
        case 'timestampsVisible':
          data = value.timestampsVisible;
        case 'effects':
          data = _effectsValue(value.effects);
        default:
          return _unavailable(id, target, SettingsFailureReason.unsupported);
      }
      final saved = id == 'effects'
          ? _effectsKeys.any(_app.hasStoredPreference)
          : _app.hasStoredPreference(_deviceKeys[id]!);
      return EffectiveSetting(
        id: id,
        target: target,
        value: data,
        revision: _revision,
        origin: saved
            ? SettingOriginKind.explicitValue
            : SettingOriginKind.defaultValue,
        writable: true,
      );
    }
    if (target.kind != SettingOwnerKind.connection) {
      return _unavailable(id, target, SettingsFailureReason.unsupported);
    }
    if (_fingerprint(target) == null) {
      return _unavailable(id, target, SettingsFailureReason.staleTarget);
    }
    final profileId = target.profileId!;
    if (id == 'shareReadState') {
      return EffectiveSetting(
        id: id,
        target: target,
        value: _app.readStateConsent.enabled(profileId),
        origin: _app.readStateConsent.origin(profileId),
        revision: _revision,
        writable: true,
      );
    }
    try {
      final Object? value;
      final String key;
      switch (id) {
        case 'model':
          final (provider, model) = _store.modelFor(profileId);
          if (provider == null || model == null) {
            if (_store.confirmedSelectionPreference('oc.model.$profileId') !=
                null) {
              return _unavailable(
                id,
                target,
                SettingsFailureReason.invalidValue,
              );
            }
            value = null;
          } else if (provider.isEmpty || model.isEmpty) {
            return _unavailable(id, target, SettingsFailureReason.invalidValue);
          } else {
            value = Map<String, String>.unmodifiable({
              'providerId': provider,
              'modelId': model,
            });
          }
          key = 'oc.model.$profileId';
        case 'agent':
          value = _store.agentFor(profileId);
          key = 'oc.agent.$profileId';
        case 'variant':
          value = _store.variantFor(profileId);
          key = 'oc.variant.$profileId';
        default:
          return _unavailable(id, target, SettingsFailureReason.unsupported);
      }
      return EffectiveSetting(
        id: id,
        target: target,
        value: value,
        revision: _revision,
        origin: _store.confirmedSelectionPreference(key) != null
            ? SettingOriginKind.explicitValue
            : SettingOriginKind.defaultValue,
      );
    } catch (_) {
      return _unavailable(id, target, SettingsFailureReason.invalidValue);
    }
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
          final watch = _Watch((id, target), _fingerprint(target), controller);
          _watches.add(watch);
          controller.onCancel = () => _watches.remove(watch);
          controller.add(initial);
        } on SettingsFailure catch (error, stack) {
          controller.addError(error, stack);
          controller.close();
        }
      }, isBroadcast: true);

  void _changed() {
    if (_disposed) return;
    _revision++;
    for (final watch in _watches.toList()) {
      final (id, target) = watch.key;
      final replaced = watch.fingerprint != _fingerprint(target);
      watch.controller.add(
        replaced
            ? _unavailable(id, target, SettingsFailureReason.staleTarget)
            : _read(id, target),
      );
    }
  }

  void _checkWritable(EffectiveSetting value) {
    if (value.state != SettingValueState.known || !value.writable) {
      throw SettingsFailure(value.reason ?? SettingsFailureReason.unsupported);
    }
  }

  @override
  Future<SettingsEditToken> beginEdit(String id, SettingsTarget target) async {
    final before = _read(id, target);
    _checkWritable(before);
    final token = SettingsEditToken(
      before: before,
      ownerFingerprint: _fingerprint(target)!,
    );
    _issued.add(token);
    return token;
  }

  void _checkEdit(SettingsEditToken edit) {
    _checkOpen();
    if (!_issued.contains(edit) ||
        _fingerprint(edit.before.target) != edit.ownerFingerprint) {
      throw const SettingsFailure(SettingsFailureReason.staleTarget);
    }
    final current = _read(edit.before.id, edit.before.target);
    _checkWritable(current);
    if (current.revision != edit.before.revision) {
      throw const SettingsFailure(SettingsFailureReason.conflict);
    }
  }

  @override
  Future<SettingsReceipt> writeSetting(
    SettingsEditToken edit,
    Object? value,
  ) async {
    _checkEdit(edit);
    if (edit.before.id == 'shareReadState') {
      if (value is! bool) {
        throw const SettingsFailure(SettingsFailureReason.invalidValue);
      }
      _issued.remove(edit);
      final consent = _app.readStateConsent;
      final pending = consent.setEnabledIfCurrent(
        edit.before.target.profileId!,
        value,
        isCurrent: () =>
            !_disposed &&
            _fingerprint(edit.before.target) == edit.ownerFingerprint,
      );
      final acceptedEpoch = consent.epoch;
      await pending;
      _checkCompletion(edit);
      final confirmed = _read(edit.before.id, edit.before.target);
      if (consent.epoch != acceptedEpoch + 1 || confirmed.value != value) {
        throw const SettingsFailure(SettingsFailureReason.conflict);
      }
      return SettingsReceipt(confirmed: confirmed);
    }
    final requested = value is Map
        ? Map<Object?, Object?>.unmodifiable(value)
        : value;
    final write = _deviceWrite(edit.before.id, requested);
    final queue = _deviceWrites[_app] ??= _WriteQueue();
    return queue.add(() async {
      _checkEdit(edit);
      _issued.remove(edit);
      await write();
      _checkCompletion(edit);
      final confirmed = _read(edit.before.id, edit.before.target);
      final matches = requested is Map && confirmed.value is Map
          ? mapEquals(requested, confirmed.value as Map)
          : requested == confirmed.value;
      if (!matches) throw const SettingsFailure(SettingsFailureReason.conflict);
      return SettingsReceipt(confirmed: confirmed);
    });
  }

  void _checkCompletion(SettingsEditToken edit) {
    _checkOpen();
    if (_fingerprint(edit.before.target) != edit.ownerFingerprint) {
      throw const SettingsFailure(SettingsFailureReason.staleTarget);
    }
  }

  Future<void> Function() _deviceWrite(String id, Object? value) {
    switch (id) {
      case 'appearance':
        final parsed = AppAppearance.values
            .where((entry) => entry.name == value)
            .firstOrNull;
        if (parsed != null) return () => _app.setAppearance(parsed);
      case 'themePack':
        final parsed = ThemePackId.values
            .where((entry) => entry.name == value)
            .firstOrNull;
        if (parsed != null) return () => _app.setThemePack(parsed);
      case 'locale':
        if (value == null) return () => _app.setLocale(null);
        if (value is String &&
            AppLocaleStore.supportedLanguages.contains(value)) {
          return () => _app.setLocale(Locale(value));
        }
      case 'reasoningExpanded':
        if (value is bool) return () => _app.setReasoningExpanded(value);
      case 'timestampsVisible':
        if (value is bool) return () => _app.setTimestampsVisible(value);
      case 'effects':
        if (value is Map &&
            value.length == 5 &&
            value['activityGlow'] is bool) {
          final motion = KitMotionLevel.values
              .where((entry) => entry.name == value['motion'])
              .firstOrNull;
          final style = KitGlowStyle.values
              .where((entry) => entry.name == value['glowStyle'])
              .firstOrNull;
          final colours = KitGlowColours.values
              .where((entry) => entry.name == value['glowColours'])
              .firstOrNull;
          final speed = KitGlowSpeed.values
              .where((entry) => entry.name == value['glowSpeed'])
              .firstOrNull;
          if (motion != null &&
              style != null &&
              colours != null &&
              speed != null) {
            final parsed = _app.value.effects.copyWith(
              motion: motion,
              activityGlow: value['activityGlow'] as bool,
              glowStyle: style,
              glowColours: colours,
              glowSpeed: speed,
            );
            return () => _app.setEffects(parsed);
          }
        }
    }
    throw const SettingsFailure(SettingsFailureReason.invalidValue);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _app.removeListener(_changed);
    _store.changes.removeListener(_changed);
    _issued.clear();
    for (final watch in _watches.toList()) {
      watch.controller.close();
    }
    _watches.clear();
  }
}

Map<String, Object> _effectsValue(KitEffects value) => Map.unmodifiable({
  'motion': value.motion.name,
  'activityGlow': value.activityGlow,
  'glowStyle': value.glowStyle.name,
  'glowColours': value.glowColours.name,
  'glowSpeed': value.glowSpeed.name,
});

class _Watch {
  _Watch(this.key, this.fingerprint, this.controller);
  final _Key key;
  final String? fingerprint;
  final MultiStreamController<EffectiveSetting> controller;
}

class _WriteQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> add<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
