import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../kit_layout.dart';
import '../kit_text.dart';
import '../kit_tokens.dart';
import 'kit_markdown.dart';
import 'kit_message.dart';

/// One remembered message of a [KitTranscriptExcerpt]: its words as they
/// were saved (redacted and cut short when saved) and who wrote them.
@immutable
class KitExcerptMessage {
  const KitExcerptMessage({
    required this.text,
    required this.fromPerson,
    this.key,
  });

  /// The saved words, drawn as Markdown.
  final String text;

  /// The person's prompt (a bubble at the end edge); false for the agent's
  /// reply (prose at the start edge).
  final bool fromPerson;

  /// On the message, for tests.
  final Key? key;
}

/// The end of a conversation as it read last time, shown read-only while
/// the live history loads (docs/ux-system/kit-api/KitTranscriptExcerpt.md,
/// speed contract item 2), so a chat opens with its own words instead of
/// placeholder turns.
///
/// The messages are laid out as the transcript lays out prompts and
/// replies, newest at the bottom, with the transcript's gutters and gaps,
/// so the live transcript lands where the excerpt was. A quiet line under
/// the newest message says how old it is ([updated], "Updated 5m ago") and,
/// while [refreshing], that the live history is on its way. Nothing is
/// pressable: no menus, links, copy or selection. A saved excerpt is not
/// the conversation (tools, thoughts, attachments and older turns are left
/// out), so nothing acts on it. Taller than its space, the older messages
/// are cut off at the top. It runs no ticker: the screen's loading bar
/// carries progress.
///
/// The host replaces it with the live transcript as soon as that arrives,
/// including one that is empty or fails to load.
///
/// States: loading.
class KitTranscriptExcerpt extends StatelessWidget {
  const KitTranscriptExcerpt({
    super.key,
    required this.messages,
    required this.updated,
    this.refreshing = true,
    this.bottomClearance = 0,
    this.labelKey,
  });

  /// Oldest first, as the transcript reads.
  final List<KitExcerptMessage> messages;

  /// How old the excerpt is, in words ("Updated 5m ago").
  final String updated;

  /// The live history is loading: the line adds "Refreshing".
  final bool refreshing;

  /// Space kept free under the newest message (a floating composer).
  final double bottomClearance;

  /// On the "Updated …" line, for tests.
  final Key? labelKey;

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final label = refreshing ? l10n.kitLastKnownRefreshing(updated) : updated;
    final newestFirst = messages.reversed.toList(growable: false);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      // Said once: these words are a memory, not the conversation.
      hint: l10n.kitTranscriptExcerptHint,
      child: IgnorePointer(
        child: Center(
          child: ConstrainedBox(
            // The transcript's cap and gutters (VL §5, LAY-5).
            constraints: BoxConstraints(
              maxWidth: KitLayout.paneDetailMaxWidth + 2 * tokens.gutter,
            ),
            child: ListView.builder(
              key: const ValueKey('kit-transcript-excerpt'),
              reverse: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                tokens.gutter,
                tokens.space2,
                tokens.gutter,
                tokens.space2 + bottomClearance,
              ),
              itemCount: newestFirst.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Padding(
                    padding: EdgeInsetsDirectional.only(top: tokens.space1),
                    child: KitText(
                      label,
                      key: labelKey,
                      role: KitTextRole.caption,
                      tone: KitTextTone.tertiary,
                    ),
                  );
                }
                final message = newestFirst[i - 1];
                final body = KitMarkdown(
                  message.text,
                  selectable: false,
                  interactive: false,
                );
                // A prompt is followed by its reply (a turn's inner gap); a
                // reply ends its turn (the gap between turns). The newest
                // has the caption under it instead.
                final gap = i == 1
                    ? 0.0
                    : message.fromPerson
                    ? tokens.space4
                    : tokens.sectionGap;
                return Padding(
                  key: message.key,
                  padding: EdgeInsetsDirectional.only(bottom: gap),
                  child: message.fromPerson
                      ? KitMessage.prompt(body: body)
                      : KitMessage.reply(body: body),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
