import '../domain/models.dart';

/// How a background command ended, as a reader cares about it.
enum BackgroundShellOutcome { finished, failed, stopped }

/// A background command's result, which OpenCode 2 files into the
/// conversation as a notice whose text is the raw
/// `<shell id="…" state="…" command="…">output</shell>` envelope, ending
/// "Command exited with code N.". Read into its parts, it can be shown as a
/// command and how it ended, with the output one tap away, instead of as
/// markup.
class BackgroundShellResult {
  const BackgroundShellResult({
    required this.command,
    required this.state,
    required this.output,
    this.exitCode,
  });

  final String command;
  final String state;
  final String output;
  final int? exitCode;

  static final _envelope = RegExp(
    r'^\s*<shell\b([^>]*)>([\s\S]*?)</shell>\s*$',
  );
  static final _attribute = RegExp(r'([A-Za-z_][\w-]*)="([^"]*)"');
  static final _exit = RegExp(r'\n?\s*Command exited with code (-?\d+)\.?\s*$');

  static BackgroundShellResult? fromPart(Part part) {
    if (part.type != 'v2:notice' || part.toolName != 'synthetic') return null;
    return parse(part.text, fallbackCommand: part.filename);
  }

  static BackgroundShellResult? parse(String text, {String? fallbackCommand}) {
    final match = _envelope.firstMatch(text);
    if (match == null) return null;
    final attributes = {
      for (final attribute in _attribute.allMatches(match.group(1)!))
        attribute.group(1)!: _unescape(attribute.group(2)!),
    };
    var output = match.group(2)!;
    int? exitCode;
    if (_exit.firstMatch(output) case final exit?) {
      exitCode = int.tryParse(exit.group(1)!);
      output = output.substring(0, exit.start);
    }
    final command = (attributes['command'] ?? fallbackCommand ?? '').trim();
    if (command.isEmpty) return null;
    return BackgroundShellResult(
      command: command,
      state: attributes['state'] ?? 'completed',
      output: output.trim(),
      exitCode: exitCode,
    );
  }

  /// 143, 130 and 137 are someone stopping it (SIGTERM, Ctrl-C, kill), not
  /// the command failing.
  BackgroundShellOutcome get outcome {
    if (state == 'killed' || state == 'cancelled') {
      return BackgroundShellOutcome.stopped;
    }
    return switch (exitCode) {
      143 || 130 || 137 => BackgroundShellOutcome.stopped,
      null || 0 =>
        state == 'error' || state == 'failed'
            ? BackgroundShellOutcome.failed
            : BackgroundShellOutcome.finished,
      _ => BackgroundShellOutcome.failed,
    };
  }

  static String _unescape(String value) => value
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
}
