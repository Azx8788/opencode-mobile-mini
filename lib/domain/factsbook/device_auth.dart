/// Proof that the person is there: a fingerprint, face, PIN or pattern asked
/// for right before an owner decision is signed. The time it returns is the
/// `authenticated_at` the node checks (no older than five minutes).
abstract interface class DeviceAuthenticator {
  /// Asks for the device's own authentication; [reason] is the prompt's
  /// words. Returns when it succeeded, or throws [FactsBookException]
  /// (`device_auth_unavailable`, `device_auth_cancelled`,
  /// `device_auth_locked`, `device_auth_failed`).
  Future<DateTime> authenticate({required String reason});
}
