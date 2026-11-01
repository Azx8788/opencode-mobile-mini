/// A session title as it may be shown: the server's title with any leaked
/// model markup cut off.
///
/// OpenCode names a session from the model's first words, and some models
/// (seen with the AI Team's refinery agent) put a tool call right after
/// them, so the stored title reads
/// `I'll run the startup sequence … prime the merge queue.<tool_call><fu…`.
/// Everything from the first markup marker on is dropped, then the space and
/// the truncation ellipsis the server left behind it. The stored title is
/// never changed; this is for display only, and every place that shows a
/// session title goes through it (see `presentedSessionTitle`).
///
/// Returns the trimmed title, or an empty string when nothing readable is
/// left (the caller shows its own "untitled" wording then).
String displaySessionTitleText(String? title) {
  var value = title?.trim() ?? '';
  if (value.isEmpty) return value;
  var cut = false;
  final lower = value.toLowerCase();
  var at = -1;
  for (final marker in _markers) {
    final index = lower.indexOf(marker);
    if (index >= 0 && (at < 0 || index < at)) at = index;
  }
  if (at >= 0) {
    value = value.substring(0, at);
    cut = true;
  } else {
    // A marker the server's length limit cut in half: `…queue.<tool_ca…`.
    final tail = _truncatedMarker.firstMatch(value);
    if (tail != null) {
      final fragment = tail.group(1)!.toLowerCase();
      if (_markers.any((marker) => marker.startsWith(fragment))) {
        value = value.substring(0, tail.start);
        cut = true;
      }
    }
  }
  if (cut) {
    value = value.replaceFirst(_trailingEllipsis, '');
  }
  return value.trim();
}

/// Where leaked model markup starts: tool-call tags and special tokens.
const _markers = [
  '<tool_call',
  '</tool_call',
  '<tool_use',
  '<function',
  '</function',
  '<|',
];

/// A `<` followed by a marker's first letters, then the ellipsis the server
/// put where it cut the title. Without the ellipsis a trailing `<f` is left
/// alone: it may be the person's own text.
final _truncatedMarker = RegExp(r'(<[A-Za-z_|/]*)\s*(?:…|\.\.\.)\s*$');

final _trailingEllipsis = RegExp(r'[\s…]*(?:\.\.\.)?[\s…]*$');

/// The plain title a forked conversation gets: "Copy of" plus the original.
/// Null when the original has no readable title (the server's dated
/// placeholder), so the caller leaves the fork alone and the display layer
/// shows "New conversation".
String? forkedSessionTitle(String? originalTitle) {
  final title = displaySessionTitleText(originalTitle);
  if (title.isEmpty || isPlaceholderSessionTitle(title)) return null;
  return 'Copy of $title';
}

/// True for the server's own placeholder title, `New session - 2026-09-28T10:00:00Z`
/// (or any title that is only such a dated stamp).
bool isPlaceholderSessionTitle(String title) =>
    _placeholderTitle.hasMatch(title.trim());

final RegExp _placeholderTitle = RegExp(
  r'^(?:(?:New|Child)\s+session|Fork(?:ed)?(?:\s+session)?)?\s*[-:\u2013]?\s*'
  r'\d{4}-\d{2}-\d{2}T[\d:.]+(?:Z|[+-]\d{2}:?\d{2})?$',
  caseSensitive: false,
);

/// [title] with any ISO timestamp cut out, for titles that only contain
/// one in passing ("Fix login 2026-09-28T10:00:00.000Z"). Empty when nothing
/// else is left.
String stripIsoStamp(String title) => title
    .replaceAll(_isoStamp, '')
    .replaceAll(RegExp(r'\s*[-:\u2013]\s*$'), '')
    .replaceAll(RegExp(r'\s{2,}'), ' ')
    .trim();

final RegExp _isoStamp = RegExp(
  r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?',
);
