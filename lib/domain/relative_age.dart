import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';

/// The one wording for "how long ago" everywhere in the app: "Just now",
/// "5 min ago", "2h ago", "Yesterday", "3d ago", then a short date.
///
/// [age] is the distance to now; [at] is the moment itself, used only for
/// the short date once the age passes a week. Without [l10n] the English
/// words are used (tests, notification copy).
String relativeAgeLabel(Duration age, {DateTime? at, AppLocalizations? l10n}) {
  final safe = age.isNegative ? Duration.zero : age;
  if (safe.inMinutes < 1) return l10n?.e7WorkspaceJustNow ?? 'Just now';
  if (safe.inHours < 1) {
    return l10n?.e7WorkspaceMinutesAgo(safe.inMinutes) ??
        '${safe.inMinutes} min ago';
  }
  if (safe.inDays < 1) {
    return l10n?.e7WorkspaceHoursAgo(safe.inHours) ?? '${safe.inHours}h ago';
  }
  if (safe.inDays < 2) return l10n?.e7WorkspaceYesterday ?? 'Yesterday';
  if (safe.inDays < 7 || at == null) {
    return l10n?.e7WorkspaceDaysAgo(safe.inDays) ?? '${safe.inDays}d ago';
  }
  return shortDateLabel(at, localeName: l10n?.localeName);
}

/// A short calendar date ("Sep 19", or "Sep 19, 2025" in another year).
String shortDateLabel(DateTime at, {String? localeName, DateTime? now}) {
  final local = at.toLocal();
  final sameYear = local.year == (now ?? DateTime.now()).year;
  try {
    final format = sameYear
        ? DateFormat.MMMd(localeName)
        : DateFormat.yMMMd(localeName);
    return format.format(local);
  } on Exception {
    final format = sameYear
        ? DateFormat.MMMd('en_US')
        : DateFormat.yMMMd('en_US');
    return format.format(local);
  }
}
