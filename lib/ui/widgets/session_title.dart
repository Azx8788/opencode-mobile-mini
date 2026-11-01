import '../../domain/models.dart' show Session;
import '../../domain/session_title_text.dart';
import '../../l10n/app_localizations.dart';

/// The session title as the app presents it: the server's own title, with
/// leaked model markup cut off ([displaySessionTitleText]), the ISO-stamped
/// placeholder collapsed to "New conversation", or [fallback] when the
/// session has no title at all. Every session list and the chat app bar
/// share this so a session reads the same wherever it appears.
String presentedSessionTitle(
  Session? session, {
  String fallback = 'New conversation',
  AppLocalizations? l10n,
}) => presentedSessionTitleText(session?.title, fallback: fallback, l10n: l10n);

/// [presentedSessionTitle] for a title known without its session: a feed
/// row or a saved act that kept only the title. The server's
/// `New session - <ISO time>` placeholder never reaches the screen (F3).
String presentedSessionTitleText(
  String? rawTitle, {
  String fallback = 'New conversation',
  AppLocalizations? l10n,
}) {
  final title = displaySessionTitleText(rawTitle);
  if (title.isEmpty) {
    return fallback == 'New conversation'
        ? l10n?.workspaceNewSession ?? fallback
        : fallback;
  }
  if (isPlaceholderSessionTitle(title)) {
    return l10n?.workspaceNewSession ?? 'New conversation';
  }
  // An ISO time stamp inside a longer title is server bookkeeping too.
  final plain = stripIsoStamp(title);
  if (plain.isEmpty) return l10n?.workspaceNewSession ?? 'New conversation';
  return plain;
}
