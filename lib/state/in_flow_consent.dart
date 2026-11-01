import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../platform/keep_alive_advice.dart';
import '../ui/kit/kit_redact.dart';

/// App consent only. An accepted choice is NOT proof of an Android permission.
enum InFlowConsentKind {
  batteryExemption,
  makerAutoStart,
  needsYouNotifications,
}

enum InFlowConsentChoice { unseen, offered, accepted, denied }

/// Stable localization selectors for Settings; never persist free-form copy.
enum InFlowConsentExplanation {
  notAsked,
  unfinished,
  acceptedCheckSystemSettings,
  batteryMayStopServer,
  makerMayPreventRestart,
  needsYouAlertsOff,
}

class InFlowConsentRow {
  const InFlowConsentRow(this.kind, this.choice);

  final InFlowConsentKind kind;
  final InFlowConsentChoice choice;

  InFlowConsentExplanation get explanation => switch (choice) {
    InFlowConsentChoice.unseen => InFlowConsentExplanation.notAsked,
    InFlowConsentChoice.offered => InFlowConsentExplanation.unfinished,
    InFlowConsentChoice.accepted =>
      InFlowConsentExplanation.acceptedCheckSystemSettings,
    InFlowConsentChoice.denied => switch (kind) {
      InFlowConsentKind.batteryExemption =>
        InFlowConsentExplanation.batteryMayStopServer,
      InFlowConsentKind.makerAutoStart =>
        InFlowConsentExplanation.makerMayPreventRestart,
      InFlowConsentKind.needsYouNotifications =>
        InFlowConsentExplanation.needsYouAlertsOff,
    },
  };
}

/// One instance per saved server/profile, owned by the composition root.
///
/// Claims are committed BEFORE returning a prompt, so rebuilds, overlapping
/// callers and process restarts never repeat an automatic ask. If presentation
/// is interrupted, Settings exposes [InFlowConsentChoice.offered] as unfinished.
/// No platform request, background monitoring or notification is enabled here.
/// Await mutations then rebuild from [row]; no listener lifecycle is required.
/// Dispose the owner before profile deletion; the existing profile preference
/// sweep removes `oc.inFlowConsent.<profileId>` without any shared-blob changes.
class InFlowConsent {
  InFlowConsent._(this._prefs, this._key, this._firstStart, this._choices);

  final SharedPreferences _prefs;
  final String _key;
  bool _firstStart;
  Map<InFlowConsentKind, InFlowConsentChoice> _choices;
  Future<void> _tail = Future.value();
  bool _unavailable = false;

  /// False after a failed write. Disable consent actions and show a storage
  /// error; a remembered choice alone must not be used to bypass this failure.
  bool get storageAvailable => !_unavailable;

  /// Invalid/corrupt storage throws a content-free error; do not show prompts
  /// or assume acceptance when this fails. There is deliberately no reset.
  static Future<InFlowConsent> load(
    SharedPreferences prefs, {
    required String profileId,
  }) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(profileId) ||
        KitRedact.text(profileId) != profileId) {
      throw ArgumentError('Expected an opaque saved profile ID');
    }
    final key = 'oc.inFlowConsent.$profileId';
    try {
      // SharedPreferences can cache a value even when a disk write failed.
      await prefs.reload();
      final raw = prefs.getString(key);
      if (raw == null) return InFlowConsent._(prefs, key, false, {});
      if (raw.length > 4096) throw const FormatException();
      final value = jsonDecode(raw);
      if (value is! Map ||
          value['version'] != 1 ||
          value['firstStart'] is! bool ||
          value['choices'] is! Map) {
        throw const FormatException();
      }
      final choices = <InFlowConsentKind, InFlowConsentChoice>{};
      for (final entry in (value['choices'] as Map).entries) {
        final kind = InFlowConsentKind.values.byName(entry.key as String);
        final choice = InFlowConsentChoice.values.byName(entry.value as String);
        choices[kind] = choice;
      }
      return InFlowConsent._(prefs, key, value['firstStart'] as bool, choices);
    } catch (_) {
      throw StateError('Consent storage unavailable');
    }
  }

  InFlowConsentRow row(InFlowConsentKind kind) =>
      InFlowConsentRow(kind, _choices[kind] ?? InFlowConsentChoice.unseen);

  /// Call when a phone-hosted server is first started, never on remote connect
  /// or app launch. Presents battery then maker advice, sequentially in the UI.
  /// A maker without an auto-start step never gets an irrelevant prompt.
  /// Already exempt batteries are skipped; no OS grant is inferred or stored.
  Future<List<InFlowConsentKind>> phoneServerFirstStart({
    required bool batteryAlreadyExempt,
    required PhoneMaker maker,
  }) => _serial(() async {
    if (_firstStart) return const [];
    final candidates = [
      if (!batteryAlreadyExempt) InFlowConsentKind.batteryExemption,
      if (keepAliveSteps(
        maker,
      ).any((step) => step.kind == KeepAliveStepKind.autostart))
        InFlowConsentKind.makerAutoStart,
    ].where((kind) => row(kind).choice == InFlowConsentChoice.unseen).toList();
    await _save({
      ..._choices,
      for (final kind in candidates) kind: InFlowConsentChoice.offered,
    }, firstStart: true);
    return List.unmodifiable(candidates);
  });

  /// Call at the action that offers “Notify me when the agent needs me”. Returns
  /// true only to the first caller that may present the consent. Accepting this
  /// is per-server intent, not permission to rewrite global notify preferences.
  Future<bool> requestNeedsYouPreset() => _serial(() async {
    const kind = InFlowConsentKind.needsYouNotifications;
    if (row(kind).choice != InFlowConsentChoice.unseen) return false;
    await _save({..._choices, kind: InFlowConsentChoice.offered});
    return true;
  });

  /// Record the person's explicit answer before invoking an existing platform
  /// API. Cancel/back counts as denial. No implicit acceptance or auto-reply.
  Future<void> answer(InFlowConsentKind kind, {required bool allow}) => _serial(
    () async {
      if (row(kind).choice != InFlowConsentChoice.offered) {
        throw StateError('Consent is not awaiting an answer');
      }
      await _save({
        ..._choices,
        kind: allow ? InFlowConsentChoice.accepted : InFlowConsentChoice.denied,
      });
    },
  );

  /// Explicit Settings interaction may revise consent, without resetting the
  /// automatic-prompt marker. Turning off platform features remains the caller's
  /// responsibility; an OS setting may have changed independently at any time.
  Future<void> changeFromSettings(
    InFlowConsentKind kind, {
    required bool allow,
  }) => _serial(() async {
    await _save({
      ..._choices,
      kind: allow ? InFlowConsentChoice.accepted : InFlowConsentChoice.denied,
    });
  });

  /// Stops accepting changes and waits for a write in flight, so the profile
  /// deletion sweep that follows removes `oc.inFlowConsent.<profileId>` for
  /// good. A later [load] starts from what storage then holds.
  Future<void> close() {
    final drained = _tail;
    _unavailable = true;
    return drained;
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) {
      if (_unavailable) throw StateError('Consent storage unavailable');
      return action();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _save(
    Map<InFlowConsentKind, InFlowConsentChoice> choices, {
    bool? firstStart,
  }) async {
    try {
      final encoded = jsonEncode({
        'version': 1,
        'firstStart': firstStart ?? _firstStart,
        'choices': {for (final e in choices.entries) e.key.name: e.value.name},
      });
      final safe = KitRedact.text(encoded);
      if (safe != encoded || !await _prefs.setString(_key, safe)) {
        throw StateError('Consent write failed');
      }
      _choices = choices;
      _firstStart = firstStart ?? _firstStart;
    } catch (_) {
      _unavailable = true;
      throw StateError('Consent storage unavailable');
    }
  }
}
