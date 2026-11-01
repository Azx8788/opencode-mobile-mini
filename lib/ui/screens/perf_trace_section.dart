import 'package:flutter/material.dart';

import '../../diagnostics/perf_trace.dart';
import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../kit/kit.dart';

/// The "Performance" part of App diagnostics: where time went in this run
/// of the app, from [PerfTrace]. Steps grouped by name (slowest first), the
/// latest steps, and a plain-text report to copy from the first list's
/// header menu (with Clear timings).
///
/// Built from kit parts only (screen-system-1): the steps are [KitRow]s on
/// two [KitRowGroup] panels, each with its time as the trailing value. A
/// step that failed says so in words ("2 failed"); nothing is painted in
/// the error colour, so a slow step never reads as a broken one. The page
/// it sits on is being redesigned as "Report a problem" (slice-P8.2).
class PerfTraceSection extends StatelessWidget {
  const PerfTraceSection({super.key, this.slowest = 12, this.recent = 50});

  /// How many grouped steps and how many recent ones to show.
  final int slowest;
  final int recent;

  @override
  Widget build(BuildContext context) {
    final copy = _copy10n(context);
    final tokens = KitTokens.of(context);
    return ListenableBuilder(
      listenable: PerfTrace.changes,
      builder: (context, _) {
        final stats = PerfTrace.stats().take(slowest).toList();
        final latest = PerfTrace.recent(recent);
        final empty = latest.isEmpty;
        // Copy and Clear act on the timings, so they sit on the first
        // timing list's header, not loose above it (owner rule 2026-09-27).
        final actions = Builder(
          builder: (menuContext) => KitIconButton(
            key: const ValueKey('perf-trace-actions'),
            icon: AppIconography.more,
            size: 20,
            tooltip: copy.perfTraceActions,
            onPressed: () => showKitMenu(
              menuContext,
              semanticsLabel: copy.perfTraceActions,
              items: [
                KitMenuItem(
                  key: const ValueKey('perf-trace-copy'),
                  label: copy.perfTraceCopy,
                  icon: AppIconography.copy,
                  onSelected: () => KitCopy.copy(
                    context,
                    PerfTrace.reportText(),
                    announcement: copy.perfTraceCopied,
                  ),
                ),
                KitMenuItem(
                  key: const ValueKey('perf-trace-clear'),
                  label: copy.perfTraceClearTimings,
                  icon: AppIconography.delete,
                  destructive: true,
                  onSelected: PerfTrace.clear,
                ),
              ],
            ),
          ),
        );
        return Column(
          key: const ValueKey('perf-trace-section'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsetsDirectional.symmetric(
                horizontal: tokens.gutter,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    header: true,
                    child: KitText(
                      copy.perfTraceTitle,
                      role: KitTextRole.headline,
                    ),
                  ),
                  SizedBox(height: tokens.space1),
                  KitText(copy.perfTraceBody, role: KitTextRole.secondary),
                  if (empty) ...[
                    SizedBox(height: tokens.space3),
                    KitText(copy.perfTraceEmpty, role: KitTextRole.secondary),
                  ],
                ],
              ),
            ),
            if (!empty) ...[
              if (stats.isNotEmpty) ...[
                SizedBox(height: tokens.sectionGap),
                KitRowGroup(
                  label: copy.perfTraceSlowest,
                  labelTrailing: actions,
                  leadingIcons: false,
                  children: [
                    for (final stat in stats)
                      KitRow(
                        key: ValueKey('perf-trace-stat-${stat.name}'),
                        title: stat.name,
                        titleMaxLines: 2,
                        supporting: TextSpan(
                          text: [
                            copy.perfTraceStatLine(
                              stat.count,
                              formatMs(stat.p50Ms),
                              formatMs(stat.p95Ms),
                              formatMs(stat.maxMs),
                            ),
                            if (stat.errors > 0)
                              copy.perfTraceFailed(stat.errors),
                          ].join(' · '),
                        ),
                        supportingMaxLines: 2,
                        trailing: KitRowValue(
                          formatMs(stat.p95Ms),
                          chevron: false,
                        ),
                      ),
                  ],
                ),
              ],
              SizedBox(height: tokens.sectionGap),
              KitRowGroup(
                label: copy.perfTraceRecent,
                labelTrailing: stats.isEmpty ? actions : null,
                leadingIcons: false,
                children: [
                  for (final span in latest)
                    KitRow(
                      key: ValueKey('perf-trace-span-${span.id}'),
                      title: span.name,
                      titleMaxLines: 2,
                      supporting: _detail(copy, span),
                      supportingMaxLines: 2,
                      trailing: KitRowValue(
                        span.isMark
                            ? copy.perfTraceAt(
                                formatMs(span.startMicros / 1000),
                              )
                            : formatMs(span.durationMs),
                        chevron: false,
                      ),
                    ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  /// The step's attributes and parent, then "failed" in words when it did.
  static InlineSpan? _detail(AppLocalizations copy, PerfSpan span) {
    final words = [
      for (final entry in span.attrs.entries) '${entry.key}=${entry.value}',
      if (span.parent != null) copy.perfTraceWithin(span.parent!),
      if (span.failed) copy.perfTraceFailed(1),
    ].join(' · ');
    return words.isEmpty ? null : TextSpan(text: words);
  }
}

AppLocalizations _copy10n(BuildContext context) =>
    Localizations.of<AppLocalizations>(context, AppLocalizations) ??
    lookupAppLocalizations(const Locale('en'));
