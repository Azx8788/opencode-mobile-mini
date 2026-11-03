/// What a conversation already contains that another model may not accept.
///
/// A session's model can be changed at any time, before or after a fork.
/// The history stays as it is, so the new provider receives whatever the
/// old one wrote: pictures, tool calls, a transcript near the old model's
/// window. This file answers one question before the next request fails:
/// what, in this conversation, the target model cannot take.
library;

import 'models.dart';
import 'server_gateway.dart';

/// One thing the target model does not accept, with the numbers that make
/// it concrete.
class SwitchCaveat {
  const SwitchCaveat.images(this.count)
    : kind = SwitchCaveatKind.images,
      tokens = 0,
      limit = 0;

  const SwitchCaveat.tools(this.count)
    : kind = SwitchCaveatKind.tools,
      tokens = 0,
      limit = 0;

  const SwitchCaveat.context({required this.tokens, required this.limit})
    : kind = SwitchCaveatKind.context,
      count = 0;

  final SwitchCaveatKind kind;

  /// Pictures (or tool results) in the transcript, for [images] and [tools].
  final int count;

  /// The conversation's tokens and the target model's window, for [context].
  final int tokens;
  final int limit;
}

enum SwitchCaveatKind { images, tools, context }

abstract final class ModelSwitchFit {
  /// The caveats of running [messages] on [target]. Empty when the model
  /// takes everything the conversation holds, or when nothing is known
  /// about it (a catalog that does not describe the model says nothing, and
  /// silence is better than a warning that may be wrong).
  ///
  /// [sessionTokens] is the server's own count for the conversation; 0
  /// skips the context check.
  static List<SwitchCaveat> assess({
    required CatalogModel target,
    required Iterable<MessageWithParts> messages,
    int sessionTokens = 0,
  }) {
    var images = 0;
    var toolResults = 0;
    for (final message in messages) {
      for (final part in message.parts) {
        if (part.type == 'tool') toolResults++;
        if (part.type == 'file' && (part.mime ?? '').startsWith('image/')) {
          images++;
        }
      }
    }
    return [
      if (images > 0 && !target.attachments) SwitchCaveat.images(images),
      if (toolResults > 0 && !target.tools) SwitchCaveat.tools(toolResults),
      if (sessionTokens > 0 &&
          target.contextLimit > 0 &&
          sessionTokens > target.contextLimit)
        SwitchCaveat.context(tokens: sessionTokens, limit: target.contextLimit),
    ];
  }
}
