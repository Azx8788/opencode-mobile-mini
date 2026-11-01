import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/kit/kit_redact.dart';
import 'draft_attachments.dart';
import 'prompt_shelf.dart';
import 'saved_prompt_safety.dart';
import 'session_drafts.dart';

enum DraftMigrationBlocker {
  unknownOwner,
  corruptDrafts,
  changedDuringMigration,

  /// Saved prompts has no room ([PromptShelfStore.capacity]); the older
  /// drafts stay where they are until the person makes room and retries.
  full,
  storage,
}

/// No raw exception or draft content is exposed in migration status.
class DraftMigrationResult {
  const DraftMigrationResult({
    this.migrated = 0,
    this.alreadyComplete = false,
    this.blocker,
  });

  /// Verified shelf copies, including copies recovered from an interrupted run.
  /// On a blocked run, these may still have corresponding legacy source rows.
  final int migrated;
  final bool alreadyComplete;
  final DraftMigrationBlocker? blocker;
  bool get complete => blocker == null;
}

/// Moves the older drafts into Saved prompts, once per profile.
///
/// "Older drafts" are the ones saved before drafts recorded their server
/// (`SessionDraft.profileID` is empty). They used to wait on the "Older
/// drafts" page; they now become saved prompts of the profile that runs the
/// migration (the one in use; before this the page showed them under every
/// server anyway). Drafts that name their server are the conversations'
/// live drafts and are never touched.
///
/// Run while ordinary draft writes and profile deletion are paused (the
/// connection controller runs it in its draft lane). Share the
/// attachment-enabled shelf with the Saved prompts controller and use the
/// ordinary draft vault as the source. Concurrent calls on this runner are
/// serialized. Source rows are removed only after their shelf copies are
/// verified, and a copy of the migrated rows is kept under [backupKey] for
/// one release; any failed run can safely be retried after restart.
///
/// A missing attachment file does not hold back the draft's text: the older
/// drafts page could never restore attachments at all, so the prompt moves
/// with what can still be read.
class MigrationRunner {
  MigrationRunner({
    required this.prefs,
    required this.shelf,
    required this.draftVault,
    required this.profileExists,
    SessionDraftStore? draftStore,
  }) : draftStore = draftStore ?? SessionDraftStore(prefs: prefs);

  final SharedPreferences prefs;
  final PromptShelfStore shelf;
  final DraftAttachmentVault draftVault;
  final SessionDraftStore draftStore;
  final bool Function(String profileId) profileExists;
  Future<void> _tail = Future<void>.value();

  static String markerKey(String profileId) =>
      'oc.savedPromptMigrationV1.$profileId';

  /// The migrated older drafts, redacted, as they were before the move.
  /// Kept for one release as a safety net; nothing reads it. Profile-scoped,
  /// so removing the server sweeps it.
  static String backupKey(String profileId) =>
      'oc.olderDraftsBackupV1.$profileId';

  /// The vault owner of older drafts' attachment files.
  static const _legacyOwner = '';

  Future<DraftMigrationResult> runForProfile(String profileId) {
    final next = _tail.then((_) => _run(profileId));
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  void _checkOwner(String profileId) {
    if (profileId.isEmpty ||
        KitRedact.text(profileId) != profileId ||
        !profileExists(profileId)) {
      throw StateError('Draft owner unavailable');
    }
  }

  String _fingerprint(SessionDraft draft) =>
      sha256.convert(utf8.encode(jsonEncode(draft.toJson()))).toString();

  Future<DraftMigrationResult> _run(String profileId) async {
    var migrated = 0;
    try {
      _checkOwner(profileId);
      if (prefs.getBool(markerKey(profileId)) == true) {
        return const DraftMigrationResult(alreadyComplete: true);
      }
      final original = draftStore.load();
      if (!draftStore.readable) {
        return const DraftMigrationResult(
          blocker: DraftMigrationBlocker.corruptDrafts,
        );
      }
      final candidates = original.values
          .where((draft) => draft.profileID.isEmpty)
          .toList();
      final moved = <SessionDraft>[];
      for (final draft in candidates) {
        _checkOwner(profileId);
        final restored = await draftVault.restore(
          _legacyOwner,
          draft.attachments,
          sameLocation: true,
        );
        final prompt = sanitizeSavedPrompt(
          StashedPrompt(
            id: 'legacy-draft-${_fingerprint(draft)}',
            text: draft.text,
            createdAt: draft.updatedAt,
            directory: draft.directory,
            workspace: draft.workspace,
            attachments: restored.attachments,
          ),
        );
        moved.add(draft);
        // Nothing readable is left (only missing attachment files): the
        // backup keeps its record; there is no prompt to save.
        if (prompt.isEmpty) continue;
        final existing = shelf
            .stashes(profileId)
            .where((entry) => entry.id == prompt.id)
            .firstOrNull;
        if (existing == null) {
          if (shelf.stashes(profileId).length >= PromptShelfStore.capacity) {
            return DraftMigrationResult(
              migrated: migrated,
              blocker: DraftMigrationBlocker.full,
            );
          }
          await shelf.stash(
            profileId,
            prompt,
            checkCurrent: () => _checkOwner(profileId),
          );
        }
        // A deterministic ID is a retry hint, not proof of an intact copy.
        final saved = shelf
            .stashes(profileId)
            .firstWhere((entry) => entry.id == prompt.id);
        final recovery = await shelf.restoreAttachments(
          profileId,
          prompt.id,
          sameLocation: true,
          checkCurrent: () => _checkOwner(profileId),
        );
        final verified = StashedPrompt(
          id: saved.id,
          text: saved.text,
          createdAt: saved.createdAt,
          directory: saved.directory,
          workspace: saved.workspace,
          references: saved.references,
          attachments: recovery.attachments,
        );
        if (recovery.unavailable.isNotEmpty ||
            jsonEncode(verified.toJson()) != jsonEncode(prompt.toJson())) {
          return DraftMigrationResult(
            migrated: migrated,
            blocker: DraftMigrationBlocker.storage,
          );
        }
        migrated++;
      }
      _checkOwner(profileId);
      final current = draftStore.load();
      if (!draftStore.readable ||
          jsonEncode(
                current.map((key, draft) => MapEntry(key, draft.toJson())),
              ) !=
              jsonEncode(
                original.map((key, draft) => MapEntry(key, draft.toJson())),
              )) {
        return DraftMigrationResult(
          migrated: migrated,
          blocker: DraftMigrationBlocker.changedDuringMigration,
        );
      }
      if (moved.isNotEmpty) {
        // A retried run finds its earlier rows here; keep each row once.
        final rows = <String>{
          for (final row in _readBackup(profileId) ?? const []) jsonEncode(row),
          for (final draft in moved)
            jsonEncode(sanitizeSessionDraft(draft).toJson()),
        };
        final backup = '[${rows.join(',')}]';
        if (!await prefs.setString(backupKey(profileId), backup)) {
          await prefs.reload();
          return DraftMigrationResult(
            migrated: migrated,
            blocker: DraftMigrationBlocker.storage,
          );
        }
        _checkOwner(profileId);
        final retained = {
          for (final entry in current.entries)
            if (entry.value.profileID.isNotEmpty) entry.key: entry.value,
        };
        if (!await draftStore.save(retained)) {
          return DraftMigrationResult(
            migrated: migrated,
            blocker: DraftMigrationBlocker.storage,
          );
        }
        _checkOwner(profileId);
        // Every older draft is gone from the index, so none of the
        // ownerless attachment files is referenced any more. Drafts without
        // stored files never touch the vault.
        final hadFiles = moved.any(
          (draft) => draft.attachments.any((ref) => ref.blob != null),
        );
        if (hadFiles &&
            !await draftVault.collect(const {}, owner: _legacyOwner)) {
          return DraftMigrationResult(
            migrated: migrated,
            blocker: DraftMigrationBlocker.storage,
          );
        }
      }
      _checkOwner(profileId);
      if (!await prefs.setBool(markerKey(profileId), true)) {
        await prefs.reload();
        return DraftMigrationResult(
          migrated: migrated,
          blocker: DraftMigrationBlocker.storage,
        );
      }
      return DraftMigrationResult(migrated: migrated);
    } catch (_) {
      // SharedPreferences optimistically updates its cache before disk writes.
      try {
        await prefs.reload();
      } catch (_) {}
      return DraftMigrationResult(
        migrated: migrated,
        blocker: profileId.isEmpty || !profileExists(profileId)
            ? DraftMigrationBlocker.unknownOwner
            : DraftMigrationBlocker.storage,
      );
    }
  }

  List<Object?>? _readBackup(String profileId) {
    try {
      final raw = prefs.getString(backupKey(profileId));
      return raw == null ? null : jsonDecode(raw) as List<Object?>;
    } catch (_) {
      return null;
    }
  }
}
