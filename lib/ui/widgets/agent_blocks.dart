import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
import '../app_iconography.dart';
import '../kit/kit_copy.dart';
import '../kit/kit_icon.dart';
import '../kit/kit_icon_button.dart';
import '../kit/kit_row.dart';
import '../kit/kit_surface.dart';
import '../kit/kit_text.dart';
import '../kit/kit_tokens.dart';

AppLocalizations _chatL10n(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

/// Rich blocks the agent can emit inside fenced code with a reserved info
/// string. [MarkdownText] recognises the fences `choices`, `checklist` and
/// `command` (case-insensitive) and renders these widgets instead of a code
/// block, so a model can offer tappable options, show progress, or hand the
/// user a command to run locally without any new wire format.
///
/// Kit only (shared-shell-1): rows, icons, text and the copy service all
/// come from lib/ui/kit.
abstract final class AgentBlockKinds {
  static const choices = 'choices';
  static const checklist = 'checklist';
  static const command = 'command';

  static bool matches(String? info) {
    final kind = info?.trim().toLowerCase();
    return kind == choices || kind == checklist || kind == command;
  }
}

/// Carries the current `onChoice` handler down to [AgentChoicesBlock] without
/// baking it into the parsed block widgets, so a fresh closure per rebuild
/// never forces a markdown re-parse during streaming.
class AgentChoiceScope extends InheritedWidget {
  const AgentChoiceScope({
    super.key,
    required this.onChoice,
    required super.child,
  });

  final ValueChanged<String>? onChoice;

  static ValueChanged<String>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AgentChoiceScope>()?.onChoice;

  @override
  bool updateShouldNotify(AgentChoiceScope oldWidget) =>
      onChoice != oldWidget.onChoice;
}

/// ```choices — one option per non-empty line, rendered as one panel of
/// tappable rows. Tapping hands the option text to the nearest
/// [AgentChoiceScope]; without one the text is copied through the kit's copy
/// service, which announces that it can be pasted into the composer.
///
/// Follow-up (P4.1b): this becomes `KitChoiceList` inside
/// `KitRequestCard(kind: choice)` once KitChoiceList is in the kit.
class AgentChoicesBlock extends StatelessWidget {
  const AgentChoicesBlock({super.key, required this.options});

  final List<String> options;

  /// Splits the fence body into options, dropping blanks and list markers.
  static List<String> parse(String body) => body
      .split('\n')
      .map(
        (line) =>
            line.trim().replaceFirst(RegExp(r'^(?:[-*+]|\d+[.)])\s+'), ''),
      )
      .where((line) => line.isNotEmpty)
      .toList();

  Future<void> _select(BuildContext context, String option) async {
    final onChoice = AgentChoiceScope.maybeOf(context);
    if (onChoice != null) {
      onChoice(option);
      return;
    }
    // The agent's own words: copied verbatim, never redacted.
    await KitCopy.copy(
      context,
      option,
      announcement: _chatL10n(context).chatUiCopiedPasteItIntoTheComposer,
      redact: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return const SizedBox.shrink();
    final l10n = _chatL10n(context);
    return KitRowGroup(
      key: const Key('agent-choices-block'),
      leadingIcons: false,
      margin: EdgeInsets.zero,
      children: [
        for (var index = 0; index < options.length; index++)
          Semantics(
            button: true,
            label: l10n.chatUiChooseOption(options[index]),
            excludeSemantics: true,
            child: KitRow(
              key: Key('agent-choice-$index'),
              title: options[index],
              titleMaxLines: 4,
              trailing: const KitIcon(
                AppIconography.forward,
                size: KitIconSize.small,
                tone: KitTextTone.secondary,
              ),
              onTap: () => _select(context, options[index]),
            ),
          ),
      ],
    );
  }
}

/// One line of a ```checklist fence.
class AgentChecklistItem {
  const AgentChecklistItem(this.label, {required this.done});

  final String label;
  final bool done;
}

/// ```checklist — lines starting with `[ ]` or `[x]` render as a read-only
/// checklist. Done items are muted; nothing is struck through so the text
/// stays legible at large text sizes. The mark says done or to do together
/// with the spoken word (STATE-9).
class AgentChecklistBlock extends StatelessWidget {
  const AgentChecklistBlock({super.key, required this.items});

  final List<AgentChecklistItem> items;

  static final _itemPattern = RegExp(r'^(?:[-*+]\s+)?\[([ xX])\]\s*(.*)$');

  static List<AgentChecklistItem> parse(String body) {
    final items = <AgentChecklistItem>[];
    for (final raw in body.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final match = _itemPattern.firstMatch(line);
      if (match == null) {
        items.add(AgentChecklistItem(line, done: false));
        continue;
      }
      items.add(
        AgentChecklistItem(
          match.group(2)!.trim(),
          done: match.group(1)!.toLowerCase() == 'x',
        ),
      );
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final tokens = KitTokens.of(context);
    final l10n = _chatL10n(context);
    return Column(
      key: const Key('agent-checklist-block'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items)
          Padding(
            padding: EdgeInsetsDirectional.only(
              top: tokens.space1,
              bottom: tokens.space1,
            ),
            child: Semantics(
              label:
                  '${item.done ? l10n.modelChoiceDone : l10n.chatUiTodo}: ${item.label}',
              excludeSemantics: true,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  KitIcon(
                    item.done
                        ? AppIconography.checkCircle
                        : AppIconography.radioEmpty,
                    key: Key(
                      item.done ? 'agent-check-done' : 'agent-check-open',
                    ),
                    size: KitIconSize.small,
                    tone: item.done
                        ? KitTextTone.success
                        : KitTextTone.tertiary,
                    growsWithText: true,
                  ),
                  SizedBox(width: tokens.space2),
                  Expanded(
                    child: KitText(
                      item.label,
                      tone: item.done
                          ? KitTextTone.secondary
                          : KitTextTone.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// ```command — each line is a shell command for the user to run on their
/// own machine, in mono with a 48dp copy button. Headed "Run on your
/// computer" so it never reads as something the agent already ran.
///
/// Kit only: a `surface2` block with the code shape, each command as
/// [KitText.mono] (left to right, wrapping at any character), and
/// [KitIconButton.copy], which copies through the kit's copy service and
/// shows a check in place instead of a snackbar (KIT-23).
class AgentCommandBlock extends StatelessWidget {
  const AgentCommandBlock({super.key, required this.commands});

  final List<String> commands;

  static List<String> parse(String body) => body
      .split('\n')
      .map((line) => line.trimRight())
      .where((line) => line.trim().isNotEmpty)
      .toList();

  @override
  Widget build(BuildContext context) {
    if (commands.isEmpty) return const SizedBox.shrink();
    final tokens = KitTokens.of(context);
    final l10n = _chatL10n(context);
    return KitSurface(
      key: const Key('agent-command-block'),
      level: KitSurfaceLevel.surface2,
      shape: KitShape.code,
      padding: KitSurfacePadding.none,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsetsDirectional.only(
              start: tokens.space3,
              top: tokens.space2,
              end: tokens.space3,
            ),
            child: Row(
              children: [
                const KitIcon(
                  AppIconography.terminal,
                  size: KitIconSize.small,
                  tone: KitTextTone.secondary,
                ),
                SizedBox(width: tokens.space2),
                Expanded(
                  child: KitText(
                    l10n.chatUiRunOnYourComputer,
                    role: KitTextRole.caption,
                  ),
                ),
              ],
            ),
          ),
          for (var index = 0; index < commands.length; index++)
            Padding(
              padding: EdgeInsetsDirectional.only(
                start: tokens.space3,
                end: tokens.space1,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: KitText.mono(commands[index], selectable: true),
                  ),
                  KitIconButton.copy(
                    key: Key('agent-command-copy-$index'),
                    text: () => commands[index],
                    tooltip: l10n.handoffCopyCommand,
                    size: 20,
                  ),
                ],
              ),
            ),
          SizedBox(height: tokens.space1),
        ],
      ),
    );
  }
}
