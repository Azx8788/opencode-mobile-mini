import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import '../../state/offline_queue.dart';
import '../../state/profiles.dart';
import '../../state/queued_prompt_move.dart';
import '../app_theme.dart';
import '../kit/kit.dart';
import 'phone_server_card.dart' show serverDisplayName;
import 'product_states.dart';
import 'relative_time.dart';

/// Moves prompts queued for a server the app cannot reach into a
/// conversation on the server it is connected to (slice-queue-move).
///
/// One sheet any surface can open: Servers opens it from a server row, and
/// the conversation's "waiting for other servers" notice can open it too
/// (the chat hook is the chat chain's). The person picks the prompts (all
/// that can move are picked), the conversation (a new one first), sees
/// what goes with the move, and the primary names what happens: "Move 3
/// prompts to Laptop". A move is one queue write, so it happens whole or
/// not at all; a failure keeps the sheet open and says so in plain words,
/// with the technical text only under Details. Done shows the one Undo
/// bar; Undo puts back each prompt that has not started sending.
///
/// Profile isolation: only [source]'s prompts are listed and only the
/// connected server is a destination; nothing moves until the person
/// presses the primary.
///
/// Returns the move, or null when nothing moved (cancelled, no destination).
/// [onProblem] receives an Undo that could not fully put prompts back, in
/// words, for the opening page to show.
Future<QueuedPromptMoveResult?> showQueuedPromptMoveSheet(
  BuildContext context, {
  required ConnectionController connection,
  required ServerProfile source,
  void Function(String message, {String? details})? onProblem,
}) async {
  final l10n = lookupAppLocalizations(Localizations.localeOf(context));
  final destination = connection.queuedPromptMoveDestination;
  if (destination == null || destination.id == source.id) return null;
  final profiles = connection.store.profiles;
  final sourceName = serverDisplayName(source, l10n, among: profiles);
  final destinationName = serverDisplayName(destination, l10n, among: profiles);
  final state = _MoveState(
    connection: connection,
    sourceID: source.id,
    selected: {
      for (final prompt in connection.queuedPromptsForProfile(source.id))
        if (QueuedPromptMove.blockFor(prompt) == null) prompt.id,
    },
  );
  final primary = ValueNotifier<KitAction?>(null);
  var open = true;
  late NavigatorState navigator;

  // Done, with Undo (one bar). Shown from where the sheet was opened, also
  // when the sheet was closed while the move was still being saved.
  void announce(QueuedPromptMoveResult moved) {
    if (!context.mounted) return;
    final total = moved.moved + moved.skipped;
    showKitUndo(
      context,
      key: const ValueKey('queued-move-undo'),
      message: moved.skipped > 0
          ? l10n.queuedMoveDonePartial(moved.moved, total, destinationName)
          : l10n.queuedMoveDone(moved.moved, destinationName),
      onUndo: () async {
        final restored = await connection.undoQueuedPromptMove(moved);
        if (restored == 0) throw const _NothingRestored();
        if (restored < moved.moved) {
          onProblem?.call(
            l10n.queuedMoveUndoPartial(
              moved.moved - restored,
              destinationName,
              sourceName,
            ),
          );
        }
      },
      // The prompts send from the destination's queue once the Undo window
      // has passed, like any queued prompt.
      onCommit: () => unawaited(connection.flushOfflineQueue()),
      onUndoFailed: (error, _) => onProblem?.call(
        error is _NothingRestored
            ? l10n.queuedMoveUndoNone(destinationName)
            : l10n.queuedMoveUndoFailed(destinationName),
        details: error is _NothingRestored ? null : productErrorDetails(error),
      ),
    );
  }

  Future<void> move() async {
    final result = await state.move(l10n, sourceName, destinationName);
    if (!open) state.dispose();
    if (result == null) return;
    if (open) {
      navigator.pop(result);
    } else {
      announce(result);
    }
  }

  void publish() {
    final count = state.movableSelected.length;
    primary.value = KitAction(
      key: const ValueKey('queued-move-confirm'),
      label: l10n.queuedMoveAction(count, destinationName),
      icon: AppIconography.forward,
      working: state.working,
      onPressed: count == 0 || state.working ? null : () => unawaited(move()),
      disabledReason: count == 0 ? l10n.queuedMoveChooseOne : null,
    );
  }

  final listenable = Listenable.merge([state, connection]);
  listenable.addListener(publish);
  publish();
  QueuedPromptMoveResult? result;
  try {
    result = await showKitSheet<QueuedPromptMoveResult>(
      context,
      sheetKey: const ValueKey('queued-move-sheet'),
      title: l10n.queuedMoveTitle,
      subtitle: l10n.queuedMoveSubtitle(sourceName),
      icon: AppIconography.forward,
      height: KitSheetHeight.full,
      primaryListenable: primary,
      secondary: KitAction(
        key: const ValueKey('queued-move-cancel'),
        label: l10n.kitConfirmCancel,
        onPressed: () => navigator.pop(),
      ),
      secondaryDismisses: true,
      body: (sheetContext) {
        navigator = Navigator.of(sheetContext);
        return ListenableBuilder(
          listenable: listenable,
          builder: (context, _) => _MoveBody(
            state: state,
            connection: connection,
            sourceName: sourceName,
            destinationName: destinationName,
          ),
        );
      },
    );
  } finally {
    open = false;
    listenable.removeListener(publish);
    primary.dispose();
    // A move still being saved finishes and announces itself (above).
    if (!state.working) state.dispose();
  }
  if (result != null) announce(result);
  return result;
}

class _NothingRestored implements Exception {
  const _NothingRestored();
}

/// Where a moved prompt goes: [newConversation] or a session ID.
const _newConversation = '';

class _MoveState extends ChangeNotifier {
  _MoveState({
    required this.connection,
    required this.sourceID,
    required Set<String> selected,
  }) : _selected = selected;

  final ConnectionController connection;
  final String sourceID;
  Set<String> _selected;
  String conversation = _newConversation;
  bool working = false;
  String? failure;
  String? failureDetails;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  List<QueuedPrompt> get prompts =>
      connection.queuedPromptsForProfile(sourceID);

  Set<String> get selected => _selected;
  set selected(Set<String> value) {
    _selected = value;
    failure = null;
    notifyListeners();
  }

  void choose(String value) {
    conversation = value;
    failure = null;
    notifyListeners();
  }

  /// The picked prompts that are still waiting and can move.
  List<QueuedPrompt> get movableSelected => [
    for (final prompt in prompts)
      if (_selected.contains(prompt.id) &&
          QueuedPromptMove.blockFor(prompt) == null)
        prompt,
  ];

  Future<QueuedPromptMoveResult?> move(
    AppLocalizations l10n,
    String sourceName,
    String destinationName,
  ) async {
    working = true;
    failure = null;
    failureDetails = null;
    notifyListeners();
    try {
      return await connection.moveQueuedPrompts(
        sourceProfileID: sourceID,
        promptIDs: {for (final prompt in movableSelected) prompt.id},
        sessionID: conversation == _newConversation ? null : conversation,
      );
    } on QueuedPromptMoveException catch (error) {
      failure = switch (error.problem) {
        QueuedPromptMoveProblem.noDestination ||
        QueuedPromptMoveProblem.destinationChanged =>
          l10n.queuedMoveFailedDisconnected(destinationName),
        QueuedPromptMoveProblem.conversationGone =>
          l10n.queuedMoveFailedConversationGone(destinationName),
        QueuedPromptMoveProblem.nothingToMove => l10n.queuedMoveFailedNothing(
          sourceName,
        ),
        QueuedPromptMoveProblem.newConversationFailed =>
          l10n.queuedMoveFailedNewConversation(destinationName),
        QueuedPromptMoveProblem.notSaved => l10n.queuedMoveFailedNotSaved(
          sourceName,
        ),
      };
      failureDetails = error.cause == null
          ? null
          : productErrorDetails(error.cause);
      return null;
    } catch (error) {
      failure = l10n.queuedMoveFailedNotSaved(sourceName);
      failureDetails = productErrorDetails(error);
      return null;
    } finally {
      working = false;
      if (!_disposed) notifyListeners();
    }
  }
}

class _MoveBody extends StatelessWidget {
  const _MoveBody({
    required this.state,
    required this.connection,
    required this.sourceName,
    required this.destinationName,
  });

  final _MoveState state;
  final ConnectionController connection;
  final String sourceName;
  final String destinationName;

  /// How many conversations the picker offers after "New conversation":
  /// the most recent, where a follow-up usually belongs.
  static const _recentConversations = 8;

  @override
  Widget build(BuildContext context) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final tokens = KitTokens.of(context);
    final prompts = state.prompts;
    final movable = state.movableSelected;
    final hidden = movable.where(QueuedPromptMove.hidesSecrets).length;
    final models = connection.catalog == null
        ? null
        : connection.modelAvailable;
    final reset = movable
        .where(
          (prompt) => !QueuedPromptMove.keepsSelection(
            prompt,
            modelAvailable: models,
            agents: connection.agents,
          ),
        )
        .length;
    final sessions = connection
        .sortedSessions()
        .take(_recentConversations)
        .toList();
    final facts = [
      if (hidden > 0)
        KitConsequence(
          l10n.queuedMoveHidesSecrets(hidden),
          key: const ValueKey('queued-move-hidden'),
          mark: KitConsequenceMark.neutral,
        ),
      if (reset > 0)
        KitConsequence(
          l10n.queuedMoveUsesCurrentModel(reset, destinationName),
          key: const ValueKey('queued-move-model'),
          mark: KitConsequenceMark.neutral,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KitReveal(
          key: const ValueKey('queued-move-failure-slot'),
          child: switch (state.failure) {
            final failure? => Padding(
              padding: EdgeInsetsDirectional.only(bottom: tokens.space3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  KitNotice(
                    key: const ValueKey('queued-move-failure'),
                    tone: AppStatusTone.failure,
                    message: failure,
                  ),
                  if (state.failureDetails case final details?)
                    KitDetailsFold(text: details),
                ],
              ),
            ),
            null => null,
          },
        ),
        KitSectionLabel(
          l10n.queuedMovePromptsLabel,
          margin: EdgeInsets.zero,
          gapBefore: 0,
        ),
        KitChoiceList<String>.multi(
          key: const ValueKey('queued-move-prompts'),
          semanticsLabel: l10n.queuedMovePromptsLabel,
          choices: [
            for (final prompt in prompts)
              _promptChoice(l10n, prompt, sourceName),
          ],
          selected: state.selected,
          onChanged: (value) => state.selected = value,
          empty: KitStateView(
            icon: AppIconography.checkCircle,
            title: l10n.queuedMoveNoneLeft(sourceName),
            size: KitStateSize.inline,
          ),
        ),
        SizedBox(height: tokens.sectionGap),
        KitSectionLabel(
          l10n.queuedMoveConversationLabel,
          margin: EdgeInsets.zero,
          gapBefore: 0,
        ),
        KitChoiceList<String>.single(
          key: const ValueKey('queued-move-conversations'),
          semanticsLabel: l10n.queuedMoveConversationLabel,
          actsOnTap: false,
          choices: [
            KitChoice(
              key: const ValueKey('queued-move-new-conversation'),
              value: _newConversation,
              title: l10n.queuedMoveNewConversation,
            ),
            for (final session in sessions)
              KitChoice(
                key: ValueKey('queued-move-conversation-${session.id}'),
                value: session.id,
                title: session.title?.trim().isNotEmpty == true
                    ? session.title!.trim()
                    : l10n.commandUntitledChat,
                supporting: switch (session.time?.updated ??
                    session.time?.created) {
                  final at? => relativeTimeLabel(at, l10n: l10n),
                  null => null,
                },
              ),
          ],
          selected: state.conversation,
          onSelected: state.choose,
        ),
        if (facts.isNotEmpty) ...[
          SizedBox(height: tokens.sectionGap),
          KitConsequences(items: facts),
        ],
      ],
    );
  }

  static KitChoice<String> _promptChoice(
    AppLocalizations l10n,
    QueuedPrompt prompt,
    String sourceName,
  ) {
    final block = QueuedPromptMove.blockFor(prompt);
    final files = prompt.attachments.length;
    return KitChoice(
      key: ValueKey('queued-move-prompt-${prompt.id}'),
      value: prompt.id,
      title: _preview(prompt),
      supporting: [
        l10n.queuedMoveQueuedAt(
          relativeTimeLabel(prompt.createdAt, l10n: l10n),
        ),
        if (files > 0) l10n.queuedMoveFiles(files),
      ].join(' · '),
      enabled: block == null,
      disabledReason: switch (block) {
        QueuedPromptMoveBlock.uncertain => l10n.queuedMoveBlockedUncertain(
          sourceName,
        ),
        QueuedPromptMoveBlock.serverFile => l10n.queuedMoveBlockedFile(
          sourceName,
        ),
        QueuedPromptMoveBlock.mentions => l10n.queuedMoveBlockedMentions,
        null => null,
      },
    );
  }

  /// The prompt as a row shows it: secrets masked (KitRedact), on one
  /// paragraph, at most [_previewLength] characters.
  static String _preview(QueuedPrompt prompt) {
    var text = KitRedact.text(prompt.text).replaceAll(RegExp(r'\s+'), ' ');
    text = text.trim();
    if (text.isEmpty && prompt.attachments.isNotEmpty) {
      text = KitRedact.text(
        prompt.attachments.map((a) => a.filename).join(', '),
      );
    }
    final runes = text.runes.toList();
    if (runes.length <= _previewLength) return text;
    return '${String.fromCharCodes(runes.take(_previewLength)).trimRight()}…';
  }

  static const _previewLength = 140;
}
