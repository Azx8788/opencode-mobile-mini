import 'dart:convert';

import '../domain/models.dart';
import '../ui/kit/kit_redact.dart';
import 'offline_queue.dart';
import 'queued_prompt_removal.dart';

/// Moving prompts queued for one server into a conversation on the server
/// the app is connected to (slice-queue-move). The controller owns the
/// queue lock and the write; this file only decides what the queue becomes.
///
/// Session IDs never carry across servers, so every moved prompt is given
/// the destination conversation the person picked. A model or agent the
/// destination does not offer is dropped, so the prompt uses the
/// destination's current choice instead of failing there.

/// Why one queued prompt cannot move.
enum QueuedPromptMoveBlock {
  /// Its send started and was never confirmed: it may already be on the
  /// source server. Only the person's review on that server settles it.
  uncertain,

  /// It carries a file that only the source server can open.
  serverFile,

  /// Hiding a password or key in it would shift its agent mentions.
  mentions,
}

/// What stops a whole move. Words for people come from the sheet; nothing
/// here is shown as copy.
enum QueuedPromptMoveProblem {
  /// No connected server can take queued prompts, or it is the source.
  noDestination,

  /// The connected server changed while the move was being prepared.
  destinationChanged,

  /// The picked conversation is no longer on the destination.
  conversationGone,

  /// None of the picked prompts is still waiting and movable.
  nothingToMove,

  /// A new conversation could not be started on the destination.
  newConversationFailed,

  /// The queue could not be read or the write was refused. Nothing moved.
  notSaved,
}

class QueuedPromptMoveException implements Exception {
  const QueuedPromptMoveException(this.problem, {this.cause});
  final QueuedPromptMoveProblem problem;

  /// The underlying failure, for a Details fold only.
  final Object? cause;

  @override
  String toString() => 'Queued prompts were not moved (${problem.name})';
}

/// What a move did, and what its Undo needs.
class QueuedPromptMoveResult {
  const QueuedPromptMoveResult({
    required this.sourceProfileID,
    required this.destinationProfileID,
    required this.sessionID,
    required this.originals,
    required this.skipped,
    required this.selectionsReset,
    required this.newConversation,
  });

  final String sourceProfileID;
  final String destinationProfileID;
  final String sessionID;

  /// The moved prompts exactly as they were queued for the source.
  final List<QueuedPrompt> originals;

  /// Picked prompts that were no longer waiting (sent, removed) or could
  /// not move when the move ran.
  final int skipped;

  /// Moved prompts whose model or agent the destination does not offer.
  final int selectionsReset;

  /// Whether the move started a new conversation.
  final bool newConversation;

  int get moved => originals.length;
}

abstract final class QueuedPromptMove {
  /// Why [prompt] cannot move, or null when it can. Mirrors the refusals of
  /// [QueuedPromptRemoval.moveToSessions], so the sheet can say why before
  /// the person tries.
  static QueuedPromptMoveBlock? blockFor(QueuedPrompt prompt) {
    if (prompt.dispatched) return QueuedPromptMoveBlock.uncertain;
    if (prompt.attachments.any(
      (a) => !{'data', 'https', 'http'}.contains(Uri.tryParse(a.url)?.scheme),
    )) {
      return QueuedPromptMoveBlock.serverFile;
    }
    if (prompt.mentions.isNotEmpty && hidesSecrets(prompt)) {
      return QueuedPromptMoveBlock.mentions;
    }
    return null;
  }

  /// Whether moving [prompt] masks a password or key in its text (a moved
  /// prompt is stored redacted, like every kept queued prompt).
  static bool hidesSecrets(QueuedPrompt prompt) =>
      KitRedact.text(prompt.text) != prompt.text;

  /// Whether the destination offers [prompt]'s model and agent. An unknown
  /// catalog or agent list counts as offered: nothing is dropped on a guess.
  static bool keepsSelection(
    QueuedPrompt prompt, {
    required bool Function(ModelRef model)? modelAvailable,
    required List<AgentInfo> agents,
  }) {
    final model = prompt.model;
    if (model != null && modelAvailable != null && !modelAvailable(model)) {
      return false;
    }
    final agent = prompt.agent;
    if (agent != null &&
        agent.isNotEmpty &&
        agents.isNotEmpty &&
        !agents.any((known) => known.name == agent)) {
      return false;
    }
    return true;
  }

  /// The queue after moving [promptIDs] of [sourceProfileID] into
  /// [sessionID] on [destinationProfileID]. [queue] is the live queue and
  /// must match what [removal] reads from storage; a difference means a
  /// write is still settling and the move is refused rather than guessed.
  static ({List<QueuedPrompt> queue, QueuedPromptMoveResult result}) apply({
    required QueuedPromptRemoval removal,
    required List<QueuedPrompt> queue,
    required String sourceProfileID,
    required String destinationProfileID,
    required Set<String> availableProfileIDs,
    required Set<String> promptIDs,
    required String sessionID,
    required bool newConversation,
    required bool Function(QueuedPrompt prompt) keepsSelection,
  }) {
    final QueuedPromptRemovalPlan plan;
    try {
      plan = removal.inspect(sourceProfileID);
    } catch (error) {
      throw QueuedPromptMoveException(
        QueuedPromptMoveProblem.notSaved,
        cause: error,
      );
    }
    if (_encode(queue) != _encode(removal.queue.load())) {
      throw const QueuedPromptMoveException(QueuedPromptMoveProblem.notSaved);
    }
    final movable = <String, QueuedPrompt>{
      for (final prompt in plan.prompts)
        if (promptIDs.contains(prompt.id) && blockFor(prompt) == null)
          prompt.id: prompt,
    };
    if (movable.isEmpty) {
      throw const QueuedPromptMoveException(
        QueuedPromptMoveProblem.nothingToMove,
      );
    }
    final List<QueuedPrompt> moved;
    try {
      moved = removal.moveToSessions(
        plan,
        destinationProfileID: destinationProfileID,
        availableProfileIDs: availableProfileIDs,
        destinationSessions: {for (final id in movable.keys) id: sessionID},
        only: movable.keys.toSet(),
      );
    } catch (error) {
      throw QueuedPromptMoveException(
        QueuedPromptMoveProblem.notSaved,
        cause: error,
      );
    }
    var reset = 0;
    final next = <QueuedPrompt>[];
    for (final entry in moved) {
      if (movable.containsKey(entry.id) && !keepsSelection(entry)) {
        reset++;
        next.add(_withoutSelection(entry));
      } else {
        next.add(entry);
      }
    }
    return (
      queue: List.unmodifiable(next),
      result: QueuedPromptMoveResult(
        sourceProfileID: sourceProfileID,
        destinationProfileID: destinationProfileID,
        sessionID: sessionID,
        originals: List.unmodifiable(movable.values),
        skipped: promptIDs.length - movable.length,
        selectionsReset: reset,
        newConversation: newConversation,
      ),
    );
  }

  /// The queue after putting a move back (Undo): each moved prompt that is
  /// still waiting, unsent, on the destination returns to the source as it
  /// was. A prompt already sending or sent stays where it is.
  static ({List<QueuedPrompt> queue, int restored}) undo({
    required List<QueuedPrompt> queue,
    required QueuedPromptMoveResult result,
    required String? inFlightID,
  }) {
    final originals = {for (final p in result.originals) p.id: p};
    var restored = 0;
    final next = <QueuedPrompt>[];
    for (final entry in queue) {
      final original = originals[entry.id];
      if (original != null &&
          entry.profileID == result.destinationProfileID &&
          entry.sessionID == result.sessionID &&
          !entry.dispatched &&
          entry.id != inFlightID) {
        restored++;
        next.add(original);
      } else {
        next.add(entry);
      }
    }
    return (queue: List.unmodifiable(next), restored: restored);
  }

  static QueuedPrompt _withoutSelection(QueuedPrompt entry) {
    return QueuedPrompt.fromJson({
      ...entry.toJson(),
      'modelProviderID': null,
      'modelID': null,
      'agent': null,
      'variant': null,
    })!;
  }

  /// Order-free: the live queue is kept oldest first, storage as written.
  static String _encode(List<QueuedPrompt> prompts) => jsonEncode(
    [for (final prompt in prompts) jsonEncode(prompt.toJson())]..sort(),
  );
}
