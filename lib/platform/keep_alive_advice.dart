import 'app_exit.dart';

/// Phone makers whose Android closes apps on its own (dontkillmyapp.com),
/// grouped by the settings they share.
enum PhoneMaker {
  /// Nubia and RedMagic (ZTE): force-stop an app swiped from Recents.
  nubia,

  /// Xiaomi, Redmi, POCO (MIUI / HyperOS).
  xiaomi,

  /// Oppo, OnePlus, Realme (ColorOS and its relatives).
  oppo,

  /// Vivo and iQOO.
  vivo,

  /// Huawei and Honor.
  huawei,

  samsung,

  /// Everything else, including Pixels: stock Android keeps an app with a
  /// running notification alive.
  other;

  static PhoneMaker of(String manufacturer, [String brand = '']) {
    final name = '${manufacturer.toLowerCase()} ${brand.toLowerCase()}';
    bool has(List<String> words) => words.any(name.contains);
    if (has(const ['nubia', 'redmagic', 'zte'])) return nubia;
    if (has(const ['xiaomi', 'redmi', 'poco'])) return xiaomi;
    if (has(const ['oppo', 'oneplus', 'realme'])) return oppo;
    if (has(const ['vivo', 'iqoo'])) return vivo;
    if (has(const ['huawei', 'honor'])) return huawei;
    if (has(const ['samsung'])) return samsung;
    return other;
  }

  /// Whether swiping the app away from Recents may close it on this phone.
  bool get closesOnSwipe => this != other;
}

/// One thing to allow so Android leaves the app running.
enum KeepAliveStepKind { battery, lockInRecents, autostart, background }

class KeepAliveStep {
  const KeepAliveStep(this.kind, {this.setting});

  final KeepAliveStepKind kind;

  /// The screen that allows it, when there is one to open; the person does
  /// a step without one (locking in Recents) by hand.
  final KeepAliveSetting? setting;
}

/// What to allow on [maker]'s phones, most useful first. Battery comes
/// first everywhere: it is Android's own switch and the one the app can
/// ask for directly.
List<KeepAliveStep> keepAliveSteps(PhoneMaker maker) {
  const battery = KeepAliveStep(
    KeepAliveStepKind.battery,
    setting: KeepAliveSetting.battery,
  );
  const lock = KeepAliveStep(KeepAliveStepKind.lockInRecents);
  const autostart = KeepAliveStep(
    KeepAliveStepKind.autostart,
    setting: KeepAliveSetting.autostart,
  );
  const background = KeepAliveStep(
    KeepAliveStepKind.background,
    setting: KeepAliveSetting.appDetails,
  );
  return switch (maker) {
    // Swiping away force-stops even with the battery exemption: the lock
    // is what helps most there.
    PhoneMaker.nubia => const [battery, lock, background, autostart],
    PhoneMaker.xiaomi => const [battery, autostart, background, lock],
    PhoneMaker.oppo => const [battery, autostart, background, lock],
    PhoneMaker.vivo => const [battery, background, autostart, lock],
    PhoneMaker.huawei => const [battery, autostart, lock],
    PhoneMaker.samsung => const [battery, background, lock],
    PhoneMaker.other => const [battery, background],
  };
}
