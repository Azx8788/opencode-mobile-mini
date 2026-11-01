import 'package:flutter/widgets.dart';

import '../../domain/transcript_search.dart';
import '../../l10n/app_localizations.dart';
import '../kit/chat/kit_find_mark.dart';
import '../kit/kit_surface.dart';
import '../kit/kit_text.dart';
import '../kit/kit_tokens.dart';

/// Adds the find mark ([KitFindMark]) at rendering time without reparsing Markdown or changing
/// selection, link recognizers, code content, or clipboard data.
class TranscriptHighlight extends InheritedWidget {
  const TranscriptHighlight({
    super.key,
    required this.query,
    required super.child,
  });
  final String query;
  @override
  bool updateShouldNotify(TranscriptHighlight oldWidget) =>
      query != oldWidget.query;

  static TextSpan decorate(
    BuildContext context,
    TextSpan span, {
    String? source,
  }) {
    final query =
        context
            .dependOnInheritedWidgetOfExactType<TranscriptHighlight>()
            ?.query ??
        '';
    if (query.isEmpty) return span;
    final ranges = literalTranscriptQuery(
      query,
    ).allMatches(span.toPlainText(includeSemanticsLabels: false)).toList();
    if (ranges.isEmpty) return span;
    // Source-only hits (e.g. a link URL) use the active excerpt. Do not add
    // uncounted highlights created solely by removing Markdown delimiters.
    if (source != null &&
        literalTranscriptQuery(query).allMatches(source).length !=
            ranges.length) {
      return span;
    }
    final style = KitFindMark.style(context);
    var offset = 0;
    var rangeIndex = 0;
    InlineSpan visit(InlineSpan value) {
      if (value is! TextSpan) {
        offset += value.toPlainText(includeSemanticsLabels: false).length;
        return value;
      }
      final text = value.text ?? '';
      final start = offset;
      offset += text.length;
      final children = <InlineSpan>[];
      var cursor = 0;
      while (rangeIndex < ranges.length && ranges[rangeIndex].end <= start) {
        rangeIndex++;
      }
      for (
        var index = rangeIndex;
        index < ranges.length && ranges[index].start < offset;
        index++
      ) {
        final range = ranges[index];
        final from = (range.start - start).clamp(0, text.length);
        final to = (range.end - start).clamp(0, text.length);
        if (from >= to) continue;
        if (from > cursor) {
          children.add(
            TextSpan(
              text: text.substring(cursor, from),
              recognizer: value.recognizer,
            ),
          );
        }
        children.add(
          TextSpan(
            text: text.substring(from, to),
            style: style,
            recognizer: value.recognizer,
          ),
        );
        cursor = to;
      }
      if (cursor < text.length) {
        children.add(
          TextSpan(text: text.substring(cursor), recognizer: value.recognizer),
        );
      }
      for (final child in value.children ?? const <InlineSpan>[]) {
        children.add(visit(child));
      }
      return TextSpan(
        style: value.style,
        recognizer: value.recognizer,
        mouseCursor: value.mouseCursor,
        onEnter: value.onEnter,
        onExit: value.onExit,
        semanticsLabel: value.semanticsLabel,
        locale: value.locale,
        spellOut: value.spellOut,
        children: children,
      );
    }

    return visit(span) as TextSpan;
  }
}

/// The active occurrence stays visible where the transcript does not show it
/// in place (a thought, tool data, a file name, far down a very long
/// message): a surface2 panel above the turn with up to five lines around
/// the hit in the active find mark, headed by where it was found ("Tool
/// data") when that is not the message's own words. The count lives in the
/// find bar only.
class TranscriptMatchExcerpt extends StatelessWidget {
  const TranscriptMatchExcerpt({super.key, required this.match});
  final TranscriptMatch match;
  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final from = match.previewStart;
    final to = match.previewEnd;
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final source = switch (match.kind) {
      'reasoning' => l10n.transcriptFindReasoning,
      'tool' => l10n.transcriptFindTool,
      'file' => l10n.transcriptFindFile,
      _ => null,
    };
    String compact(String value) => value.replaceAll(RegExp(r'\s+'), ' ');
    return Padding(
      key: ValueKey('transcript-match-${match.key}'),
      padding: EdgeInsetsDirectional.only(bottom: tokens.space2),
      child: SizedBox(
        width: double.infinity,
        child: KitSurface(
          level: KitSurfaceLevel.surface2,
          padding: KitSurfacePadding.compact,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (source != null) ...[
                KitText(source, role: KitTextRole.label),
                SizedBox(height: tokens.space1),
              ],
              KitText.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text:
                          '${from > 0 ? '…' : ''}${compact(match.text.substring(from, match.start))}',
                    ),
                    TextSpan(
                      text: compact(
                        match.text.substring(match.start, match.end),
                      ),
                      style: KitFindMark.style(context, active: true),
                    ),
                    TextSpan(
                      text:
                          '${compact(match.text.substring(match.end, to))}${to < match.text.length ? '…' : ''}',
                    ),
                  ],
                ),
                role: KitTextRole.secondary,
                tone: KitTextTone.primary,
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
