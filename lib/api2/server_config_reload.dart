/// Asks the server to re-read the configuration it was started with.
///
/// OpenCode 2 keeps a location's config in memory. A provider entry written to
/// `opencode.json` is invisible until the server re-reads that file: the
/// provider is "not loaded", its models are missing from the catalog and a
/// message to it cannot be sent. `/api/location/reload` is that re-read.
///
/// Returns false instead of throwing. Every caller is a screen that has just
/// written a file and has to tell the person whether the server picked it up;
/// a reload that did not answer is a sentence ("saved, not reloaded yet"), not
/// a failed save.
library;

import 'package:dio/dio.dart';

import 'transport.dart';

/// Reloads the server's config for the location this client is pointed at.
///
/// The credentials and trust rules come from the profile, so a server behind a
/// verified certificate pin reloads the same way it connects.
Future<bool> reloadServerConfig({
  required String baseUrl,
  required String password,
  String username = 'opencode',
  String? cleartextConfirmedOrigin,
  String? certificatePinSha256,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final transport = Api2Transport(
    baseUrl: baseUrl,
    password: password,
    username: username,
    cleartextConfirmedOrigin: cleartextConfirmedOrigin,
    certificatePinSha256: certificatePinSha256,
  );
  try {
    final response = await transport.dio.post<void>(
      '/location/reload',
      options: Options(
        sendTimeout: timeout,
        receiveTimeout: timeout,
        validateStatus: (status) => status != null && status < 400,
      ),
    );
    final status = response.statusCode ?? 0;
    return status >= 200 && status < 300;
  } on DioException {
    return false;
  } catch (_) {
    return false;
  } finally {
    transport.close();
  }
}
