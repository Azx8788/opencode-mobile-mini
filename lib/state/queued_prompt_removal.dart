import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../ui/kit/kit_redact.dart';
import 'offline_queue.dart';
import 'prompt_shelf.dart';

/// Why a server removal kept the server: its queued prompts changed since
/// the person confirmed ([changed]), or they could not be kept as drafts.
/// Nothing was removed in either case.
class QueuedPromptRemovalException implements Exception {
  const QueuedPromptRemovalException({
    required this.changed,
    this.unreadable = false,
  });
  final bool changed;
  final bool unreadable;

  @override
  String toString() => unreadable
      ? 'Queued prompts cannot be read; the server was kept'
      : changed
      ? 'Queued prompts changed; confirm removal again'
      : 'Queued prompts could not be kept; nothing was removed';
}

/// A confirmation snapshot. A changed queue requires a fresh confirmation.
class QueuedPromptRemovalPlan {
  QueuedPromptRemovalPlan._(this.profileID, this._queue);

  final String profileID;
  final List<QueuedPrompt> _queue;

  List<QueuedPrompt> get prompts => List.unmodifiable(
    _queue.where((prompt) => prompt.profileID == profileID),
  );
  int get count => prompts.length;
  int get uncertainCount => prompts.where((prompt) => prompt.dispatched).length;
}

/// Persistence/preparation only: never sends prompts or removes a profile.
///
/// The controller owner MUST suspend queue admission/flush, drain outstanding
/// writes, re-inspect/validate the confirmation, then keep or move and delete
/// within that exclusion. Do not call from a screen beside a live queue writer.
/// A move's returned queue must be durably committed AND installed in the live
/// queue cache before invoking ordinary profile deletion. See the QA UI hook-up.
class QueuedPromptRemoval {
  QueuedPromptRemoval({required this.preferences, required this.queue});

  final SharedPreferences preferences;
  final OfflineQueueStore queue;

  /// Deliberately app-owned: an explicit Keep choice transfers ownership away
  /// from the removed profile. Profile deletion must not sweep this key.
  static const draftsKey = 'oc.keptQueuedPrompts';
  static const capacity = OfflineQueueStore.maxEntries;
  Future<void> _writes = Future<void>.value();
  bool _storageCertain = true;

  List<QueuedPrompt> _readQueue() {
    if (!queue.readable) throw StateError('Queued prompts cannot be read');
    return queue.load();
  }

  QueuedPromptRemovalPlan inspect(String profileID) {
    if (profileID.isEmpty) throw ArgumentError('A source server is required');
    return QueuedPromptRemovalPlan._(profileID, _readQueue());
  }

  /// Also check immediately before the controller's destructive step.
  void validateCurrent(QueuedPromptRemovalPlan plan) {
    if (_encode(_readQueue()) != _encode(plan._queue)) {
      throw StateError('Queued prompts changed; confirm removal again');
    }
  }

  /// Complete saved queue metadata, including the uncertain-send marker.
  /// These records are drafts and must never be automatically re-enqueued.
  List<QueuedPrompt> get keptPrompts {
    if (!_storageCertain) throw StateError('Reload saved queued prompts first');
    try {
      final raw = preferences.getString(draftsKey);
      if (raw == null) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) throw const FormatException();
      final result = <QueuedPrompt>[];
      final identities = <(String, String)>{};
      for (final value in decoded) {
        final prompt = QueuedPrompt.fromJson(value);
        if (prompt == null || !identities.add((prompt.profileID, prompt.id))) {
          throw const FormatException();
        }
        result.add(prompt);
      }
      return List.unmodifiable(result);
    } catch (_) {
      throw StateError('Saved queued prompts cannot be read');
    }
  }

  /// Show in Saved prompts even when no server is selected. Kept records are
  /// independent of the ordinary profile shelf. Use [forgetDraft] to consume.
  /// Attachments must be reviewed with sameLocation=false on another server;
  /// file/content URLs are not portable. Queue model/mentions remain available
  /// via [keptPrompts], but require review before use on a different server.
  List<StashedPrompt> get savedDrafts => List.unmodifiable([
    for (final prompt in keptPrompts)
      StashedPrompt(
        id: draftID(prompt),
        text: prompt.text,
        createdAt: prompt.createdAt,
        attachments: prompt.attachments,
      ),
  ]);

  static String draftID(QueuedPrompt prompt) =>
      'kept-${base64Url.encode(utf8.encode(jsonEncode([prompt.profileID, prompt.id])))}';

  /// Copy before deletion. Retrying the same snapshot is idempotent; a changed
  /// record with the same identity is refused rather than overwriting a draft.
  /// Returns the count protected by this confirmation, including earlier copies.
  Future<int> keepAsDrafts(QueuedPromptRemovalPlan plan) => _serialize(
    () async {
      validateCurrent(plan);
      final next = [...keptPrompts];
      for (final source in plan.prompts) {
        final safe = _redacted(source);
        final existing = next.where(
          (item) => item.profileID == safe.profileID && item.id == safe.id,
        );
        if (existing.isNotEmpty) {
          if (_encode([existing.single]) != _encode([safe])) {
            throw StateError('An earlier saved draft needs review');
          }
        } else {
          next.add(safe);
        }
      }
      if (next.length > capacity ||
          utf8.encode(_encode(next)).length > OfflineQueueStore.maxTotalBytes) {
        throw StateError('Saved prompts are full; nothing was removed');
      }
      if (plan.count != 0) await _save(next);
      validateCurrent(plan);
      return plan.count;
    },
  );

  /// Prepare a replacement queue for the controller's existing serialized writer.
  /// Every source entry needs a session ID belonging to the selected destination;
  /// session IDs, models, and agents are NOT portable between servers. The caller
  /// validates destination session ownership and model/agent compatibility
  /// through its domain gateway first. Existing send selections are preserved.
  /// Uncertain sends and nonportable attachments block a move; Keep is available.
  /// [only] limits the move to those source prompt IDs (the person's pick);
  /// the rest of the plan stays where it is. Null moves the whole plan.
  List<QueuedPrompt> moveToSessions(
    QueuedPromptRemovalPlan plan, {
    required String destinationProfileID,
    required Set<String> availableProfileIDs,
    required Map<String, String> destinationSessions,
    Set<String>? only,
  }) {
    validateCurrent(plan);
    if (destinationProfileID == plan.profileID ||
        !availableProfileIDs.contains(destinationProfileID) ||
        destinationProfileID.isEmpty) {
      throw StateError('Choose another available server');
    }
    final moved = <String, QueuedPrompt>{};
    for (final source in plan.prompts) {
      if (only != null && !only.contains(source.id)) continue;
      final session = destinationSessions[source.id];
      if (source.dispatched || session == null || session.isEmpty) {
        throw StateError('Review delivery and choose a destination session');
      }
      if (source.attachments.any(
        (a) => !{'data', 'https', 'http'}.contains(Uri.tryParse(a.url)?.scheme),
      )) {
        throw StateError('Keep drafts with server-local attachments instead');
      }
      final candidate = QueuedPrompt.fromJson({
        ...source.toJson(),
        'profileID': destinationProfileID,
        'sessionID': session,
        'error': null,
      })!;
      final safe = _redacted(candidate);
      if (safe.text != candidate.text && candidate.mentions.isNotEmpty) {
        throw StateError('Keep this draft and review its agent mentions first');
      }
      moved[source.id] = safe;
    }
    return List.unmodifiable([
      for (final entry in plan._queue) moved[entry.id] ?? entry,
    ]);
  }

  /// Explicit deletion from Saved prompts; a failed write keeps the draft.
  /// Returns the removed record (for Undo), or null when it was not there.
  Future<QueuedPrompt?> forgetDraft(String id) => _serialize(() async {
    final current = keptPrompts;
    final next = current.where((prompt) => draftID(prompt) != id).toList();
    if (next.length == current.length) return null;
    await _save(next);
    return current.firstWhere((prompt) => draftID(prompt) == id);
  });

  /// Puts back a record [forgetDraft] returned (Undo). A record with the same
  /// identity already present is left as it is; a full store refuses.
  Future<void> rememberDraft(QueuedPrompt prompt) => _serialize(() async {
    final current = keptPrompts;
    if (current.any((item) => draftID(item) == draftID(prompt))) return;
    final next = [...current, _redacted(prompt)];
    if (next.length > capacity ||
        utf8.encode(_encode(next)).length > OfflineQueueStore.maxTotalBytes) {
      throw StateError('Saved prompts are full');
    }
    await _save(next);
  });

  /// Recover after a storage failure whose optimistic cache could not reload.
  Future<void> reload() => _serialize(() async {
    _storageCertain = false;
    try {
      await preferences.reload();
      _storageCertain = true;
    } catch (_) {
      throw StateError('Saved queued prompts cannot be reloaded');
    }
  });

  Future<T> _serialize<T>(Future<T> Function() action) {
    final next = _writes.then((_) => action());
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> _save(List<QueuedPrompt> prompts) async {
    try {
      final saved = prompts.isEmpty
          ? await preferences.remove(draftsKey)
          : await preferences.setString(
              draftsKey,
              _encode(prompts.map(_redacted).toList()),
            );
      if (!saved) throw StateError('Write refused');
    } catch (_) {
      // SharedPreferences updates its cache optimistically even on refusal.
      _storageCertain = false;
      try {
        await preferences.reload();
        _storageCertain = true;
      } catch (_) {}
      throw StateError(
        'Could not save queued drafts; do not remove the server',
      );
    }
  }

  static String _encode(List<QueuedPrompt> prompts) =>
      jsonEncode([for (final prompt in prompts) prompt.toJson()]);

  static QueuedPrompt _redacted(QueuedPrompt prompt) {
    Object? redact(Object? value) => switch (value) {
      String text => KitRedact.text(text),
      List values => values.map(redact).toList(),
      Map values => values.map((key, value) => MapEntry(key, redact(value))),
      _ => value,
    };
    final safe = QueuedPrompt.fromJson(redact(prompt.toJson()))!;
    if (safe.id != prompt.id ||
        safe.profileID != prompt.profileID ||
        safe.sessionID != prompt.sessionID) {
      throw StateError('Prompt identity cannot be safely persisted');
    }
    return safe;
  }
}
