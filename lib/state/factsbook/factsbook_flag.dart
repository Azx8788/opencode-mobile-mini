import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connection.dart' show connProvider;

/// The hidden developer flag for FactsBook (decision D33: the frontend lives
/// behind a flag until v1 is ready). Off by default; nothing about FactsBook
/// shows while it is off.
///
/// Turn it on in a developer build with
/// `--dart-define=OC_FACTSBOOK=true`, or by setting the boolean preference
/// `oc.dev.factsbook` (it is app-wide, not per profile, so it is not swept
/// with a profile).
abstract final class FactsBookFlag {
  static const preferenceKey = 'oc.dev.factsbook';

  static const compiledOn = bool.fromEnvironment('OC_FACTSBOOK');

  static bool read(SharedPreferences prefs) =>
      compiledOn || (prefs.getBool(preferenceKey) ?? false);

  static Future<void> write(SharedPreferences prefs, bool on) =>
      prefs.setBool(preferenceKey, on);
}

/// Whether FactsBook shows. Providers that are not bootstrapped (previews and
/// tests that never built a connection) read as off.
final factsBookEnabledProvider = Provider<bool>((ref) {
  if (FactsBookFlag.compiledOn) return true;
  try {
    return FactsBookFlag.read(ref.watch(connProvider).store.prefs);
  } on Exception {
    return false;
  } on UnimplementedError {
    return false;
  }
});
