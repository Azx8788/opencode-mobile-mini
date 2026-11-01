import 'dart:math' as math;
import 'dart:ui';

import '../kit_live_style.dart';

/// Small helpers shared by the industrial and premium looks. Everything here
/// is deterministic (no global randomness), so a fixed clock gives a fixed
/// picture and goldens stay stable.

/// A hash of up to three numbers into 0..1 (no 32-bit integer maths, so it
/// behaves the same on the web).
double liveHash(num a, [num b = 0, num c = 0]) {
  final s = math.sin(a * 127.1 + b * 311.7 + c * 74.7) * 43758.5453;
  return s - s.floorToDouble();
}

double _valueNoise(double x, double y) {
  final xi = x.floorToDouble(), yi = y.floorToDouble();
  final xf = x - xi, yf = y - yi;
  final u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf);
  final a = liveHash(xi, yi), b = liveHash(xi + 1, yi);
  final c = liveHash(xi, yi + 1), d = liveHash(xi + 1, yi + 1);
  return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v;
}

/// Three octaves of value noise, 0..1.
double liveFbm(double x, double y) =>
    _valueNoise(x, y) * .6 +
    _valueNoise(x * 2.03 + 5.2, y * 2.03 + 1.3) * .3 +
    _valueNoise(x * 4.1 + 9.1, y * 4.1 + 3.7) * .1;

double liveSmooth(double e0, double e1, double x) {
  final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

Color liveMix(Color a, Color b, double t) =>
    Color.lerp(a, b, t.clamp(0.0, 1.0))!;

/// The most opaque one layer may be at this frame.
double livePeak(KitLiveFrame f) => f.palette.ceiling * f.strength;

/// A seeded generator for a style's static geometry.
math.Random liveRandom(String id) =>
    math.Random(id.codeUnits.fold<int>(7, (h, c) => (h * 31 + c) & 0x7fffffff));

class _Clock {
  double? last;
  double acc = 0;
}

/// A clock that runs at [rate] (1 = the idle speed) and never jumps when the
/// rate changes: it adds the elapsed time times the rate each frame. The
/// first frame starts at `t * rate`, so a fixed `t` is deterministic.
double liveClock(KitLiveFrame f, String key, double rate) {
  final c = f.memory.of<_Clock>('clock.$key', _Clock.new);
  final last = c.last;
  if (last == null || f.t < last) {
    c.acc = f.t * rate;
  } else {
    c.acc += math.min(f.t - last, .25) * rate;
  }
  c.last = f.t;
  return c.acc;
}

class _Slot<T> {
  Size? size;
  Object? sig;
  T? value;
}

/// Static geometry kept in [KitLiveFrame.memory], rebuilt only when the
/// surface [size] or [sig] (colour, strength) changes.
T liveCached<T>(
  KitLiveFrame f,
  String key,
  Size size,
  T Function() make, {
  Object? sig,
  void Function(T old)? dispose,
}) {
  final s = f.memory.of<_Slot<T>>(key, _Slot<T>.new);
  if (s.value == null || s.size != size || s.sig != sig) {
    final old = s.value;
    if (old != null) dispose?.call(old);
    s.value = make();
    s.size = size;
    s.sig = sig;
  }
  return s.value as T;
}
