import '../domain/models.dart';
import '../domain/server_gateway.dart';

/// The conversation's context window, read from what the server already
/// reported: each assistant reply carries the tokens it used, and the model
/// catalog knows the window of the exact model that replied.
///
/// Pure functions, no Flutter: the chat top bar, the details sheet, the
/// compact nudge and the chats list all read the same maths.

/// One assistant reply that reported tokens, as a share of the window.
class ContextReply {
  const ContextReply({
    required this.messageID,
    required this.fraction,
    this.afterCompaction = false,
  });

  final String messageID;

  /// Tokens used by this reply over the model's window (not clamped).
  final double fraction;

  /// A compaction notice stands between this reply and the one before it.
  final bool afterCompaction;
}

/// The newest reply's reading, with the numbers the details sheet words.
class ContextReading {
  const ContextReading({
    required this.tokens,
    required this.limit,
    required this.modelName,
    required this.replies,
  });

  final int tokens;
  final int limit;
  final String modelName;

  /// Oldest first; the last one is the reading itself.
  final List<ContextReply> replies;

  double get fraction => tokens / limit;
}

/// Share of the window [tokens] fill; null when either side is unknown.
double? contextFraction(int tokens, int limit) =>
    tokens > 0 && limit > 0 ? tokens / limit : null;

bool _isCompactionNotice(MessageWithParts message) => message.parts.any(
  (part) => part.type == 'v2:compaction' || part.type == 'compaction',
);

CatalogModel? _modelOf(CatalogSnapshot catalog, MessageInfo info) {
  for (final model in catalog.models) {
    if (model.providerID == info.providerID && model.id == info.modelID) {
      return model;
    }
  }
  return null;
}

/// The newest assistant reply that reported tokens, against its model's
/// window. Null when there is no catalog, no such reply, or its model (or
/// window) is unknown: the ring is then absent, never a guess.
ContextReading? contextReadingFor(
  List<MessageWithParts> messages,
  CatalogSnapshot? catalog,
) {
  if (catalog == null) return null;
  final replies = <ContextReply>[];
  var compacted = false;
  int? tokens, limit;
  String? name;
  for (final message in messages) {
    if (_isCompactionNotice(message)) {
      compacted = true;
      continue;
    }
    final info = message.info;
    if (info.role != 'assistant' || info.tokens.total <= 0) continue;
    final model = _modelOf(catalog, info);
    final fraction = model == null
        ? null
        : contextFraction(info.tokens.total, model.contextLimit);
    if (model == null || fraction == null) {
      // The newest reply's model is unknown: no reading, as before.
      tokens = null;
      limit = null;
      continue;
    }
    replies.add(
      ContextReply(
        messageID: info.id,
        fraction: fraction,
        afterCompaction: compacted && replies.isNotEmpty,
      ),
    );
    compacted = false;
    tokens = info.tokens.total;
    limit = model.contextLimit;
    name = model.name;
  }
  if (tokens == null || limit == null || replies.isEmpty) return null;
  return ContextReading(
    tokens: tokens,
    limit: limit,
    modelName: name ?? '',
    replies: List.unmodifiable(replies),
  );
}
