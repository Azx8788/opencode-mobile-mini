import 'model_manager.dart';
import 'model_manifest.dart';

/// The shared automatic choice for phone setup and the first microphone tap.
/// Keeps a supported installed selection; otherwise chooses the highest RAM
/// tier. A saved preference alone never overrides the device's capacity.
/// Unknown physical RAM does not authorize an automatic choice.
///
/// Storage does not change the model choice. Each caller checks free space
/// before downloading; setup needs the intended size for its own preflight.
VoiceModelPack? automaticVoicePack(VoiceModelManager manager) {
  final device = manager.deviceInfo;
  final memory = device.totalMemoryMb;
  if (!device.captureSupported ||
      !device.hasMicrophone ||
      memory == null ||
      memory <= 0) {
    return null;
  }
  bool eligible(VoiceModelPack pack) {
    final support = manager.supportFor(pack);
    return support.supported || support.kind == VoicePackUnsupported.storage;
  }

  final selected = manager.selectedPack;
  if (manager.isInstalled(selected) && eligible(selected)) return selected;
  final candidates = voiceModelPacks.where(eligible).toList()
    ..sort((a, b) => b.minimumMemoryMb.compareTo(a.minimumMemoryMb));
  return candidates.firstOrNull;
}
