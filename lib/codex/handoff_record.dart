import '../domain/models.dart';
import 'mappers.dart';
import 'transport.dart';

/// Handoff-only view of `thread/read(includeTurns: true)` persisted items.
///
/// This deliberately does not reuse the chat mapper: patch bodies and reasoning
/// are excluded, and command cwd/exit status and successful changed paths must
/// survive into the common record builder. Text is never shortened here. That
/// builder masks credentials before applying its whole-turn UTF-8 size budget.
List<MessageWithParts> codexHandoffMessages(Map<String, dynamic> thread) {
  final threadID = codexString(thread['id'], max: 256);
  if (!const {'legacy', 'paginated'}.contains(thread['historyMode'])) {
    _invalid();
  }
  final result = <MessageWithParts>[];
  final turnIDs = <String>{};
  final itemIDs = <String>{};
  final messageIDs = <String>{};
  var itemCount = 0;
  var partCount = 0;

  void add(MessageWithParts message) {
    partCount += message.parts.length;
    if (result.length >= 5000 || partCount > 10000) _invalid();
    if (!messageIDs.add(message.info.id)) _invalid();
    result.add(message);
  }

  for (final rawTurn in codexList(thread['turns'], max: 5000)) {
    final turn = codexObject(rawTurn);
    final turnID = codexString(turn['id'], max: 256);
    if (!turnIDs.add(turnID)) _invalid();
    // 0.153.4 marks summary/not-loaded payloads explicitly. Missing metadata
    // cannot establish a full-history read either.
    if (turn['itemsView'] != 'full') _invalid();
    final status = codexString(turn['status'], max: 32);
    if (!const {
      'inProgress',
      'completed',
      'interrupted',
      'failed',
    }.contains(status)) {
      _invalid();
    }
    final created = codexMillis(turn['startedAt']);
    final completed = codexMillis(turn['completedAt']);
    final items = codexList(turn['items']);
    itemCount += items.length;
    if (itemCount > 10000) _invalid();

    for (final rawItem in items) {
      final item = codexObject(rawItem);
      final id = codexString(item['id'], max: 256);
      if (!itemIDs.add(id)) _invalid();
      final type = codexString(item['type'], max: 128);
      final parts = <Part>[];
      switch (type) {
        case 'userMessage':
          for (final rawInput in codexList(item['content'], max: 1000)) {
            final input = codexObject(rawInput);
            final inputType = codexString(input['type'], max: 128);
            parts.add(
              inputType == 'text'
                  ? Part(type: 'text', text: _text(input['text']))
                  : Part(
                      type: 'file',
                      filename: 'Codex input (contents excluded)',
                    ),
            );
          }
        case 'agentMessage':
          final phase = item['phase'];
          if (phase != null &&
              phase != 'final_answer' &&
              phase != 'commentary') {
            _invalid();
          }
          final text = _text(item['text']);
          // Older persisted messages have no phase. Their visible text is the
          // only available answer; do not guess whether it was a final answer.
          if (phase == 'commentary') continue;
          if (phase == null) {
            parts.add(
              Part(
                type: 'text',
                text:
                    'Codex did not record whether the following assistant '
                    'message was a final answer.',
              ),
            );
          }
          parts.add(Part(type: 'text', text: text));
        case 'reasoning':
          continue;
        case 'commandExecution':
          final state = _toolStatus(item['status']);
          final exit = item['exitCode'];
          if (exit != null && exit is! int) _invalid();
          final output = item['aggregatedOutput'];
          parts.add(
            Part(
              type: 'tool',
              toolName: 'shell',
              toolState: ToolState(
                status: state == 'completed' && exit != null && exit != 0
                    ? 'error'
                    : state,
                executed: item['status'] != 'declined',
                input: {
                  'command': _text(item['command']),
                  'cwd': codexString(item['cwd']),
                },
                output: output == null ? null : _text(output),
                metadata: {'exitCode': ?exit},
              ),
            ),
          );
        case 'mcpToolCall':
          final state = _callStatus(item['status']);
          final rawResult = item['result'];
          final output = rawResult == null
              ? null
              : _textChunks(codexObject(rawResult)['content'], 'text');
          parts.add(
            Part(
              type: 'tool',
              toolName: 'mcp:${codexString(item['tool'], max: 256)}',
              toolState: ToolState(
                status: state,
                input: _toolInput(item['arguments']),
                output: output,
              ),
            ),
          );
        case 'dynamicToolCall':
          final state = _callStatus(item['status']);
          final success = item['success'];
          if (success != null && success is! bool) _invalid();
          parts.add(
            Part(
              type: 'tool',
              toolName: 'dynamic:${codexString(item['tool'], max: 256)}',
              toolState: ToolState(
                status: success == false ? 'error' : state,
                input: _toolInput(item['arguments']),
                output: item['contentItems'] == null
                    ? null
                    : _textChunks(item['contentItems'], 'inputText'),
              ),
            ),
          );
        case 'functionCallOutput':
          final output = item['output'];
          parts.add(
            Part(
              type: 'tool',
              toolName: 'function:${codexString(item['name'], max: 256)}',
              toolState: ToolState(
                // A persisted output has no success/status field. Do not
                // turn its presence into a successful execution claim.
                status: 'result recorded; success not reported',
                output: output is String
                    ? _text(output)
                    : _textChunks(output, 'input_text'),
              ),
            ),
          );
        case 'collabAgentToolCall':
          final state = item['status'] == 'interrupted'
              ? 'cancelled'
              : _callStatus(item['status']);
          parts.add(
            Part(
              type: 'tool',
              toolName: 'agent:${codexString(item['tool'], max: 256)}',
              toolState: ToolState(status: state),
            ),
          );
        case 'fileChange':
          final state = _toolStatus(item['status']);
          for (final rawChange in codexList(item['changes'], max: 1000)) {
            final change = codexObject(rawChange);
            final path = codexString(change['path']);
            final kind = codexObject(change['kind']);
            final operation = codexString(kind['type'], max: 32);
            if (!const {'add', 'delete', 'update'}.contains(operation)) {
              _invalid();
            }
            final movePath = operation == 'update' && kind['move_path'] != null
                ? codexString(kind['move_path'])
                : null;
            // Only paths and the apply outcome are exported. In particular,
            // neither diff text nor arbitrary change metadata enters a record.
            for (final changedPath in {path, ?movePath}) {
              parts.add(
                Part(
                  type: 'tool',
                  toolName: 'edit_file',
                  toolState: ToolState(
                    status: state,
                    executed: item['status'] != 'declined',
                    input: {'path': changedPath},
                    output:
                        'Codex file change ($operation): ${item['status']}.',
                  ),
                ),
              );
            }
          }
          if (parts.isEmpty) {
            parts.add(
              Part(
                type: 'text',
                text: 'Codex reported a file-change step with no paths.',
              ),
            );
          }
        case 'plan':
          parts.add(
            Part(
              type: 'text',
              text: 'Plan reported by Codex:\n${_text(item['text'])}',
            ),
          );
        case 'contextCompaction':
          parts.add(Part(type: 'v2:compaction'));
        default:
          parts.add(
            Part(
              type: 'text',
              text:
                  'Codex recorded an unsupported item. Its contents are '
                  'excluded from this handoff.',
            ),
          );
      }
      add(
        MessageWithParts(
          info: MessageInfo(
            id: id,
            sessionID: threadID,
            role: type == 'userMessage' ? 'user' : 'assistant',
            providerID: type == 'userMessage' ? null : 'codex',
            time: MsgTime(created: created, completed: completed),
          ),
          parts: parts,
        ),
      );
    }
    // Turn errors can exist without an assistant item. A fixed-copy notice
    // preserves that state without ever copying the server error body.
    if (status == 'failed' ||
        status == 'interrupted' ||
        status == 'inProgress') {
      add(
        MessageWithParts(
          info: MessageInfo(
            id: 'handoff:turn:$turnID',
            sessionID: threadID,
            role: 'assistant',
            providerID: 'codex',
            errorText: status == 'failed'
                ? 'The Codex turn failed. Check the project state before retrying.'
                : null,
          ),
          parts: status == 'failed'
              ? const []
              : [
                  Part(
                    type: 'text',
                    text: status == 'interrupted'
                        ? 'The Codex turn was interrupted before completion.'
                        : 'The Codex turn was still in progress when read.',
                  ),
                ],
        ),
      );
    }
  }
  return result;
}

String _text(Object? value) =>
    codexString(value, max: 1024 * 1024, empty: true);

String _toolStatus(Object? value) => switch (value) {
  'inProgress' => 'running',
  'completed' => 'completed',
  'failed' => 'error',
  'declined' => 'cancelled',
  _ => _invalid(),
};

String _callStatus(Object? value) => switch (value) {
  'inProgress' => 'running',
  'completed' => 'completed',
  'failed' => 'error',
  _ => _invalid(),
};

/// Tool argument JSON may be a scalar or a nested object. Copy only known
/// command/location strings; URLs, credentials and arbitrary metadata are never
/// serialized. The common writer redacts these strings before shortening them.
Map<String, dynamic> _toolInput(Object? arguments) {
  if (arguments is! Map<String, dynamic>) return const {};
  return {
    for (final key in const [
      'command',
      'cmd',
      'filePath',
      'file_path',
      'path',
      'cwd',
      'workdir',
    ])
      if (arguments[key] is String) key: _text(arguments[key]),
  };
}

/// Retain only explicit text chunks, never structured data, resource bodies,
/// encrypted contents or media URLs. Bound before concatenation, without
/// truncating a token that the common redactor must see whole.
String _textChunks(Object? rawChunks, String textType) {
  final text = <String>[];
  var characters = 0;
  var omitted = false;
  for (final raw in codexList(rawChunks, max: 1000)) {
    if (raw is! Map<String, dynamic> || raw['type'] != textType) {
      omitted = true;
      continue;
    }
    final chunk = _text(raw['text']);
    characters += chunk.length + 1;
    if (characters > 1024 * 1024) _invalid();
    text.add(chunk);
  }
  if (omitted) text.add('Non-text result content excluded.');
  return text.join('\n');
}

Never _invalid() => throw CodexFailure(CodexFailureKind.invalidResponse);
