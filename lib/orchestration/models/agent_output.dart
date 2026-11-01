/// An agent's live output: the events a session stream delivers, the merge
/// that turns overlapping `turn` captures into one transcript, and the
/// step-log parser that reads `[tool: …]` markers out of that transcript
/// for the Agent detail's Activity section (02-ux §5.2).
library;

/// One event of an agent's session output stream.
sealed class AgentOutputEvent {
  const AgentOutputEvent();
}

/// A capture of the session's transcript: the whole text so far, or a
/// window of it overlapping what came before (Gas City sends pane
/// captures). [mergeAgentOutput] folds either shape into the tail.
class AgentOutputText extends AgentOutputEvent {
  const AgentOutputText(this.text, {this.cursor});

  final String text;

  /// The stream's `id:` for this capture, when it carried one.
  final String? cursor;
}

/// The host no longer serves the session's output (404 once the session
/// stopped or was recycled). Nothing follows.
class AgentOutputEnded extends AgentOutputEvent {
  const AgentOutputEnded({this.reason});

  /// Host-provided detail (`session bl-5qc has no live output`).
  final String? reason;
}

/// Characters of output kept per agent; older text is dropped from the
/// front so a long session never grows without bound.
const agentOutputLimit = 200000;

/// Folds [chunk] into [accumulated]: a chunk already inside the text is a
/// repeat and changes nothing; otherwise the longest suffix of the text
/// that the chunk starts with is the overlap, and only what follows it is
/// appended. A cumulative transcript therefore appends its new tail, a
/// pane capture appends its new lines, and an unrelated chunk is appended
/// whole. The result is trimmed to the last [limit] characters.
String mergeAgentOutput(
  String accumulated,
  String chunk, {
  int limit = agentOutputLimit,
}) {
  if (chunk.isEmpty) return accumulated;
  if (accumulated.isEmpty) return _trim(chunk, limit);
  if (accumulated.contains(chunk)) return accumulated;
  final overlap = _overlap(accumulated, chunk);
  return _trim(accumulated + chunk.substring(overlap), limit);
}

int _overlap(String text, String chunk) {
  final first = chunk.codeUnitAt(0);
  final max = text.length < chunk.length ? text.length : chunk.length;
  for (var k = max; k > 0; k--) {
    if (text.codeUnitAt(text.length - k) != first) continue;
    if (text.endsWith(chunk.substring(0, k))) return k;
  }
  return 0;
}

String _trim(String text, int limit) =>
    text.length <= limit ? text : text.substring(text.length - limit);

// ---------------------------------------------------------------------------
// Step log
// ---------------------------------------------------------------------------

/// What a step did, for the group header and its glyph.
enum AgentStepKind { command, test, read, edit, search, other }

/// One tool call: the tool it went through, the command or argument the
/// marker carried, and the output that followed.
class AgentStep {
  const AgentStep({
    required this.tool,
    required this.command,
    required this.output,
    required this.kind,
  });

  final String tool;
  final String command;
  final String output;
  final AgentStepKind kind;

  AgentStep withOutput(String output) =>
      AgentStep(tool: tool, command: command, output: output, kind: kind);

  @override
  String toString() => 'AgentStep(${kind.name} $tool: $command)';
}

/// A run of the transcript: what the agent said, or what it did.
sealed class AgentTranscriptBlock {
  const AgentTranscriptBlock();
}

/// Text the agent wrote between tool calls.
class AgentProse extends AgentTranscriptBlock {
  const AgentProse(this.text);

  final String text;
}

/// Consecutive tool calls with nothing said in between, shown collapsed
/// like the chat's tool groups.
class AgentStepGroup extends AgentTranscriptBlock {
  const AgentStepGroup(this.steps);

  final List<AgentStep> steps;

  int count(AgentStepKind kind) =>
      steps.where((step) => step.kind == kind).length;
}

/// `[tool: …]` at the start of a line up to the first `]` that ends one;
/// multi-line commands are one marker.
final _marker = RegExp(r'^\[tool: ([\s\S]*?)\]$', multiLine: true);

/// A bare tool name (`bash`, `read`, `apply_patch`), as opposed to the
/// command marker that follows it.
final _toolName = RegExp(r'^[a-z][a-z0-9_.-]{0,23}$');

final _testCommand = RegExp(
  r'(^|[\s;&|(])(pytest|unittest|jest|vitest|mocha|rspec|phpunit|'
  r'flutter\s+test|dart\s+test|npm\s+test|yarn\s+test|pnpm\s+test|'
  r'go\s+test|cargo\s+test|bun\s+test|make\s+test)($|[\s;&|)])',
);

/// Prose is streamed one token per line; a trailing run of at least this
/// many token-like lines after a tool's output is what the agent said next.
const _proseMinLines = 4;

/// Reads the transcript's `[tool: …]` markers into prose and step groups.
///
/// A bare tool name marker (`[tool: bash]`) names the tool for the command
/// markers after it. A command marker repeated with the same text is the
/// same call re-captured with more output, so only the last body counts.
/// The text between a call's output and the next marker is split into the
/// output and the prose that followed it.
List<AgentTranscriptBlock> parseAgentTranscript(String transcript) {
  final blocks = <AgentTranscriptBlock>[];
  var group = <AgentStep>[];
  void closeGroup() {
    if (group.isNotEmpty) {
      blocks.add(AgentStepGroup(List.unmodifiable(group)));
      group = <AgentStep>[];
    }
  }

  void prose(String text) {
    final joined = _joinProse(text);
    if (joined.isEmpty) return;
    closeGroup();
    blocks.add(AgentProse(joined));
  }

  final matches = _marker.allMatches(transcript).toList();
  if (matches.isEmpty) {
    prose(transcript);
    return blocks;
  }
  prose(transcript.substring(0, matches.first.start));
  var tool = 'tool';
  for (var i = 0; i < matches.length; i++) {
    final match = matches[i];
    final marker = match.group(1)!.trim();
    final end = i + 1 < matches.length
        ? matches[i + 1].start
        : transcript.length;
    final body = transcript.substring(match.end, end);
    if (_toolName.hasMatch(marker)) {
      tool = marker;
      prose(body);
      continue;
    }
    final (output, said) = _splitOutput(body);
    if (group.isNotEmpty && group.last.command == marker) {
      group[group.length - 1] = group.last.withOutput(output);
    } else {
      group.add(
        AgentStep(
          tool: tool,
          command: marker,
          output: output,
          kind: _kindOf(tool, marker),
        ),
      );
    }
    if (said.isNotEmpty) prose(said);
  }
  closeGroup();
  return blocks;
}

AgentStepKind _kindOf(String tool, String command) {
  switch (tool) {
    case 'read' || 'view' || 'cat':
      return AgentStepKind.read;
    case 'edit' || 'write' || 'patch' || 'apply_patch' || 'multiedit':
      return AgentStepKind.edit;
    case 'glob' || 'grep' || 'search' || 'list' || 'ls':
      return AgentStepKind.search;
    case 'bash' || 'shell' || 'sh' || 'exec' || 'tool':
      return _testCommand.hasMatch(command)
          ? AgentStepKind.test
          : AgentStepKind.command;
    default:
      return AgentStepKind.other;
  }
}

/// Splits a call's body into its output and the streamed prose after it:
/// the trailing lines that look like tokens (short, or led by a space).
(String, String) _splitOutput(String body) {
  final lines = body.split('\n');
  var cut = lines.length;
  while (cut > 0 && _tokenLike(lines[cut - 1])) {
    cut--;
  }
  final trailing = lines.sublist(cut).where((line) => line.isNotEmpty);
  if (trailing.length < _proseMinLines) return (body.trim(), '');
  // Streamed words carry their leading space; a listing of short names
  // (`calc.py`, `.gc`) does not, and stays output.
  final spaced = trailing.where((line) => line.startsWith(' ')).length;
  if (spaced * 3 < trailing.length) return (body.trim(), '');
  return (
    lines.sublist(0, cut).join('\n').trim(),
    lines.sublist(cut).join('\n'),
  );
}

bool _tokenLike(String line) =>
    line.isEmpty ||
    line.startsWith(' ') ||
    (line.length <= 20 &&
        !line.contains(' ') &&
        !line.contains('/') &&
        !(line.contains('.') && line.length > 1));

/// Streamed tokens joined back into sentences; a real paragraph (lines
/// with spaces inside) keeps its line breaks.
String _joinProse(String text) {
  final lines = text.split('\n');
  final buffer = StringBuffer();
  for (final line in lines) {
    if (line.isEmpty) continue;
    if (_tokenLike(line)) {
      buffer.write(line);
    } else {
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(line.trim());
    }
  }
  return buffer.toString().trim();
}
