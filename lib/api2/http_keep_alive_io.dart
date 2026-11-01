import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../domain/server_trust.dart';

/// One native client and trust decision per profile connection, never global.
void configureHttpKeepAlive(
  Dio dio, {
  required String baseUrl,
  String? cleartextConfirmedOrigin,
  String? certificatePinSha256,
}) {
  if (dio.httpClientAdapter case IOHttpClientAdapter adapter) {
    Exception? certificateFailure;
    adapter.createHttpClient = () => createServerHttpClient(
      baseUrl: baseUrl,
      cleartextConfirmedOrigin: cleartextConfirmedOrigin,
      certificatePinSha256: certificatePinSha256,
      onCertificateChanged: () =>
          certificateFailure = const ServerCertificateChangedException(),
      onCertificateInvalid: () =>
          certificateFailure = const ServerCertificateValidityException(),
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (certificateFailure != null) {
            handler.reject(
              DioException(requestOptions: options, error: certificateFailure),
            );
          } else {
            handler.next(options);
          }
        },
        onError: (error, handler) {
          // Once a peer differs, this client stays blocked until the connection
          // is explicitly rebuilt. No concurrent retry can silently clear it.
          handler.next(
            certificateFailure != null
                ? error.copyWith(error: certificateFailure)
                : error,
          );
        },
      ),
    );
  }
}
