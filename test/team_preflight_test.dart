// The team's phone pre-flight: what may block turning the AI Team on.
//
// The in-app team is the native phone engine shipped inside the APK. Nothing
// is downloaded when it starts, so a phone that is low on free space must
// still be offered the action; the download-size reservation belongs to the
// Gas City component (and to Termux), not to this path. These tests pin both
// halves: the space policy still applies where something is downloaded, and
// it never hides the in-app team behind a download that does not happen.
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/builtin/setup/preflight.dart';
import 'package:opencode_mobile/voice/device.dart';

VoiceDeviceInfo phone({
  int? freeBytes = 40 * 1024 * 1024 * 1024,
  int? totalMemoryMb = 8192,
  List<String> abis = const ['arm64-v8a'],
}) => VoiceDeviceInfo(
  availableStorageBytes: freeBytes,
  memoryClassMb: 512,
  totalMemoryMb: totalMemoryMb,
  supportedAbis: abis,
  hasMicrophone: true,
);

void main() {
  // 300 MB: the legacy floor for a download whose extracted size is unknown.
  const download = 300 * 1000 * 1000;

  test('a download needs room for the archive and its extraction', () {
    final result = checkSetupPreflight(
      phone(freeBytes: 100 * 1000 * 1000),
      downloadBytes: download,
    );
    expect(result.supported, isFalse);
    expect(result.issue, SetupPreflightIssue.lowSpace);
  });

  test('the in-app team is not refused for the download it never makes', () {
    final result = checkSetupPreflight(
      phone(freeBytes: 100 * 1000 * 1000),
      downloadBytes: download,
      requireDownloadSpace: false,
    );
    expect(result.supported, isTrue);
    expect(result.issue, isNull);
  });

  test('skipping the download check still refuses a CPU without a rootfs', () {
    final result = checkSetupPreflight(
      phone(abis: const ['armeabi-v7a']),
      downloadBytes: download,
      requireDownloadSpace: false,
    );
    expect(result.issue, SetupPreflightIssue.unsupportedAbi);
    expect(result.reportedAbi, 'armeabi-v7a');
  });

  test('skipping the download check still refuses a phone without memory', () {
    final result = checkSetupPreflight(
      phone(totalMemoryMb: 1024),
      downloadBytes: download,
      requireDownloadSpace: false,
    );
    expect(result.issue, SetupPreflightIssue.lowMemory);
    expect(result.totalMemoryMb, 1024);
  });

  test('a small phone is still told the team may be slow', () {
    final result = checkSetupPreflight(
      phone(totalMemoryMb: 2000, freeBytes: 20 * 1024 * 1024 * 1024),
      downloadBytes: download,
      requireDownloadSpace: false,
    );
    expect(result.supported, isTrue);
    expect(result.mayBeSlow, isTrue);
    expect(result.totalMemoryMb, 2000);
  });
}
