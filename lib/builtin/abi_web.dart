// Stand-in for `dart:ffi` Abi in a browser build. Never reached on a device.
class Abi {
  const Abi._(this.name);
  final String name;

  static const androidArm64 = Abi._('android_arm64');
  static const androidX64 = Abi._('android_x64');

  static Abi current() => androidArm64;
}
