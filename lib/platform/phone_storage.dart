import '../builtin/builtin_linux.dart';
import '../voice/device.dart';
import 'platform_capabilities.dart';

/// An absolute free-space warning, not a percentage of the phone's capacity.
enum PhoneStoragePressure { unknown, nearlyFull, aboveThreshold }

/// Whether an explicit in-app host scan produced a measurement.
enum BuiltinStorageAvailability { notRequested, unavailable, available }

/// A transient measurement. Refresh after cleanup or returning to the app.
/// Null means unknown; zero is a measured value. Nothing is persisted.
class PhoneStorageSnapshot {
  const PhoneStorageSnapshot({
    required this.availableBytes,
    required this.pressure,
    required this.builtinHost,
    required this.builtinAvailability,
  });

  /// Space available on the filesystem containing the app's private files.
  /// This is neither total phone capacity nor remote/Termux filesystem space.
  final int? availableBytes;
  final PhoneStoragePressure pressure;

  /// Logical file sizes for the built-in Ubuntu runtime and its projects.
  /// Not filesystem allocation, and not the entire application's storage.
  final BuiltinProjectStorage? builtinHost;
  final BuiltinStorageAvailability builtinAvailability;
}

/// Read-only storage API over existing native contracts. Requires no server,
/// microphone permission, new MethodChannel method, or background service.
///
/// Call [read] on entry or explicit refresh, not from build or a polling timer.
/// Host scans recurse through files; opt in only for the built-in host screen
/// and await completion before refreshing again. No cleanup is performed.
class PhoneStorageService {
  PhoneStorageService({
    Future<VoiceDeviceInfo> Function()? readDeviceInfo,
    Future<BuiltinProjectStorage> Function()? readBuiltinStorage,
    PlatformCapabilities? capabilities,
    this.nearlyFullAtBytes = 1024 * 1024 * 1024,
  }) : _readDeviceInfo = readDeviceInfo ?? voiceDevicePlatform.getDeviceInfo,
       _readBuiltinStorage =
           readBuiltinStorage ?? BuiltinLinux().projectStorage,
       _capabilities = capabilities {
    if (nearlyFullAtBytes < 0) {
      throw ArgumentError.value(nearlyFullAtBytes, 'nearlyFullAtBytes');
    }
  }

  final Future<VoiceDeviceInfo> Function() _readDeviceInfo;
  final Future<BuiltinProjectStorage> Function() _readBuiltinStorage;
  final PlatformCapabilities? _capabilities;

  /// Inclusive warning threshold, default 1 GiB. It is app policy, not an
  /// Android low-storage signal or a guarantee that an operation will fit.
  final int nearlyFullAtBytes;

  /// Capability to attempt a local measurement, not proof it succeeded.
  bool get isSupported => (_capabilities ?? platformCapabilities).isAndroid;

  /// Each source fails independently to unknown without exposing its error.
  /// [includeBuiltinHost] defaults to false to avoid an implicit disk walk.
  Future<PhoneStorageSnapshot> read({bool includeBuiltinHost = false}) async {
    int? available;
    BuiltinProjectStorage? host;
    if (isSupported) {
      try {
        final value = (await _readDeviceInfo()).availableStorageBytes;
        if (value != null && value >= 0) available = value;
      } catch (_) {
        // Native error messages can contain private paths. Keep them local.
      }
      if (includeBuiltinHost) {
        try {
          final value = await _readBuiltinStorage();
          if (value.runtimeBytes >= 0 &&
              value.projectsBytes >= 0 &&
              value.measuredAtMilliseconds >= 0) {
            host = value;
          }
        } catch (_) {
          // Unknown host storage must not erase a successful free-space read.
        }
      }
    }
    return PhoneStorageSnapshot(
      availableBytes: available,
      pressure: available == null
          ? PhoneStoragePressure.unknown
          : available <= nearlyFullAtBytes
          ? PhoneStoragePressure.nearlyFull
          : PhoneStoragePressure.aboveThreshold,
      builtinHost: host,
      builtinAvailability: !includeBuiltinHost
          ? BuiltinStorageAvailability.notRequested
          : host == null
          ? BuiltinStorageAvailability.unavailable
          : BuiltinStorageAvailability.available,
    );
  }
}
