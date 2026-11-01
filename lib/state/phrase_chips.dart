import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/kit/kit_redact.dart';

/// The moment of a chat a short phrase was sent in, and is offered for again.
enum PhraseMoment {
  /// The agent is busy or streaming.
  working,

  /// The last turn was cut off (output length), stopped, interrupted or
  /// ended in an error.
  stoppedPartway,

  /// The last finished turn edited files.
  finishedWithChanges,

  /// Finished without edits, or a chat with history.
  idle,
}

/// One chip: the words to send, and whether they are a built-in starter
/// rather than something learned from this person.
class PhraseChip {
  const PhraseChip(this.text, {this.starter = false});

  final String text;
  final bool starter;

  @override
  bool operator ==(Object other) =>
      other is PhraseChip && other.text == text && other.starter == starter;

  @override
  int get hashCode => Object.hash(text, starter);
}

/// What the person's own common short phrases are, learned on this phone
/// from what they send ("Continue", "Run the tests"), per server profile.
///
/// Stored as one JSON blob under `oc.phraseChips.<profileId>` so
/// `ProfileStore.profileScopedPreferenceKeys` removes it with the profile.
/// Nothing leaves the phone and no model sees it. A phrase is recorded only
/// when it is short, one line, free of attachments, commands, mentions and
/// anything that looks like a secret; it becomes a chip after
/// [minSends] sends; chips are ranked per moment by count with recency decay.
class PhraseChipStore {
  PhraseChipStore(this._prefs, this.profileId, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// The store for [profileId], one per preferences object, so its parsed
  /// copy is read once and shared by the chat and Settings.
  factory PhraseChipStore.forProfile(
    SharedPreferences prefs,
    String profileId,
  ) {
    final owners = _shared[prefs] ??= {};
    return owners[profileId] ??= PhraseChipStore(prefs, profileId);
  }

  static final _shared = Expando<Map<String, PhraseChipStore>>();

  /// Bumped after every change (a send learned, Hide, the switch, Show
  /// hidden), so an open chat redraws its row when Settings changes it.
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  /// Stops admission and drains the writes already running, before the
  /// profile deletion sweep, so a chat still open on a deleted server cannot
  /// write its phrases back.
  static Future<void> closeProfile(SharedPreferences prefs, String profileId) {
    final owner = PhraseChipStore.forProfile(prefs, profileId);
    owner._closed = true;
    return owner._pending;
  }

  final SharedPreferences _prefs;
  final String profileId;
  final DateTime Function() _now;
  bool _closed = false;
  Future<void> _pending = Future<void>.value();

  static const maxLength = 40;
  static const maxEntries = 50;
  static const maxHidden = 100;
  static const minSends = 2;
  static const maxChips = 4;

  /// A use counts for half as much after this long.
  static const halfLife = Duration(days: 14);

  /// The device-wide switch (Settings › Conversations › Phrase suggestions).
  /// Not profile data, so it is not named by profile.
  static const enabledKey = 'oc.phraseChips.enabled';

  static String keyFor(String profileId) => 'oc.phraseChips.$profileId';

  static bool enabled(SharedPreferences prefs) =>
      prefs.getBool(enabledKey) ?? true;

  static Future<void> setEnabled(SharedPreferences prefs, bool value) async {
    await prefs.setBool(enabledKey, value);
    changes.value++;
  }

  /// The key phrases are counted under: case-folded, whitespace collapsed,
  /// trailing punctuation trimmed. "Run the tests." and "run the tests" are
  /// one phrase.
  static String normalize(String text) {
    var value = text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    value = value.replaceAll(RegExp(r'[\s.!?,;:…؟،؛]+$'), '');
    return value;
  }

  /// Whether [text] may be remembered at all.
  static bool isRecordable(String text, {bool hasAttachments = false}) {
    if (hasAttachments) return false;
    final value = text.trim();
    if (value.length < 2 || value.length > maxLength) return false;
    if (value.contains('\n') || value.contains('\r')) return false;
    if (value.startsWith('/') || value.startsWith('!')) return false;
    if (value.contains('@')) return false;
    if (normalize(value).isEmpty) return false;
    return !looksSecret(value);
  }

  /// A secret by the app's own detector, or any 20+ character run without
  /// spaces (a key or token pasted on its own).
  static bool looksSecret(String text) {
    if (KitRedact.text(text) != text) return true;
    return RegExp(r'\S{20,}').hasMatch(text);
  }

  /// "Try again" and its kin ask for a redo; while a reply or a command is
  /// still running there is nothing to redo yet, so they are never offered in
  /// the [PhraseMoment.working] moment.
  static bool isRedoPhrase(String text) => const {
    'try again',
    'try that again',
    'try it again',
    'retry',
    'run again',
    'run it again',
    'run that again',
    'do it again',
    'do that again',
  }.contains(normalize(text));

  String get _key => keyFor(profileId);

  String? _cachedRaw;
  _Blob? _cached;

  _Blob _read() {
    final raw = _prefs.getString(_key);
    if (_cached != null && raw == _cachedRaw) return _cached!;
    var blob = _Blob();
    try {
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is Map<String, dynamic>) blob = _Blob.fromJson(decoded);
    } catch (_) {}
    _cachedRaw = raw;
    return _cached = blob;
  }

  Future<void> _write(_Blob blob) async {
    if (_closed) return;
    final raw = jsonEncode(blob.toJson());
    _cachedRaw = raw;
    _cached = blob;
    final write = _prefs.setString(_key, raw);
    _pending = write.then((_) {}, onError: (_) {});
    await write;
    changes.value++;
  }

  /// Counts one send of [text] in [moment]. Returns whether it was kept.
  Future<bool> record(
    String text,
    PhraseMoment moment, {
    bool hasAttachments = false,
  }) async {
    if (_closed || !isRecordable(text, hasAttachments: hasAttachments)) {
      return false;
    }
    final key = normalize(text);
    final blob = _read();
    if (blob.hidden.contains(key)) return false;
    final nowMs = _now().millisecondsSinceEpoch;
    final entry = blob.entries.putIfAbsent(key, () => _Entry(text.trim()));
    entry.text = text.trim();
    entry.total += 1;
    entry.last = nowMs;
    final use = entry.moments.putIfAbsent(moment.name, () => _Use());
    use.count += 1;
    use.last = nowMs;
    if (blob.entries.length > maxEntries) {
      final ranked = blob.entries.entries.toList()
        ..sort((a, b) => a.value.last.compareTo(b.value.last));
      for (final old in ranked.take(blob.entries.length - maxEntries)) {
        blob.entries.remove(old.key);
      }
    }
    await _write(blob);
    return true;
  }

  /// The chips to offer in [moment], best first, at most [limit]: the
  /// moment's [starters] lead ("Continue" after a reply stopped partway is
  /// the likeliest next step), then learned phrases (sent [minSends] times
  /// or more, at least once in this moment). A starter the person has
  /// learned keeps their spelling; one hidden or in [exclude] is left out.
  List<PhraseChip> chipsFor(
    PhraseMoment moment, {
    List<String> starters = const [],
    Set<String> exclude = const {},
    int limit = maxChips,
  }) {
    final blob = _read();
    final skip = {for (final text in exclude) normalize(text)};
    final nowMs = _now().millisecondsSinceEpoch;
    final scored = <(double, int, String, _Entry)>[];
    for (final MapEntry(:key, value: entry) in blob.entries.entries) {
      if (entry.total < minSends) continue;
      if (blob.hidden.contains(key) || skip.contains(key)) continue;
      if (moment == PhraseMoment.working && isRedoPhrase(key)) continue;
      final use = entry.moments[moment.name];
      if (use == null || use.count < 1) continue;
      final ageMs = math.max(0, nowMs - use.last);
      final score =
          use.count * math.pow(0.5, ageMs / halfLife.inMilliseconds).toDouble();
      scored.add((score, use.last, key, entry));
    }
    scored.sort((a, b) {
      final byScore = b.$1.compareTo(a.$1);
      return byScore != 0 ? byScore : b.$2.compareTo(a.$2);
    });
    final chips = <PhraseChip>[];
    final taken = <String>{};
    for (final starter in starters) {
      if (chips.length >= limit) break;
      final key = normalize(starter);
      if (taken.contains(key) ||
          blob.hidden.contains(key) ||
          skip.contains(key)) {
        continue;
      }
      final learned = blob.entries[key];
      chips.add(
        learned != null && learned.total >= minSends
            ? PhraseChip(learned.text)
            : PhraseChip(starter, starter: true),
      );
      taken.add(key);
    }
    for (final (_, _, key, entry) in scored) {
      if (chips.length >= limit) break;
      if (!taken.add(key)) continue;
      chips.add(PhraseChip(entry.text));
    }
    return chips;
  }

  /// Never suggest [text] again (until [showHidden]).
  Future<void> hide(String text) async {
    final key = normalize(text);
    if (key.isEmpty) return;
    final blob = _read();
    blob.hidden.remove(key);
    blob.hidden.add(key);
    while (blob.hidden.length > maxHidden) {
      blob.hidden.remove(blob.hidden.first);
    }
    await _write(blob);
  }

  int get hiddenCount => _read().hidden.length;

  /// "Show hidden phrases": every hidden phrase may be suggested again.
  Future<void> showHidden() async {
    final blob = _read();
    if (blob.hidden.isEmpty) return;
    blob.hidden.clear();
    await _write(blob);
  }

  /// How many phrases have been learned (for tests and diagnostics).
  int get learnedCount => _read().entries.length;
}

class _Use {
  _Use({this.count = 0, this.last = 0});
  int count;
  int last;
}

class _Entry {
  _Entry(this.text);
  String text;
  int total = 0;
  int last = 0;
  final Map<String, _Use> moments = {};
}

class _Blob {
  _Blob();

  /// Insertion-ordered; the oldest hidden phrase goes first when full.
  final Set<String> hidden = {};
  final Map<String, _Entry> entries = {};

  factory _Blob.fromJson(Map<String, dynamic> json) {
    final blob = _Blob();
    final hidden = json['hidden'];
    if (hidden is List) {
      blob.hidden.addAll(hidden.whereType<String>());
    }
    final entries = json['entries'];
    if (entries is Map) {
      for (final MapEntry(:key, :value) in entries.entries) {
        if (key is! String || value is! Map) continue;
        final text = value['t'];
        if (text is! String || text.isEmpty) continue;
        final entry = _Entry(text)
          ..total = (value['n'] as num?)?.toInt() ?? 0
          ..last = (value['l'] as num?)?.toInt() ?? 0;
        final moments = value['m'];
        if (moments is Map) {
          for (final MapEntry(:key, :value) in moments.entries) {
            if (key is! String || value is! Map) continue;
            entry.moments[key] = _Use(
              count: (value['n'] as num?)?.toInt() ?? 0,
              last: (value['l'] as num?)?.toInt() ?? 0,
            );
          }
        }
        blob.entries[key] = entry;
      }
    }
    return blob;
  }

  Map<String, dynamic> toJson() => {
    'v': 1,
    'hidden': hidden.toList(),
    'entries': {
      for (final MapEntry(:key, :value) in entries.entries)
        key: {
          't': value.text,
          'n': value.total,
          'l': value.last,
          'm': {
            for (final MapEntry(key: moment, value: use)
                in value.moments.entries)
              moment: {'n': use.count, 'l': use.last},
          },
        },
    },
  };
}
