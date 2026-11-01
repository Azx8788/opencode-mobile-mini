import '../../domain/relative_age.dart';
import '../../l10n/app_localizations.dart';

/// Short relative age for list rows: "Just now", "5 min ago", "2h ago",
/// "Yesterday", "3d ago", then a short date. One wording shared with every
/// other place that shows a time ([relativeAgeLabel]).
String relativeTimeLabel(
  int milliseconds, {
  DateTime? now,
  AppLocalizations? l10n,
}) {
  final date = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  return relativeAgeLabel(
    (now ?? DateTime.now()).difference(date),
    at: date,
    l10n: l10n,
  );
}
