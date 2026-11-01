import 'package:flutter/material.dart';

import '../../domain/server_gateway.dart' show Session;
import '../../l10n/app_localizations.dart';
import '../../state/session_inventory_cache.dart';
import '../kit/kit.dart';
import 'relative_time.dart';
import 'session_title.dart';

/// The conversation titles this server listed last time
/// (`ConnectionController.cachedSessionInventory`), shown read-only while
/// the app connects or the live list loads (docs/qa/codex-speed-2026-09-28,
/// contract item 1): the opening frame shows the person's own work instead
/// of a spinner or placeholders.
///
/// Titles only: no running, waiting or pinned marks, no tap, menu or swipe.
/// The rows prove nothing about what exists now, so nothing here acts on
/// them; the live list replaces this as soon as it arrives.
class LastKnownSessions extends StatelessWidget {
  const LastKnownSessions({
    super.key,
    required this.preview,
    this.refreshing = true,
    this.now,
  });

  /// At most this many rows: enough to fill a tall window, without laying
  /// out all of a long list on the opening frame.
  static const maxRows = 24;

  final SessionInventoryPreview preview;

  /// A fresh read is under way (connecting, or the list loading).
  final bool refreshing;

  /// The clock, for tests; the wall clock otherwise.
  final DateTime? now;

  /// "Updated 5m ago" for [fetchedAt].
  static String updatedLabel(
    AppLocalizations l10n,
    DateTime fetchedAt, {
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    if (at.difference(fetchedAt).inMinutes < 1) {
      return l10n.lastKnownUpdatedJustNow;
    }
    return l10n.lastKnownUpdatedAgo(
      relativeTimeLabel(fetchedAt.millisecondsSinceEpoch, now: at, l10n: l10n),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final at = now ?? DateTime.now();
    return KitLastKnown(
      labelKey: const ValueKey('last-known-sessions'),
      updated: updatedLabel(l10n, preview.fetchedAt, now: at),
      refreshing: refreshing,
      rows: [
        for (final session in preview.sessions.take(maxRows))
          KitLastKnownRow(
            key: ValueKey('last-known-session-${session.id}'),
            title: presentedSessionTitle(
              Session(id: session.id, title: session.title),
              fallback: l10n.globalSessionsUntitled,
              l10n: l10n,
            ),
            detail: session.updated > 0
                ? relativeTimeLabel(session.updated, now: at, l10n: l10n)
                : null,
          ),
      ],
    );
  }
}
