/// A navigation request, not a route or widget key. The UI resolves [pageId],
/// reveals [sectionId], then scrolls to and highlights [rowId] when present.
class SettingsSearchTarget {
  const SettingsSearchTarget({
    required this.pageId,
    this.sectionId,
    this.rowId,
  });

  final String pageId;
  final String? sectionId;
  final String? rowId;
}

/// Public, static setting metadata only. Never include profile values, secrets,
/// server responses or user-entered settings in this document.
class SettingsSearchDocument {
  const SettingsSearchDocument({
    required this.id,
    required this.title,
    required this.target,
    this.parent = '',
    this.aliases = '',
  });

  final String id;
  final String title;
  final String parent;

  /// Include both English and Arabic aliases regardless of the display locale.
  final String aliases;
  final SettingsSearchTarget target;
}

/// Shared matcher for Settings and the command palette. Construct from only
/// currently reachable documents; rebuild when capabilities or host state change.
/// No I/O, query history, logging, persistence or navigation side effects.
class SettingsSearchIndex {
  SettingsSearchIndex(Iterable<SettingsSearchDocument> documents)
    : _documents = List.unmodifiable(documents.map(_IndexedSetting.new));

  final List<_IndexedSetting> _documents;

  /// Exact title, exact words/aliases, prefixes, then one-edit typo matches.
  /// Every query word must match. Ties retain catalog order. Empty/punctuation
  /// queries produce no suggestions. Typo matching starts at four characters.
  List<SettingsSearchDocument> search(String query) {
    final words = _words(query);
    if (words.isEmpty) return const [];
    final phrase = words.join(' ');
    final matches = <(int, int, SettingsSearchDocument)>[];
    for (var i = 0; i < _documents.length; i++) {
      final entry = _documents[i];
      var score = 0;
      var matched = true;
      for (final word in words) {
        final cost = entry.cost(word);
        if (cost == null) {
          matched = false;
          break;
        }
        if (cost > score) score = cost;
      }
      if (matched) {
        // A whole title beats an exact alias. Typo matches never outrank
        // literal matches even for multiword input.
        final rank = entry.title == phrase ? 0 : score + 1;
        matches.add((rank, i, entry.document));
      }
    }
    matches.sort((a, b) {
      final rank = a.$1.compareTo(b.$1);
      return rank != 0 ? rank : a.$2.compareTo(b.$2);
    });
    return List.unmodifiable(matches.map((match) => match.$3));
  }
}

class _IndexedSetting {
  _IndexedSetting(this.document)
    : title = _words(document.title).join(' '),
      words = _words(
        '${document.title} ${document.parent} ${document.aliases}',
      ).toSet();

  final SettingsSearchDocument document;
  final String title;
  final Set<String> words;

  int? cost(String query) {
    if (words.contains(query)) return 0;
    if (words.any((word) => word.startsWith(query))) return 1;
    if (query.length >= 4 && words.any((word) => _oneEditApart(query, word))) {
      return 2;
    }
    return null;
  }
}

// Arabic harakat/tatweel and alef variants should not prevent a match. Keep
// meaningful letters (including ta marbuta) intact. Unicode letters/numbers
// allow mixed-language input without indexing punctuation as a query.
List<String> _words(String value) => value
    .toLowerCase()
    .replaceAll(RegExp('[\u0640\u064B-\u065F\u0670]'), '')
    .replaceAll(RegExp('[أإآٱ]'), 'ا')
    .replaceAll('ى', 'ي')
    .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
    .where((word) => word.isNotEmpty)
    .toList();

// Bounded edit distance: insertion, deletion, substitution or adjacent swap.
// Linear work, including for pasted long input; no edit-distance matrix.
bool _oneEditApart(String a, String b) {
  if ((a.length - b.length).abs() > 1) return false;
  var i = 0;
  while (i < a.length && i < b.length && a[i] == b[i]) {
    i++;
  }
  if (i == a.length || i == b.length) return true;
  if (a.length > b.length) return a.substring(i + 1) == b.substring(i);
  if (b.length > a.length) return a.substring(i) == b.substring(i + 1);
  if (a.substring(i + 1) == b.substring(i + 1)) return true;
  return i + 1 < a.length &&
      a[i] == b[i + 1] &&
      a[i + 1] == b[i] &&
      a.substring(i + 2) == b.substring(i + 2);
}
