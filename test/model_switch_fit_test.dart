import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/model_switch_fit.dart';
import 'package:opencode_mobile/domain/models.dart';
import 'package:opencode_mobile/domain/server_gateway.dart';

CatalogModel _model({
  bool attachments = true,
  bool tools = true,
  int contextLimit = 200000,
}) => CatalogModel(
  id: 'target',
  providerID: 'provider',
  name: 'Target',
  enabled: true,
  status: 'active',
  contextLimit: contextLimit,
  outputLimit: 32000,
  reasoning: true,
  attachments: attachments,
  tools: tools,
  variants: const [],
);

MessageWithParts _message(String role, List<Part> parts) => MessageWithParts(
  info: MessageInfo(id: 'm${parts.length}$role', sessionID: 's', role: role),
  parts: parts,
);

void main() {
  test('a text-only model is flagged for a conversation holding images', () {
    final messages = [
      _message('user', [
        Part(type: 'text', text: 'look'),
        Part(type: 'file', mime: 'image/png', url: 'file:///a.png'),
        Part(type: 'file', mime: 'image/jpeg', url: 'file:///b.jpg'),
      ]),
    ];
    final caveats = ModelSwitchFit.assess(
      target: _model(attachments: false),
      messages: messages,
    );
    expect(caveats, hasLength(1));
    expect(caveats.single.kind, SwitchCaveatKind.images);
    expect(caveats.single.count, 2);
  });

  test('a model without tools is flagged for tool results', () {
    final messages = [
      _message('assistant', [
        Part(type: 'tool', toolName: 'bash'),
        Part(type: 'tool', toolName: 'read'),
      ]),
    ];
    final caveats = ModelSwitchFit.assess(
      target: _model(tools: false),
      messages: messages,
    );
    expect(caveats.single.kind, SwitchCaveatKind.tools);
    expect(caveats.single.count, 2);
  });

  test('a history larger than the new window is flagged', () {
    final caveats = ModelSwitchFit.assess(
      target: _model(contextLimit: 32000),
      messages: const [],
      sessionTokens: 41000,
    );
    expect(caveats.single.kind, SwitchCaveatKind.context);
    expect(caveats.single.tokens, 41000);
    expect(caveats.single.limit, 32000);
  });

  test('a capable model takes everything: no warning', () {
    final messages = [
      _message('user', [
        Part(type: 'file', mime: 'image/png', url: 'file:///a.png'),
      ]),
      _message('assistant', [Part(type: 'tool', toolName: 'bash')]),
    ];
    expect(
      ModelSwitchFit.assess(
        target: _model(),
        messages: messages,
        sessionTokens: 1000,
      ),
      isEmpty,
    );
  });

  test('nothing known about the size means no context warning', () {
    expect(
      ModelSwitchFit.assess(
        target: _model(contextLimit: 0),
        messages: const [],
        sessionTokens: 0,
      ),
      isEmpty,
    );
  });

  test('a fit exactly at the window is not over it', () {
    expect(
      ModelSwitchFit.assess(
        target: _model(contextLimit: 32000),
        messages: const [],
        sessionTokens: 32000,
      ),
      isEmpty,
    );
  });
}
