import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/server_gateway.dart';
import '../../api2/transport.dart';
import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import '../widgets/product_states.dart' show productErrorText;
import '../app_theme.dart';
import '../kit/kit.dart';

/// One editor for the mobile-owned note, never a generic instruction browser
/// (map pages session-note and session-note-discard-dialog).
class SessionNoteScreen extends StatefulWidget {
  final ConnectionController controller;
  final String sessionID;
  const SessionNoteScreen({
    super.key,
    required this.controller,
    required this.sessionID,
  });
  @override
  State<SessionNoteScreen> createState() => _SessionNoteScreenState();
}

class _SessionNoteScreenState extends State<SessionNoteScreen> {
  final _text = TextEditingController();
  late final ConnectionController _boundController;
  late final String _boundSessionID;
  late final int _location;
  SessionNoteReview? _review;
  Object? _reviewRepository;
  Object? _error;

  /// The last failure came from a save or delete (offer Try again), not
  /// from reading the saved note (offer Refresh).
  bool _errorFromSave = false;
  bool _loading = true;
  DateTime? _loadStartedAt;
  bool _saving = false;
  bool _removing = false;

  /// What the last failed write was, so Try again repeats it.
  bool _lastWriteRemoved = false;
  bool _allowLeave = false;
  bool _reviewRefreshed = false;
  int _maxBytes = SessionNoteGateway.maxBytes;
  int _loadGeneration = 0;
  int _saveGeneration = 0;
  bool get _dirty => _text.text != (_review?.value ?? '');
  bool get _sameWidget =>
      identical(widget.controller, _boundController) &&
      widget.sessionID == _boundSessionID;
  bool get _sameLocation =>
      _sameWidget && _boundController.locationRevision == _location;
  bool get _savingForScope =>
      _saving &&
      _sameLocation &&
      identical(_boundController.repository, _reviewRepository);

  @override
  void initState() {
    super.initState();
    _boundController = widget.controller;
    _boundSessionID = widget.sessionID;
    _location = _boundController.locationRevision;
    unawaited(_load());
  }

  Future<void> _load() async {
    if (!_sameLocation) return;
    final loadGeneration = ++_loadGeneration;
    final keepDraft = _review != null;
    setState(() {
      _loading = true;
      _loadStartedAt = DateTime.now();
      _error = null;
    });
    try {
      final review = await _boundController.loadSessionNote(_boundSessionID);
      if (!mounted || !_sameLocation || loadGeneration != _loadGeneration) {
        return;
      }
      setState(() {
        _review = review;
        _reviewRepository = _boundController.repository;
        _reviewRefreshed = keepDraft;
        if (!keepDraft) _text.text = review.value ?? '';
      });
    } catch (error) {
      if (mounted && _sameLocation && loadGeneration == _loadGeneration) {
        setState(() {
          _error = error;
          _errorFromSave = false;
        });
      }
    } finally {
      if (mounted && loadGeneration == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  /// Reads the saved note again as if the editor had just opened: the field
  /// shows what the server holds, with no "saved version" comparison.
  Future<void> _reload() {
    _review = null;
    _reviewRefreshed = false;
    return _load();
  }

  Future<void> _leave({bool Function()? stillTargetsThisEditor}) async {
    if (stillTargetsThisEditor != null && !stillTargetsThisEditor()) return;
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    setState(() => _allowLeave = true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted ||
        (stillTargetsThisEditor != null && !stillTargetsThisEditor()) ||
        route == null ||
        !route.isActive) {
      return;
    }
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  Future<void> _confirmLeave() async {
    if (_savingForScope) return;
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final discard = await showKitConfirm(
      context,
      title: l10n.sessionNoteDiscard,
      body: l10n.sessionNoteDiscardDetail,
      confirmLabel: l10n.sessionNoteDiscardAction,
      cancelLabel: l10n.sessionNoteKeepEditing,
      kind: KitConfirmKind.discard,
      icon: AppIconography.note,
    );
    if (mounted && discard) await _leave();
  }

  Future<void> _save({bool remove = false}) async {
    final review = _review;
    if (_saving || review == null || !_sameLocation) return;
    final saveController = _boundController;
    final saveSessionID = _boundSessionID;
    final saveRepository = saveController.repository;
    final saveGeneration = ++_saveGeneration;
    final previous = review.value;
    bool saveStillTargetsThisEditor() =>
        mounted &&
        saveGeneration == _saveGeneration &&
        identical(_boundController, saveController) &&
        _boundSessionID == saveSessionID &&
        identical(saveController.repository, saveRepository) &&
        _sameLocation;
    setState(() {
      _saving = true;
      _removing = remove;
      _lastWriteRemoved = remove;
      _error = null;
    });
    try {
      await saveController.saveSessionNote(review, remove ? null : _text.text);
      if (!saveStillTargetsThisEditor()) return;
      if (remove) {
        // Delete stays on the page, shows the empty note and offers Undo,
        // which writes the deleted words back (DATA-11: act now, undo is
        // the inverse call).
        _saving = false;
        unawaited(_reload());
        if (previous != null && mounted) _offerUndo(previous);
      } else {
        await _leave(stillTargetsThisEditor: saveStillTargetsThisEditor);
      }
    } catch (error) {
      if (saveStillTargetsThisEditor()) {
        setState(() {
          _error = error;
          _errorFromSave = true;
          if (error is SessionNoteException &&
              error.failure == SessionNoteFailure.tooLarge) {
            _maxBytes = error.maxBytes.clamp(1, SessionNoteGateway.maxBytes);
          }
        });
      }
    } finally {
      if (mounted && saveGeneration == _saveGeneration) {
        setState(() {
          _saving = false;
          _removing = false;
        });
      }
    }
  }

  void _offerUndo(String previous) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final controller = _boundController;
    final sessionID = _boundSessionID;
    showKitUndo(
      context,
      key: const ValueKey('session-note-undo'),
      message: l10n.sessionNoteRemoved,
      onUndo: () async {
        final review = await controller.loadSessionNote(sessionID);
        await controller.saveSessionNote(review, previous);
        if (mounted && _sameLocation) await _reload();
      },
    );
  }

  String _errorText(Object error, AppLocalizations l10n) {
    if (error is Api2Error &&
        (error.statusCode == 401 || error.statusCode == 403)) {
      return l10n.sessionNoteAuthorization;
    }
    if (error is! SessionNoteException) {
      return productErrorText(error, l10n: l10n);
    }
    return switch (error.failure) {
      SessionNoteFailure.unsupported => l10n.sessionNoteUnsupported,
      SessionNoteFailure.changed => l10n.sessionNoteChanged,
      SessionNoteFailure.invalidValue => l10n.sessionNoteInvalid,
      SessionNoteFailure.tooLarge => l10n.sessionNoteTooLarge,
      SessionNoteFailure.busy => l10n.sessionNoteBusy,
    };
  }

  @override
  void dispose() {
    _loadGeneration++;
    _saveGeneration++;
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    return ListenableBuilder(
      listenable: _boundController,
      builder: (context, _) {
        final current =
            _sameLocation &&
            (_review == null ||
                (identical(_boundController.repository, _reviewRepository) &&
                    _boundController.isSessionNoteReviewCurrent(_review!)));
        final loading = _loading && _sameLocation;
        final saving = _savingForScope;
        final review = _review;
        return PopScope(
          canPop: _allowLeave || (!saving && !_dirty),
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) unawaited(_confirmLeave());
          },
          child: KitScreen(
            topBar: KitTopBar(title: l10n.sessionNoteTitle),
            width: KitScreenWidth.list,
            loading: review != null && (loading || saving),
            loadingLabel: saving
                ? (_removing
                      ? l10n.sessionNoteDeleting
                      : l10n.sessionNoteSaving)
                : l10n.sessionNoteLoading,
            bottom: review == null
                ? null
                : _actions(l10n, review, current: current, saving: saving),
            body: review == null
                ? _placeholder(l10n)
                : _editor(context, l10n, review, current: current),
          ),
        );
      },
    );
  }

  /// Before the saved note has been read: waiting, or why it could not be.
  Widget _placeholder(AppLocalizations l10n) {
    final error = _error;
    if (error != null || !_sameLocation) {
      return KitStateView.error(
        key: const ValueKey('session-note-load-failed'),
        title: l10n.sessionNoteLoadFailed,
        body: error == null ? l10n.sessionNoteChanged : _errorText(error, l10n),
        error: error,
        retry: _sameLocation
            ? KitAction(label: l10n.sessionNoteRefresh, onPressed: _load)
            : null,
      );
    }
    return KitStateView(
      key: const ValueKey('session-note-loading'),
      icon: AppIconography.note,
      title: l10n.sessionNoteLoading,
      progress: const KitProgress.waiting(),
      since: _loadStartedAt,
      onSlow: [KitAction(label: l10n.commonRetry, onPressed: _load)],
    );
  }

  Widget _editor(
    BuildContext context,
    AppLocalizations l10n,
    SessionNoteReview review, {
    required bool current,
  }) {
    final tokens = KitTokens.of(context);
    final saving = _savingForScope;
    final bytes = SessionNoteGateway.encodedBytes(_text.text);
    final tooLong = bytes > _maxBytes;
    // The size shows only near the limit (KIT-21); bytes, because the
    // server's limit is in bytes.
    final nearLimit = bytes * 5 >= _maxBytes * 4;
    final error = _error;
    final notice = !current
        ? KitNotice(
            key: const ValueKey('session-note-stale'),
            tone: AppStatusTone.neutral,
            message: l10n.sessionNoteChanged,
            actions: [
              if (_sameLocation && !_loading && !saving)
                KitAction(label: l10n.sessionNoteRefresh, onPressed: _load),
            ],
          )
        : error != null
        ? KitNotice(
            key: const ValueKey('session-note-error'),
            tone: AppStatusTone.failure,
            title: _errorFromSave ? l10n.sessionNoteSaveFailed : null,
            message: _errorText(error, l10n),
            actions: [
              if (_sameLocation && !_loading && !saving)
                _errorFromSave &&
                        !(error is SessionNoteException &&
                            error.failure == SessionNoteFailure.changed)
                    ? KitAction(
                        label: l10n.commonRetry,
                        onPressed: () => _save(remove: _lastWriteRemoved),
                      )
                    : KitAction(
                        label: l10n.sessionNoteRefresh,
                        onPressed: _load,
                      ),
            ],
          )
        : null;
    return ListView(
      padding: KitScreen.padding(
        context,
      ).add(EdgeInsetsDirectional.only(top: tokens.space3)),
      children: [
        KitText(
          l10n.sessionNoteDescription,
          role: KitTextRole.secondary,
          tone: KitTextTone.secondary,
        ),
        SizedBox(height: tokens.space4),
        KitReveal(
          child: notice == null
              ? null
              : Padding(
                  padding: EdgeInsetsDirectional.only(bottom: tokens.space3),
                  child: notice,
                ),
        ),
        if (_reviewRefreshed) ...[
          KitNotice(
            key: const ValueKey('session-note-saved-version'),
            title: l10n.sessionNoteSavedVersion,
            message: review.value ?? l10n.sessionNoteNone,
          ),
          SizedBox(height: tokens.space3),
        ],
        KitField(
          fieldKey: const ValueKey('session-note-editor'),
          label: l10n.sessionNoteFieldLabel,
          controller: _text,
          kind: KitFieldKind.multiline,
          hint: l10n.sessionNoteHint,
          enabled: current && !saving,
          disabledReason: saving
              ? l10n.sessionNoteSaving
              : l10n.sessionNoteFieldLocked,
          helper: nearLimit && !tooLong
              ? l10n.sessionNoteBytes(bytes, _maxBytes)
              : null,
          error: tooLong
              ? l10n.sessionNoteTooLong(bytes - _maxBytes, _maxBytes)
              : null,
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  /// Save note appears once the words differ from the saved note (and
  /// stays while that save runs); Delete saved note whenever one exists.
  /// Null when there is nothing to offer.
  KitActionBlock? _actions(
    AppLocalizations l10n,
    SessionNoteReview review, {
    required bool current,
    required bool saving,
  }) {
    final bytes = SessionNoteGateway.encodedBytes(_text.text);
    final enabled = current && !_loading && !saving;
    final offerSave = _dirty || (saving && !_removing);
    final String? saveReason;
    if (saving) {
      saveReason = _removing
          ? l10n.sessionNoteDeleting
          : l10n.sessionNoteSaving;
    } else if (!current) {
      saveReason = l10n.sessionNoteFieldLocked;
    } else if (_text.text.trim().isEmpty) {
      saveReason = review.value == null
          ? l10n.sessionNoteWriteFirst
          : l10n.sessionNoteEmptyUseDelete;
    } else if (bytes > _maxBytes) {
      saveReason = l10n.sessionNoteTooLarge;
    } else {
      saveReason = null;
    }
    final remove = review.value != null;
    if (!offerSave && !remove) return null;
    return KitActionBlock(
      primary: offerSave
          ? KitAction(
              key: const ValueKey('save-session-note'),
              label: l10n.sessionNoteSave,
              icon: AppIconography.check,
              onPressed: enabled && saveReason == null ? _save : null,
              disabledReason: _loading && !saving ? null : saveReason,
            )
          : null,
      tertiary: [
        if (remove)
          KitAction(
            key: const ValueKey('remove-session-note'),
            label: l10n.sessionNoteRemove,
            icon: AppIconography.delete,
            destructive: true,
            onPressed: enabled ? () => _save(remove: true) : null,
          ),
      ],
    );
  }
}
