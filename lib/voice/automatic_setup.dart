import 'dart:async';

import 'package:flutter/foundation.dart';

import 'automatic_pack.dart';
import 'automatic_setup_platform.dart';
import 'controller.dart';
import 'model_manager.dart';
import 'model_manifest.dart';

enum VoiceSetupStage {
  idle,
  checking,
  consentRequired,
  downloading,
  verifying,

  /// The pack is verified but the app was in the background when it
  /// finished, so the microphone was not started; [requestMicrophone] starts
  /// it once the person is back.
  ready,
  starting,
  listening,
  cancelled,
  blocked,
  failed,
}

enum VoiceSetupProblem {
  unavailable,
  unknownMemory,
  noSupportedPack,
  offline,
  busy,
  downloadFailed,
  listeningFailed,
}

/// First-mic orchestration. Own one per composer; dispose this before the
/// composer. Neither the composer nor its shared model manager is owned here.
///
/// [requestMicrophone] prepares a size/pack offer without downloading. Present
/// localized consent when [stage] is [VoiceSetupStage.consentRequired], then
/// call [confirmDownload]. Consent is per attempt and is never persisted.
/// Settings can use [composer.models] for pack/language management and the
/// existing ReadAloudController for system voices.
///
/// Call [cancel] on route exit or lifecycle pause to revoke auto-listening.
/// This is a foreground download, not a process-surviving background service.
/// No exception text, URLs, filenames or credentials are exposed or persisted.
class VoiceAutomaticSetupController extends ChangeNotifier {
  VoiceAutomaticSetupController({
    required this.composer,
    this.platform = const AndroidVoiceSetupPlatform(),
  }) {
    composer.models.addListener(_modelChanged);
  }

  final VoiceComposerController composer;
  final VoiceSetupPlatform platform;

  VoiceSetupStage _stage = VoiceSetupStage.idle;
  VoiceSetupProblem? _problem;
  VoiceModelPack? _pack;
  VoiceSetupNetwork _network = VoiceSetupNetwork.unknown;
  bool? _notificationAvailable;
  int _receivedBytes = 0;
  int _generation = 0;
  bool _running = false;
  bool _cancelling = false;
  bool _disposed = false;
  bool _ownsDownload = false;
  bool _ownsListeningAttempt = false;
  bool _foreground = true;
  Future<void> _notifications = Future<void>.value();
  String? _lastNotification;

  VoiceSetupStage get stage => _stage;
  VoiceSetupProblem? get problem => _problem;
  VoiceModelPack? get pack => _pack;
  int get downloadBytes => _pack?.downloadBytes ?? 0;
  int get receivedBytes => _receivedBytes;
  VoiceSetupNetwork get network => _network;

  /// Null until attempted, false when permission/channel/bridge is unavailable.
  /// True means Android accepted posting, not proof the user saw it.
  bool? get notificationAvailable => _notificationAvailable;

  /// Whether the app is in front. A download that finishes while it is not
  /// stops at [VoiceSetupStage.ready] instead of opening the microphone
  /// behind the person's back. The download itself keeps going (the
  /// notification shows it); only the automatic start waits.
  void setForeground(bool foreground) => _foreground = foreground;

  /// Hands a started recording over to the composer's own surface. After
  /// this, [cancel] and [dispose] leave the composer's recording alone; the
  /// surface that took it over stops it. Call once [stage] reaches
  /// [VoiceSetupStage.starting] or [VoiceSetupStage.listening].
  void handOff() => _ownsListeningAttempt = false;

  VoiceModelManager get _models => composer.models;
  bool _current(int generation) => !_disposed && generation == _generation;
  bool get _modelsBusy =>
      _models.downloadInProgress || _models.state == VoiceModelState.loading;

  /// Chooses highest-quality eligible shipped pack using total physical RAM.
  /// Retains a supported installed selection. Unknown RAM requires manual
  /// setup; the Java heap class is never a fallback capacity measurement.
  Future<void> requestMicrophone() async {
    if (_disposed || _running || _cancelling) return;
    if (_stage == VoiceSetupStage.listening &&
        composer.state == VoiceComposerState.listening) {
      return;
    }
    if (_modelsBusy ||
        composer.state == VoiceComposerState.initializing ||
        composer.state == VoiceComposerState.listening ||
        composer.state == VoiceComposerState.transcribing ||
        composer.state == VoiceComposerState.finishingCancellation) {
      _set(VoiceSetupStage.blocked, VoiceSetupProblem.busy);
      return;
    }
    _running = true;
    final generation = ++_generation;
    _pack = null;
    _receivedBytes = 0;
    _notificationAvailable = null;
    _network = VoiceSetupNetwork.unknown;
    _set(VoiceSetupStage.checking);
    try {
      await _models.initialize();
      if (!_current(generation)) return;
      if (_models.state == VoiceModelState.error) {
        _set(VoiceSetupStage.failed, VoiceSetupProblem.unavailable);
        return;
      }
      final device = _models.deviceInfo;
      if (!device.captureSupported || !device.hasMicrophone) {
        _set(VoiceSetupStage.blocked, VoiceSetupProblem.unavailable);
        return;
      }
      if (device.totalMemoryMb == null || device.totalMemoryMb! <= 0) {
        _set(VoiceSetupStage.blocked, VoiceSetupProblem.unknownMemory);
        return;
      }
      _pack = automaticVoicePack(_models);
      if (_pack == null) {
        _set(VoiceSetupStage.blocked, VoiceSetupProblem.noSupportedPack);
        return;
      }
      // Free space can block the chosen tier, but cannot silently choose a
      // different model from phone setup. The model manager checks again
      // before downloading in case available space changes after consent.
      if (!_models.supportFor(_pack!).supported) {
        _set(VoiceSetupStage.blocked, VoiceSetupProblem.noSupportedPack);
        return;
      }
      await _models.selectPack(_pack!);
      if (!_current(generation)) return;
      if (_models.isReady) {
        await _startListening(generation);
        return;
      }
      _network = await _readNetwork();
      if (!_current(generation)) return;
      if (_network == VoiceSetupNetwork.offline) {
        _set(VoiceSetupStage.blocked, VoiceSetupProblem.offline);
        return;
      }
      _set(VoiceSetupStage.consentRequired);
    } catch (_) {
      if (_current(generation)) {
        _set(VoiceSetupStage.failed, VoiceSetupProblem.unavailable);
      }
    } finally {
      _running = false;
    }
  }

  /// Rechecks connectivity before using consent. Unknown networks, cellular,
  /// and metered Wi-Fi require explicit [allowMetered]. A change from Wi-Fi
  /// leaves the offer pending so the UI can ask again with the updated state.
  Future<void> confirmDownload({bool allowMetered = false}) async {
    if (_disposed ||
        _running ||
        _cancelling ||
        _stage != VoiceSetupStage.consentRequired) {
      return;
    }
    _running = true;
    final generation = _generation;
    try {
      _network = await _readNetwork();
      if (!_current(generation)) return;
      if (_network == VoiceSetupNetwork.offline) {
        _set(VoiceSetupStage.blocked, VoiceSetupProblem.offline);
        return;
      }
      if (_network != VoiceSetupNetwork.unmetered && !allowMetered) {
        _set(VoiceSetupStage.consentRequired);
        return;
      }
      if (_modelsBusy || _models.selectedPack.id != _pack?.id) {
        _set(VoiceSetupStage.blocked, VoiceSetupProblem.busy);
        return;
      }
      try {
        _notificationAvailable = await platform.requestNotificationPermission();
      } catch (_) {
        _notificationAvailable = false;
      }
      if (!_current(generation)) return;
      // Permission prompts can be open long enough for the network to change.
      _network = await _readNetwork();
      if (!_current(generation)) return;
      if (_network == VoiceSetupNetwork.offline) {
        _set(VoiceSetupStage.blocked, VoiceSetupProblem.offline);
        return;
      }
      if (_network != VoiceSetupNetwork.unmetered && !allowMetered) {
        _set(VoiceSetupStage.consentRequired);
        return;
      }
      if (_modelsBusy || _models.selectedPack.id != _pack?.id) {
        _set(VoiceSetupStage.blocked, VoiceSetupProblem.busy);
        return;
      }
      _ownsDownload = true;
      _lastNotification = null;
      _set(VoiceSetupStage.downloading);
      _post(VoiceSetupNotificationPhase.downloading, generation);
      await _models.downloadSelected();
      if (!_current(generation)) return;
      _ownsDownload = false;
      if (!_models.isReady || _models.selectedPack.id != _pack?.id) {
        _post(VoiceSetupNotificationPhase.failed, generation);
        _set(VoiceSetupStage.failed, VoiceSetupProblem.downloadFailed);
        await _notifications;
        return;
      }
      _receivedBytes = downloadBytes;
      _post(VoiceSetupNotificationPhase.complete, generation);
      await _notifications;
      if (!_current(generation)) return;
      if (!_foreground) {
        _set(VoiceSetupStage.ready);
        return;
      }
      await _startListening(generation);
    } catch (_) {
      if (_current(generation)) {
        _post(VoiceSetupNotificationPhase.failed, generation);
        _set(VoiceSetupStage.failed, VoiceSetupProblem.downloadFailed);
        await _notifications;
      }
    } finally {
      _ownsDownload = false;
      _running = false;
    }
  }

  Future<VoiceSetupNetwork> _readNetwork() async {
    try {
      return await platform.network();
    } catch (_) {
      return VoiceSetupNetwork.unknown;
    }
  }

  Future<void> _startListening(int generation) async {
    if (!_current(generation)) return;
    _ownsListeningAttempt = true;
    _set(VoiceSetupStage.starting);
    try {
      await composer.startListening();
      if (!_current(generation)) return;
      if (composer.state == VoiceComposerState.listening) {
        _set(VoiceSetupStage.listening);
      } else {
        _set(VoiceSetupStage.failed, VoiceSetupProblem.listeningFailed);
      }
    } catch (_) {
      if (_current(generation)) {
        _set(VoiceSetupStage.failed, VoiceSetupProblem.listeningFailed);
      }
    }
  }

  void _modelChanged() {
    if (_disposed || !_ownsDownload) return;
    final progress = _models.progress;
    _receivedBytes = (progress?.received ?? 0).clamp(0, downloadBytes);
    if (_models.state == VoiceModelState.downloading) {
      _set(VoiceSetupStage.downloading);
      _post(VoiceSetupNotificationPhase.downloading, _generation);
    } else if (_models.state == VoiceModelState.verifying) {
      _set(VoiceSetupStage.verifying);
      _post(VoiceSetupNotificationPhase.verifying, _generation);
    }
  }

  // Serialize updates so a late progress result cannot overwrite completion
  // or dismissal. Post at most once per percentage point/phase transition.
  void _post(VoiceSetupNotificationPhase phase, int generation) {
    if (_notificationAvailable != true) return;
    final received = _receivedBytes;
    final total = downloadBytes;
    final percent = total > 0 ? received * 100 ~/ total : 0;
    final key = '${phase.name}:$percent';
    if (key == _lastNotification) return;
    _lastNotification = key;
    _notifications = _notifications.then((_) async {
      if (!_current(generation) || _notificationAvailable != true) return;
      bool posted;
      try {
        posted = await platform.showNotification(
          phase: phase,
          receivedBytes: received,
          totalBytes: total,
        );
      } catch (_) {
        posted = false;
      }
      if (!_current(generation)) return;
      _notificationAvailable = posted;
      _notify();
    });
  }

  /// Revokes pending automatic recording, cancels this controller's download,
  /// and removes its notification. Does not delete verified packs or dispose
  /// the shared model manager. Safe during prompts and delayed completions.
  Future<void> cancel() async {
    if (_disposed || _cancelling) return;
    _cancelling = true;
    ++_generation;
    try {
      await _cancelWork();
      if (!_disposed) _set(VoiceSetupStage.cancelled);
    } finally {
      _cancelling = false;
    }
  }

  Future<void> _cancelWork() async {
    if (_ownsDownload) _models.cancelDownload();
    _ownsDownload = false;
    if (_ownsListeningAttempt) {
      _ownsListeningAttempt = false;
      await composer.cancel();
    }
    _notifications = _notifications.then((_) async {
      try {
        await platform.dismissNotification();
      } catch (_) {
        // A missing bridge cannot undo cancellation or grant capture.
      }
    });
    await _notifications;
  }

  void _set(VoiceSetupStage stage, [VoiceSetupProblem? problem]) {
    _stage = stage;
    _problem = problem;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    _models.removeListener(_modelChanged);
    unawaited(_cancelWork());
    super.dispose();
  }
}
