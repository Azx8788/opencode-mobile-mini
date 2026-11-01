import 'dart:async';

import 'package:flutter/services.dart';

import '../platform/platform_capabilities.dart';

enum VoiceMicrophonePermission { granted, denied, permanentlyDenied }

class VoiceDeviceUnavailable implements Exception {
  const VoiceDeviceUnavailable();

  @override
  String toString() =>
      'Local voice input is unavailable. Stop playback, check microphone settings, and try again.';
}

class VoiceDeviceInfo {
  const VoiceDeviceInfo({
    required this.availableStorageBytes,
    required this.memoryClassMb,
    this.totalMemoryMb,
    this.lowRamDevice = false,
    required this.supportedAbis,
    required this.hasMicrophone,
    this.captureSupported = true,
  });

  /// A device that answered nothing useful — an Android build with no
  /// `oc/voice` handler, or a probe that failed. Capture is still possible,
  /// so the model picker shows every pack rather than none.
  const VoiceDeviceInfo.unknown()
    : availableStorageBytes = null,
      memoryClassMb = null,
      totalMemoryMb = null,
      lowRamDevice = false,
      supportedAbis = const [],
      hasMicrophone = true,
      captureSupported = true;

  /// A platform this app has no voice capture path for at all.
  ///
  /// Distinct from [VoiceDeviceInfo.unknown]: this is not "we could not
  /// measure the device", it is "there is nothing to measure". The old code
  /// returned `unknown` off Android, whose `hasMicrophone = true` and granted
  /// permission let a desktop user walk into voice setup, download a model,
  /// and record into Android-shaped paths.
  const VoiceDeviceInfo.unsupported()
    : availableStorageBytes = null,
      memoryClassMb = null,
      totalMemoryMb = null,
      lowRamDevice = false,
      supportedAbis = const [],
      hasMicrophone = false,
      captureSupported = false;

  final int? availableStorageBytes;

  /// Android's per-app Java heap class. Kept for diagnostics only: it is
  /// 256-512 MB even on a 16 GB phone, and the speech models do not live in
  /// the Java heap, so it must never decide which model a phone can run.
  final int? memoryClassMb;

  /// Physical memory of the device in MB; null when it could not be read.
  /// Model packs are gated on this.
  final int? totalMemoryMb;

  /// Android Go-class devices, which the system itself marks as low on RAM.
  final bool lowRamDevice;
  final List<String> supportedAbis;
  final bool hasMicrophone;

  /// False when the running platform has no speech capture path.
  final bool captureSupported;
}

abstract interface class VoiceDevicePlatform {
  Future<VoiceDeviceInfo> getDeviceInfo();
  Future<VoiceMicrophonePermission> requestMicrophonePermission();
  Future<void> openAppSettings();
}

class AndroidVoiceDevicePlatform implements VoiceDevicePlatform {
  const AndroidVoiceDevicePlatform();

  static const _channel = MethodChannel('oc/voice');

  @override
  Future<VoiceDeviceInfo> getDeviceInfo() async {
    if (!platformCapabilities.supportsVoice) {
      return const VoiceDeviceInfo.unsupported();
    }
    try {
      final result = await _channel
          .invokeMapMethod<String, dynamic>('getDeviceInfo')
          .timeout(const Duration(seconds: 5));
      return VoiceDeviceInfo(
        availableStorageBytes: (result?['availableStorageBytes'] as num?)
            ?.toInt(),
        memoryClassMb: (result?['memoryClassMb'] as num?)?.toInt(),
        totalMemoryMb: (result?['totalMemoryMb'] as num?)?.toInt(),
        lowRamDevice: result?['lowRamDevice'] == true,
        supportedAbis:
            (result?['supportedAbis'] as List?)?.cast<String>().toList(
              growable: false,
            ) ??
            const [],
        hasMicrophone: result?['hasMicrophone'] as bool? ?? true,
      );
    } catch (_) {
      return const VoiceDeviceInfo.unknown();
    }
  }

  @override
  Future<VoiceMicrophonePermission> requestMicrophonePermission() async {
    // Nothing routes here off Android — the composer's voice tool and the
    // voice settings row are both gated — so this is the backstop, and it
    // says no rather than claiming a grant the platform never made.
    if (!platformCapabilities.supportsVoice) {
      return VoiceMicrophonePermission.permanentlyDenied;
    }
    try {
      final status = await _channel
          .invokeMethod<String>('requestMicrophonePermission')
          .timeout(const Duration(seconds: 60));
      return switch (status) {
        'granted' => VoiceMicrophonePermission.granted,
        'permanentlyDenied' => VoiceMicrophonePermission.permanentlyDenied,
        'denied' => VoiceMicrophonePermission.denied,
        _ => throw const VoiceDeviceUnavailable(),
      };
    } catch (_) {
      // A missing/stale/malformed bridge cannot authorize capture or bypass
      // the native playback-stop interlock.
      throw const VoiceDeviceUnavailable();
    }
  }

  @override
  Future<void> openAppSettings() async {
    if (!platformCapabilities.supportsVoice) return;
    try {
      await _channel
          .invokeMethod<void>('openAppSettings')
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // The recovery action is Android-only and unavailable in unit tests.
    }
  }
}

const voiceDevicePlatform = AndroidVoiceDevicePlatform();
