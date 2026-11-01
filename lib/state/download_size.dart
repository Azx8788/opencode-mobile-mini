import '../voice/model_manifest.dart';

/// Evidence about a payload, never a transport/header guess. A lower bound may
/// prove a consent is needed, but cannot prove a download is below the limit.
enum DownloadSizeKind { unknown, exact, lowerBound, estimate }

class DownloadSize {
  const DownloadSize.unknown() : kind = DownloadSizeKind.unknown, bytes = null;
  const DownloadSize.exact(int value)
    : assert(value >= 0),
      kind = DownloadSizeKind.exact,
      bytes = value;
  const DownloadSize.lowerBound(int value)
    : assert(value >= 0),
      kind = DownloadSizeKind.lowerBound,
      bytes = value;
  const DownloadSize.estimate(int value)
    : assert(value >= 0),
      kind = DownloadSizeKind.estimate,
      bytes = value;

  final DownloadSizeKind kind;
  final int? bytes;

  /// Only the immutable packs shipped in this build are a trusted manifest.
  static DownloadSize voicePack(VoiceModelPack pack) =>
      voiceModelPacks.contains(pack)
      ? DownloadSize.exact(pack.downloadBytes)
      : const DownloadSize.unknown();

  /// Unknown/estimated components leave only the sum of trusted components as
  /// a lower bound. This never upgrades an estimate into known-safe evidence.
  static DownloadSize sum(Iterable<DownloadSize> sizes) {
    var total = 0;
    var exact = true;
    for (final size in sizes) {
      if ((size.kind == DownloadSizeKind.exact ||
              size.kind == DownloadSizeKind.lowerBound) &&
          size.bytes != null &&
          size.bytes! >= 0) {
        total += size.bytes!;
        exact = exact && size.kind == DownloadSizeKind.exact;
      } else {
        exact = false;
      }
    }
    return exact ? DownloadSize.exact(total) : DownloadSize.lowerBound(total);
  }
}
