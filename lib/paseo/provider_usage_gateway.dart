import '../domain/provider_usage.dart';
import '../state/profiles.dart';
import 'transport.dart';

/// Reads plan usage from a Paseo daemon over its own short-lived session
/// (`provider.usage.list.request`, permission daemon.read). The connection is
/// closed after the read; older daemons that do not answer simply time out.
class PaseoProviderUsageGateway implements ProviderUsageGateway {
  PaseoProviderUsageGateway(
    ServerProfile profile, {
    PaseoTransport? transport,
    this.timeout = const Duration(seconds: 10),
    DateTime Function()? clock,
  }) : _transport =
           transport ??
           PaseoTransport(
             endpoint: profile.baseUrl,
             password: profile.password,
             requestTimeout: timeout,
           ),
       _clock = clock ?? DateTime.now;

  /// Reads through a transport somebody else owns (the phone's built-in
  /// host session). [close] leaves it open and nothing here ever connects a
  /// transport that is not already up.
  PaseoProviderUsageGateway.over(
    PaseoTransport transport, {
    this.timeout = const Duration(seconds: 10),
    DateTime Function()? clock,
  }) : _transport = transport,
       _owns = false,
       _clock = clock ?? DateTime.now;

  final PaseoTransport _transport;
  bool _owns = true;
  final Duration timeout;
  final DateTime Function() _clock;

  @override
  Future<List<ProviderUsageReading>> read() async {
    final Map<String, dynamic> payload;
    try {
      payload = await _transport.request(
        'provider.usage.list.request',
        const {},
        timeout: timeout,
      );
    } on ProviderUsageFailure {
      rethrow;
    } catch (_) {
      throw const ProviderUsageFailure(ProviderUsageFailureKind.unavailable);
    }
    return parseProviderUsageList(payload, now: _clock().toUtc());
  }

  @override
  Future<void> close() async {
    if (!_owns) return;
    try {
      await _transport.close();
    } catch (_) {}
  }
}
