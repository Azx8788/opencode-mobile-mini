import '../domain/models.dart';
import '../ui/kit/kit_redact.dart';
import 'draft_attachments.dart';
import 'prompt_photos.dart';
import 'saved_prompt_safety.dart';
import 'session_drafts.dart';

/// A retryable recovery result. Failures retain the pending photo for retry.
enum DraftPhotoRecoveryResult {
  nothingPending,
  attached,
  profileRemoved,
  retryRequired,
}

/// Moves a recovered camera result to the draft belonging to its recorded
/// profile and conversation, without requiring the active conversation.
///
/// Run [recover] at bootstrap, before the connection controller loads its draft
/// cache. The owner must serialize this service with draft writes and profile
/// deletion; it cannot invalidate the connection controller's private cache.
/// Repeated calls on this instance are serialized, and restart retries dedupe
/// against the content-addressed attachment already committed to the draft.
class DraftPhotoRecovery {
  DraftPhotoRecovery({
    required this.photos,
    required this.drafts,
    required this.vault,
    required this.profileExists,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final PromptPhotoStore photos;
  final SessionDraftStore drafts;
  final DraftAttachmentVault vault;

  /// Consult current profile ownership, never a captured active profile.
  final bool Function(String profileID) profileExists;
  final int Function() _now;
  Future<void> _tail = Future<void>.value();

  Future<DraftPhotoRecoveryResult> recover() {
    final next = _tail.then((_) => _recover());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  bool _owned(PendingPromptPhoto photo) =>
      photo.profileID.isNotEmpty && profileExists(photo.profileID);

  Future<DraftPhotoRecoveryResult> _removed(PendingPromptPhoto photo) async {
    // Removing a profile always wins over recovery. The application deletion
    // sweep normally already removed these; this also covers deletion while
    // an asynchronous vault or preferences write was pending.
    if (!drafts.readable) return DraftPhotoRecoveryResult.retryRequired;
    if (!await drafts.save(
      SessionDraftStore.withoutProfile(drafts.load(), photo.profileID),
    )) {
      return DraftPhotoRecoveryResult.retryRequired;
    }
    if (!await vault.collect({}, owner: photo.profileID)) {
      return DraftPhotoRecoveryResult.retryRequired;
    }
    await photos.discard(photo.id);
    return DraftPhotoRecoveryResult.profileRemoved;
  }

  void _validatePending(PendingPromptPhoto photo) {
    // Existing recovery writes preserve the origin record. Refuse to rewrite a
    // record containing sensitive routing/path metadata through that API.
    void check(Object? value) {
      if (value is String) savedPromptIdentity(value);
      if (value is Map) value.values.forEach(check);
      if (value is List) value.forEach(check);
    }

    if (photo.sessionID.isEmpty) {
      throw StateError('Recovered photo has no conversation');
    }
    check(photo.toJson());
  }

  Future<DraftPhotoRecoveryResult> _recover() async {
    try {
      var photo = photos.pending;
      if (photo == null) return DraftPhotoRecoveryResult.nothingPending;
      if (!_owned(photo)) return await _removed(photo);
      _validatePending(photo);
      await photos.recoverLostData();
      photo = photos.pending;
      if (photo == null) return DraftPhotoRecoveryResult.nothingPending;
      if (!_owned(photo)) return await _removed(photo);
      _validatePending(photo);
      if (!drafts.readable) return DraftPhotoRecoveryResult.retryRequired;
      final key = SessionDraft.keyFor(photo.profileID, photo.sessionID);
      var current = drafts.load()[key];
      // A prior run may have committed the draft but failed while clearing the
      // pending record. Check before reading its vault, which discard may have
      // already collected when the preference removal failed.
      final recoveredBlob = photo.ref?.blob;
      if (recoveredBlob != null &&
          current?.attachments.any((ref) => ref.blob == recoveredBlob) ==
              true) {
        await photos.discard(photo.id);
        return DraftPhotoRecoveryResult.attached;
      }
      final attachment = await photos.readPending(photo.id);
      if (!_owned(photo)) return await _removed(photo);
      if (KitRedact.containsSecret(attachment.url)) {
        return DraftPhotoRecoveryResult.retryRequired;
      }
      // The existing profile deletion sweep collects draft vault files only
      // after this marker has been committed. Set it before creating payloads.
      if (!(drafts.prefs.getBool('oc.draftAttachmentVault') ?? false) &&
          !await drafts.prefs.setBool('oc.draftAttachmentVault', true)) {
        await drafts.prefs.reload();
        return DraftPhotoRecoveryResult.retryRequired;
      }
      final copied = await vault.store(photo.profileID, [
        PromptAttachment(
          filename: KitRedact.text(attachment.filename),
          mime: KitRedact.text(attachment.mime),
          url: attachment.url,
        ),
      ]);
      if (!_owned(photo)) return await _removed(photo);
      if (!drafts.readable) return DraftPhotoRecoveryResult.retryRequired;
      final all = drafts.load();
      current = all[key];
      final refs = [...?current?.attachments];
      if (!refs.any((ref) => ref.blob == copied.single.blob)) {
        refs.add(copied.single);
      }
      if (refs.length > 5 ||
          refs.fold<int>(0, (sum, ref) => sum + ref.bytes) >
              DraftAttachmentVault.maxDraftBytes) {
        return DraftPhotoRecoveryResult.retryRequired;
      }
      all[key] = sanitizeSessionDraft(
        SessionDraft(
          sessionID: photo.sessionID,
          profileID: photo.profileID,
          text: current?.text ?? '',
          updatedAt: _now(),
          attachments: refs,
          directory: current == null ? photo.directory : current.directory,
          workspace: current == null ? photo.workspace : current.workspace,
        ),
      );
      if (!await drafts.save(all)) {
        return DraftPhotoRecoveryResult.retryRequired;
      }
      if (!_owned(photo)) return await _removed(photo);
      await photos.discard(photo.id);
      return DraftPhotoRecoveryResult.attached;
    } catch (_) {
      // Exceptions can contain paths or credentials. Expose only a typed state.
      return DraftPhotoRecoveryResult.retryRequired;
    }
  }
}
