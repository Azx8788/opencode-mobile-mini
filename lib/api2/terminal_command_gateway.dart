import '../domain/server_gateway.dart';
import '../domain/terminal_lifecycle.dart';
import 'client.dart';

/// Rerun facet sharing the existing authenticated v2 client. Captures its
/// location at construction so later project switching cannot retarget a
/// retained terminal row. Recreate this facet when changing location/profile.
/// The composition owner owns the client's lifetime.
class Api2TerminalCommandGateway implements TerminalCommandGateway {
  Api2TerminalCommandGateway(this._client)
    : _directory = _client.directory,
      _workspace = _client.workspace;

  final Api2Client _client;
  final String? _directory;
  final String? _workspace;

  @override
  Future<TerminalProcess> rerunTerminalCommand(TerminalProcess ended) async {
    final command = terminalRerunSnapshot(ended);
    if (_directory == null ||
        _directory.trim().isEmpty ||
        _client.directory != _directory ||
        _client.workspace != _workspace) {
      throw const ProductException('The terminal location has changed.');
    }
    try {
      final json = await _client.transport.postJson(
        '/pty',
        query: {
          'location[directory]': _directory,
          if (_workspace != null) 'location[workspace]': _workspace,
        },
        body: {
          'command': command.command,
          'args': command.arguments,
          'cwd': command.directory,
          'title': command.title,
        },
      );
      final data = json is Map ? json['data'] : null;
      if (data is! Map ||
          data['id'] is! String ||
          (data['id'] as String).isEmpty ||
          data['title'] is! String ||
          data['command'] is! String ||
          data['args'] is! List ||
          (data['args'] as List).any((value) => value is! String) ||
          data['cwd'] is! String ||
          !['running', 'exited'].contains(data['status']) ||
          data['pid'] is! int ||
          (data['exitCode'] != null && data['exitCode'] is! int)) {
        throw const FormatException('Invalid terminal');
      }
      return TerminalProcess(
        id: data['id'] as String,
        title: data['title'] as String,
        command: data['command'] as String,
        arguments: List.unmodifiable((data['args'] as List).cast<String>()),
        directory: data['cwd'] as String,
        running: data['status'] == 'running',
        pid: data['pid'] as int,
        exitCode: data['exitCode'] as int?,
      );
    } catch (_) {
      // Do not attach transport errors: those may echo command arguments.
      throw const ProductException(
        'Could not confirm the rerun. Refresh terminals before trying again.',
      );
    }
  }
}
