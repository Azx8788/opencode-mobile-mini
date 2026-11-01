import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The one-time tips of UX plan 5.8 item 4. Each is tied to a real moment and
/// names the benefit available at that moment; none is a tour step.
enum NudgeId {
  /// Third permission request of one kind in a conversation.
  approvals('approvals'),

  /// A run finished after changing files.
  reviewChanges('review-changes'),

  /// A run has kept the person waiting while finished-run notifications can
  /// reach them.
  leaveAndBeTold('leave'),

  /// The conversation fills most of the model's context window.
  compact('compact'),

  /// A second project has been used, so Work is no longer one short list.
  pinConversations('pin');

  const NudgeId(this.wire);

  /// Stable storage and widget-key name (`nudge-<wire>`).
  final String wire;

  static NudgeId? fromWire(Object? value) {
    for (final id in values) {
      if (id.wire == value) return id;
    }
    return null;
  }
}

/// What the registry remembers about one nudge. Plain data.
@immutable
class NudgeRecord {
  const NudgeRecord({
    required this.id,
    required this.shownAt,
    this.dismissed = false,
  });

  final NudgeId id;
  final DateTime shownAt;

  /// True once the person closed the card or took its action. A card that
  /// merely left the screen (its moment passed) stays false.
  final bool dismissed;

  Map<String, Object?> toJson() => {
    'shownAt': shownAt.toUtc().toIso8601String(),
    'dismissed': dismissed,
  };
}

/// The nudge currently on screen, and where.
@immutable
class ActiveNudge {
  const ActiveNudge({required this.id, required this.scope, this.detail = ''});

  final NudgeId id;

  /// The place the moment happened: a conversation id, or
  /// [NudgeRegistry.workScope]. Only that place renders the card.
  final String scope;

  /// A value the sentence needs (the permission kind, the usage percent).
  final String detail;
}

/// Records which nudges were shown and arbitrates the single card slot.
///
/// Rules, all enforced here so no screen can break them:
/// - a nudge is offered at most once ever (until [reset]);
/// - one nudge is active app-wide; an offer made while another is showing is
///   refused without being consumed, so it can fire at its next real trigger;
/// - nothing is offered before the person has received a first reply.
///
/// The app uses the one instance on `ConnectionController.nudges`. A second
/// instance over the same preferences shares what was shown, but not the
/// single active slot, so screens must not build their own.
class NudgeRegistry extends ChangeNotifier {
  NudgeRegistry(this.preferences, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  static const shownKey = 'oc.nudges.shown';

  /// No first-reply flag existed on dev when this was written (UX phase 3b
  /// adds its card concurrently), so the registry keeps its own. It is set
  /// the first time a conversation is seen idle with an assistant reply.
  static const firstReplySeenKey = 'oc.nudges.firstReplySeen';
  static const projectsKey = 'oc.nudges.projects';

  /// [ActiveNudge.scope] of the Work tab.
  static const workScope = 'work';

  /// A third request of one kind is the moment the approvals tip is earned.
  static const permissionRepeatThreshold = 3;

  final SharedPreferences preferences;
  final DateTime Function() _now;

  Map<NudgeId, NudgeRecord>? _records;
  ActiveNudge? _active;

  // Request ids seen per conversation and permission kind, for this app run
  // only. Requests are counted by id so a rebuilt card is not a new request.
  final _permissionRequests = <String, Map<String, Set<String>>>{};

  Map<NudgeId, NudgeRecord> _load() => _records ??= () {
    final records = <NudgeId, NudgeRecord>{};
    try {
      final value = jsonDecode(preferences.getString(shownKey) ?? '{}');
      if (value is Map) {
        for (final entry in value.entries) {
          final id = NudgeId.fromWire(entry.key);
          final data = entry.value;
          if (id == null || data is! Map) continue;
          final shownAt = DateTime.tryParse('${data['shownAt']}');
          if (shownAt == null) continue;
          records[id] = NudgeRecord(
            id: id,
            shownAt: shownAt,
            dismissed: data['dismissed'] == true,
          );
        }
      }
    } catch (_) {
      // Unreadable state means "nothing shown"; a repeated tip is harmless.
    }
    return records;
  }();

  Future<void> _save() async {
    await preferences.setString(
      shownKey,
      jsonEncode({
        for (final record in _load().values) record.id.wire: record.toJson(),
      }),
    );
  }

  ActiveNudge? get active => _active;

  /// The nudge to render at [scope], or null.
  ActiveNudge? activeFor(String scope) =>
      _active?.scope == scope ? _active : null;

  NudgeRecord? record(NudgeId id) => _load()[id];
  bool wasShown(NudgeId id) => _load().containsKey(id);

  bool get firstReplySeen => preferences.getBool(firstReplySeenKey) ?? false;

  Future<void> markFirstReplySeen() async {
    if (firstReplySeen) return;
    await preferences.setBool(firstReplySeenKey, true);
  }

  /// Shows [id] at [scope] when the rules allow it. Returns whether it is now
  /// the active nudge. A refusal because another nudge is showing, or because
  /// the first reply has not arrived, consumes nothing.
  bool offer(NudgeId id, {required String scope, String detail = ''}) {
    if (!firstReplySeen) return false;
    if (_active != null) return false;
    final records = _load();
    if (records.containsKey(id)) return false;
    records[id] = NudgeRecord(id: id, shownAt: _now());
    _active = ActiveNudge(id: id, scope: scope, detail: detail);
    // The in-memory record already prevents a second showing in this run; a
    // failed write can at worst repeat a tip after a restart.
    unawaited(_save().catchError((Object _) {}));
    notifyListeners();
    return true;
  }

  /// The person closed the card or took its action.
  Future<void> dismiss(NudgeId id) async {
    final records = _load();
    final record = records[id];
    final wasActive = _active?.id == id;
    if (wasActive) _active = null;
    if (record != null && !record.dismissed) {
      records[id] = NudgeRecord(
        id: id,
        shownAt: record.shownAt,
        dismissed: true,
      );
    }
    if (wasActive) notifyListeners();
    if (record != null && !record.dismissed) await _save();
  }

  /// The moment passed (the run ended, the screen closed): the card leaves
  /// without being marked dismissed. It still counts as shown.
  void release(NudgeId id) {
    if (_active?.id != id) return;
    _active = null;
    notifyListeners();
  }

  /// Releases whatever is showing at [scope]; called when that place closes
  /// so an unseen card cannot block every other nudge.
  void releaseScope(String scope) {
    final current = _active;
    if (current != null && current.scope == scope) release(current.id);
  }

  /// "Show tips again": every nudge may fire once more at its next trigger.
  /// The first-reply flag, the project count and this run's permission
  /// counts are facts about the person, not about tips, and stay.
  Future<void> reset() async {
    _records = {};
    final hadActive = _active != null;
    _active = null;
    await preferences.remove(shownKey);
    if (hadActive) notifyListeners();
  }

  /// Counts one permission request and returns how many distinct requests of
  /// [kind] this conversation has raised during this app run.
  int notePermissionRequest({
    required String conversation,
    required String kind,
    required String requestID,
  }) {
    final ids = _permissionRequests
        .putIfAbsent(conversation, () => {})
        .putIfAbsent(kind, () => {});
    ids.add(requestID);
    return ids.length;
  }

  /// The most-repeated kind in [conversation] that reached the threshold.
  String? repeatedPermissionKind(String conversation) {
    String? kind;
    var most = permissionRepeatThreshold - 1;
    for (final entry
        in (_permissionRequests[conversation] ?? const {}).entries) {
      if (entry.value.length > most) {
        most = entry.value.length;
        kind = entry.key;
      }
    }
    return kind;
  }

  /// Distinct projects this phone has used, capped at two because the only
  /// question asked is "is this the second one?".
  int get projectsUsed => _projects().length;
  bool get secondProjectUsed => projectsUsed >= 2;

  List<String> _projects() =>
      preferences.getStringList(projectsKey) ?? const [];

  /// Remembers that [directory] on [profileID] was used. Only a truncated
  /// digest is stored: enough to tell two projects apart, nothing readable.
  Future<void> noteProjectUsed({
    required String profileID,
    required String directory,
  }) async {
    if (profileID.isEmpty || directory.isEmpty) return;
    final seen = _projects();
    if (seen.length >= 2) return;
    final digest = sha256
        .convert(utf8.encode('$profileID\n$directory'))
        .toString()
        .substring(0, 16);
    if (seen.contains(digest)) return;
    await preferences.setStringList(projectsKey, [...seen, digest]);
  }
}
