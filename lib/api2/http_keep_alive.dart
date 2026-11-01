import 'package:dio/dio.dart';

/// Browsers own their connection lifetime; no native adapter is imported here.
void configureHttpKeepAlive(
  Dio dio, {
  required String baseUrl,
  String? cleartextConfirmedOrigin,
  String? certificatePinSha256,
}) {
  if (certificatePinSha256 != null) {
    throw UnsupportedError('Certificate pinning requires the native app.');
  }
}
