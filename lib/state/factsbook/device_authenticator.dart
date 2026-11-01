import 'package:clock/clock.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:local_auth/local_auth.dart';

import '../../domain/factsbook/device_auth.dart';
import '../../domain/factsbook/factsbook_types.dart';

/// Asks the device for the person's fingerprint, face, PIN or pattern right
/// before FactsBook signs an owner decision (the `local_auth` plugin, only
/// ever called from the FactsBook flag's code paths). PIN or pattern are
/// accepted where no biometric is enrolled. Every refusal becomes a
/// [FactsBookException] the screens word plainly:
///
/// - `device_auth_unavailable`: no screen lock or biometric is set up on the
///   phone (or the platform has none);
/// - `device_auth_cancelled`: the person backed out, or the prompt timed out
///   or was interrupted;
/// - `device_auth_locked`: too many wrong tries, try again later;
/// - `device_auth_failed`: anything else.
class LocalAuthDeviceAuthenticator implements DeviceAuthenticator {
  LocalAuthDeviceAuthenticator({LocalAuthentication? auth})
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<DateTime> authenticate({required String reason}) async {
    try {
      if (!await _auth.isDeviceSupported()) {
        throw const FactsBookException('device_auth_unavailable');
      }
      final ok = await _auth.authenticate(
        localizedReason: reason,
        persistAcrossBackgrounding: true,
      );
      if (!ok) throw const FactsBookException('device_auth_cancelled');
      return clock.now();
    } on LocalAuthException catch (error) {
      throw FactsBookException(switch (error.code) {
        LocalAuthExceptionCode.noCredentialsSet ||
        LocalAuthExceptionCode.noBiometricsEnrolled ||
        LocalAuthExceptionCode.noBiometricHardware => 'device_auth_unavailable',
        LocalAuthExceptionCode.userCanceled ||
        LocalAuthExceptionCode.systemCanceled ||
        LocalAuthExceptionCode.timeout ||
        LocalAuthExceptionCode.userRequestedFallback => 'device_auth_cancelled',
        LocalAuthExceptionCode.temporaryLockout ||
        LocalAuthExceptionCode.biometricLockout => 'device_auth_locked',
        _ => 'device_auth_failed',
      });
    } on MissingPluginException {
      throw const FactsBookException('device_auth_unavailable');
    }
  }
}
