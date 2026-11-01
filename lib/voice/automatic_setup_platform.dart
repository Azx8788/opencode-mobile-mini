import 'dart:async';

import 'package:flutter/services.dart';

import '../platform/platform_capabilities.dart';

enum VoiceSetupNetwork { unmetered, metered, offline, unknown }

enum VoiceSetupNotificationPhase { downloading, verifying, complete, failed }

/// Android-only support for a foreground, consented voice-pack download.
///
/// Notifications never keep the download alive. A notification tap opens the
/// app; there is currently no voice-settings notification route. No user text,
/// pack paths, credentials, or persisted values cross this API.
abstract interface class VoiceSetupPlatform {
  Future<VoiceSetupNetwork> network();

  /// Requests only notification permission, never a connection service.
  /// False includes denied permission or a disabled notification channel.
  Future<bool> requestNotificationPermission();

  /// Replaces one notification using fixed, native English/Arabic copy.
  /// False means Android could not post; the foreground UI remains usable.
  Future<bool> showNotification({
    required VoiceSetupNotificationPhase phase,
    required int receivedBytes,
    required int totalBytes,
  });

  Future<void> dismissNotification();
}

class AndroidVoiceSetupPlatform implements VoiceSetupPlatform {
  const AndroidVoiceSetupPlatform();

  static const _channel = MethodChannel('oc/voice');
  static Future<void>? _notificationTail;

  @override
  Future<VoiceSetupNetwork> network() async {
    if (!platformCapabilities.supportsVoice) return VoiceSetupNetwork.unknown;
    try {
      final value = await _channel
          .invokeMethod<Object?>('getVoiceSetupNetwork')
          .timeout(const Duration(seconds: 5));
      return switch (value) {
        'unmetered' => VoiceSetupNetwork.unmetered,
        'metered' => VoiceSetupNetwork.metered,
        'offline' => VoiceSetupNetwork.offline,
        _ => VoiceSetupNetwork.unknown,
      };
    } catch (_) {
      return VoiceSetupNetwork.unknown;
    }
  }

  @override
  Future<bool> requestNotificationPermission() async {
    if (!platformCapabilities.supportsVoice) return false;
    try {
      return await _channel
              .invokeMethod<Object?>(
                'requestVoiceDownloadNotificationPermission',
              )
              .timeout(const Duration(seconds: 60)) ==
          true;
    } catch (_) {
      return false;
    }
  }

  /// For a screen that wants to promise a notification: true when the
  /// person can be notified, or when there is nothing to ask (not Android,
  /// or the native side is not wired, as in widget tests, so no refusal is
  /// known). False only for a refusal or a failed ask. No timeout: the
  /// system prompt waits for the person.
  Future<bool> askNotificationsIfWired() async {
    if (!platformCapabilities.supportsVoice) return true;
    try {
      return await _channel.invokeMethod<Object?>(
            'requestVoiceDownloadNotificationPermission',
          ) ==
          true;
    } on MissingPluginException {
      return true;
    } catch (_) {
      return false;
    }
  }

  // All instances share the same native notification ID. Serialize mutations
  // so a queued progress update cannot overtake completion or dismissal.
  // The tail is cleared once idle so no settled future (and the zone it was
  // created in) is retained between downloads.
  static Future<T> _serialize<T>(Future<T> Function() action) {
    final previous = _notificationTail;
    final result = previous == null ? action() : previous.then((_) => action());
    late final Future<void> tail;
    tail = result.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      if (identical(_notificationTail, tail)) _notificationTail = null;
    });
    _notificationTail = tail;
    return result;
  }

  @override
  Future<bool> showNotification({
    required VoiceSetupNotificationPhase phase,
    required int receivedBytes,
    required int totalBytes,
  }) => _serialize(() async {
    if (!platformCapabilities.supportsVoice) return false;
    final total = totalBytes < 0 ? 0 : totalBytes;
    final received = receivedBytes.clamp(0, total);
    try {
      return await _channel
              .invokeMethod<Object?>('showVoiceDownloadNotification', {
                'phase': phase.name,
                'receivedBytes': received,
                'totalBytes': total,
              })
              .timeout(const Duration(seconds: 5)) ==
          true;
    } catch (_) {
      return false;
    }
  });

  @override
  Future<void> dismissNotification() => _serialize(() async {
    if (!platformCapabilities.supportsVoice) return;
    try {
      await _channel
          .invokeMethod<void>('dismissVoiceDownloadNotification')
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Notification support is best effort; no platform error is persisted.
    }
  });
}
