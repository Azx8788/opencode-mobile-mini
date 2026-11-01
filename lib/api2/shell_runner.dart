import 'dart:async';

import '../domain/remote_shell.dart';
import 'client.dart';
import 'transport.dart';

/// `POST /api/shell` and friends (docs/opencode2-protocol-notes.md §10):
/// start a non-interactive command, poll `GET /api/shell/{id}` until it is no
/// longer running, page `GET /api/shell/{id}/output` by byte cursor, then
/// `DELETE /api/shell/{id}` so the server drops the retained output.
///
/// Transport errors are never attached to the exception: their text may echo
/// the command.
class Api2ShellRunner implements RemoteShellGateway {
  Api2ShellRunner(
    this._client, {
    Future<void> Function(Duration)? sleep,
    this.pollInterval = const Duration(milliseconds: 400),
  }) : _sleep = sleep ?? Future<void>.delayed;

  final Api2Client _client;
  final Future<void> Function(Duration) _sleep;
  final Duration pollInterval;

  static const _pageLimit = 65536;
  static const _maxPages = 64;

  Map<String, dynamic> _location(String? directory) {
    final dir = directory ?? _client.directory;
    final workspace = _client.workspace;
    return {
      if (dir != null && dir.isNotEmpty) 'location[directory]': dir,
      'location[workspace]': ?workspace,
    };
  }

  @override
  Future<RemoteShellResult> runShellCommand(
    String command, {
    String? directory,
    required Duration timeout,
  }) async {
    final transport = _client.transport;
    final query = _location(directory);
    String id;
    try {
      final created = await transport.postJson(
        '/shell',
        query: query,
        body: {
          'command': command,
          if ((directory ?? _client.directory) != null)
            'cwd': directory ?? _client.directory,
          'timeout': timeout.inMilliseconds,
        },
      );
      final data = created is Map ? created['data'] : null;
      if (data is! Map || data['id'] is! String) {
        throw const RemoteShellException(RemoteShellFailure.failed);
      }
      id = data['id'] as String;
    } on Api2Error catch (error) {
      throw RemoteShellException(
        error.isNotFound
            ? RemoteShellFailure.unsupported
            : RemoteShellFailure.failed,
      );
    } on RemoteShellException {
      rethrow;
    } catch (_) {
      throw const RemoteShellException(RemoteShellFailure.failed);
    }

    try {
      final deadline = DateTime.now().add(
        timeout + const Duration(seconds: 15),
      );
      Map<dynamic, dynamic> info;
      while (true) {
        final json = await transport.getJson('/shell/$id', query: query);
        final data = json is Map ? json['data'] : null;
        if (data is! Map) {
          throw const RemoteShellException(RemoteShellFailure.failed);
        }
        info = data;
        if (info['status'] != 'running') break;
        if (DateTime.now().isAfter(deadline)) {
          return RemoteShellResult(
            status: RemoteShellStatus.timedOut,
            output: await _readOutput(transport, id, query),
          );
        }
        await _sleep(pollInterval);
      }
      final output = await _readOutput(transport, id, query);
      final exit = info['exit'];
      return RemoteShellResult(
        status: switch (info['status']) {
          'timeout' => RemoteShellStatus.timedOut,
          'killed' => RemoteShellStatus.killed,
          _ => RemoteShellStatus.exited,
        },
        output: output,
        exitCode: exit is num ? exit.toInt() : null,
      );
    } on RemoteShellException {
      rethrow;
    } catch (_) {
      throw const RemoteShellException(RemoteShellFailure.failed);
    } finally {
      // Drop the server's copy of the output before answering; a failure
      // here only leaves the copy for the server's own cleanup.
      try {
        await transport
            .deleteJson('/shell/$id', query: query)
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
  }

  Future<String> _readOutput(
    Api2Transport transport,
    String id,
    Map<String, dynamic> query,
  ) async {
    final out = StringBuffer();
    var cursor = 0;
    for (var page = 0; page < _maxPages; page++) {
      final json = await transport.getJson(
        '/shell/$id/output',
        query: {...query, 'cursor': '$cursor', 'limit': '$_pageLimit'},
      );
      final data = json is Map ? json['data'] : null;
      if (data is! Map || data['output'] is! String) break;
      out.write(data['output'] as String);
      final next = data['cursor'];
      final size = data['size'];
      if (next is! int || size is! int || next <= cursor || next >= size) {
        break;
      }
      cursor = next;
    }
    return out.toString();
  }
}
