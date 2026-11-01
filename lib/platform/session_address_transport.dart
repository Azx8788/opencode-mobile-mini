import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/session_address_handoff.dart';
import '../domain/session_address_link.dart';

/// Credential-free descriptor transport. A DNS hint alone is NOT deployment
/// evidence; the coordinator independently gates verified private deployments.
class PrivateSessionDescriptorReader implements SessionAddressDescriptorReader {
  PrivateSessionDescriptorReader({
    Future<List<InternetAddress>> Function(String)? resolve,
    Future<ConnectionTask<Socket>> Function(InternetAddress, int)? connect,
    HttpClient Function()? clientFactory,
    this.timeout = const Duration(seconds: 10),
  }) : _resolve = resolve ?? InternetAddress.lookup,
       _connect = connect ?? Socket.startConnect,
       _clientFactory = clientFactory ?? HttpClient.new;

  final Future<List<InternetAddress>> Function(String) _resolve;
  final Future<ConnectionTask<Socket>> Function(InternetAddress, int) _connect;
  final HttpClient Function() _clientFactory;
  final Duration timeout;
  static const maxResponseBytes = 8192;

  static bool isPrivateTailnetAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.length == 4) {
      return bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127;
    }
    const prefix = [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0];
    return bytes.length == 16 &&
        List.generate(6, (i) => bytes[i] == prefix[i]).every((v) => v);
  }

  @override
  Future<SessionAddressDescriptor> discover(String origin) async {
    final canonical = SessionAddressLink.normalizeOrigin(origin);
    final endpoint = Uri.parse(
      '$canonical/.well-known/opencode-mobile-session-handoff',
    );
    final client = _clientFactory();
    var finished = false;
    final connections = <ConnectionTask<Socket>>[];
    client.connectionTimeout = timeout;
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      if (finished ||
          proxyHost != null ||
          proxyPort != null ||
          uri.origin != canonical) {
        throw const SessionAddressFailure(
          SessionAddressFailureCode.privateRouteRequired,
        );
      }
      // Resolve once per actual connection and connect to the checked IP, not
      // the hostname. TLS still authenticates the original DNS name normally.
      final addresses = await _resolve(uri.host);
      if (finished ||
          addresses.isEmpty ||
          !addresses.every(isPrivateTailnetAddress)) {
        throw const SessionAddressFailure(
          SessionAddressFailureCode.privateRouteRequired,
        );
      }
      final task = await _connect(addresses.first, uri.port);
      if (finished) {
        task.cancel();
        throw const SessionAddressFailure(SessionAddressFailureCode.cancelled);
      }
      connections.add(task);
      return task;
    };
    try {
      return await (() async {
        final request = await client.getUrl(endpoint);
        request.followRedirects = false;
        request.maxRedirects = 0;
        request.persistentConnection = false;
        final response = await request.close();
        if (response.statusCode >= 300 && response.statusCode < 400) {
          throw const SessionAddressFailure(
            SessionAddressFailureCode.redirectsRejected,
          );
        }
        if (response.statusCode == 401 || response.statusCode == 403) {
          throw const SessionAddressFailure(
            SessionAddressFailureCode.accessDenied,
          );
        }
        if (response.statusCode != 200) {
          throw const SessionAddressFailure(
            SessionAddressFailureCode.invalidDescriptor,
          );
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > maxResponseBytes) {
            throw const SessionAddressFailure(
              SessionAddressFailureCode.invalidDescriptor,
            );
          }
          bytes.addAll(chunk);
        }
        return SessionAddressDescriptor.parse(jsonDecode(utf8.decode(bytes)));
      })().timeout(timeout);
    } on SessionAddressFailure {
      rethrow;
    } on TimeoutException {
      throw const SessionAddressFailure(SessionAddressFailureCode.timedOut);
    } on HandshakeException {
      throw const SessionAddressFailure(SessionAddressFailureCode.tlsRejected);
    } on TlsException {
      throw const SessionAddressFailure(SessionAddressFailureCode.tlsRejected);
    } on SocketException {
      throw const SessionAddressFailure(SessionAddressFailureCode.unreachable);
    } catch (_) {
      throw const SessionAddressFailure(
        SessionAddressFailureCode.invalidDescriptor,
      );
    } finally {
      finished = true;
      client.close(force: true);
      for (final task in connections) {
        task.cancel();
      }
    }
  }
}
