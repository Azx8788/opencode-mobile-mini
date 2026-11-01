part of '../library_screen.dart';

/// How long the wait on an automatic sign-in pauses between checks when the
/// server answered "still pending" at once (OpenCode 2 answers a status
/// read; OpenCode 1 holds the check open until the person approves), and
/// before it tries again after a check that never got an answer. Tests set
/// it small.
@visibleForTesting
Duration integrationAutoWaitPause = const Duration(seconds: 3);

/// The wait on an automatic sign-in (OpenCode's "headless" ChatGPT and
/// Copilot methods): the server saves the account only while the app holds
/// the callback check open, so the app holds it as soon as the browser
/// opens and finishes the connection itself when it resolves.
extension _IntegrationsAutoWait on _IntegrationsScreenState {
  bool _isAutoOAuth(PendingAuthAttempt entry) =>
      entry.kind == PendingAuthKind.oauth &&
      entry.mode == IntegrationAuthMode.auto;

  /// A sign-in the person can no longer finish: the wait found it gone, or
  /// the server said it failed or expired.
  bool _signInIsEnded(PendingAuthAttempt entry) =>
      entry.expired ||
      _signInEnded.contains(entry.key) ||
      (entry.kind == PendingAuthKind.oauth &&
          (_signInStatus[entry.key] == IntegrationAuthState.expired ||
              _signInStatus[entry.key] == IntegrationAuthState.failed));

  /// An automatic sign-in this screen is (or should be) waiting on.
  bool _signInIsWaiting(PendingAuthAttempt entry) =>
      widget.controller.integrationAuthRecoverySupported &&
      _isAutoOAuth(entry) &&
      !_signInIsEnded(entry);

  /// Picks up the wait of every live automatic sign-in that has none: when
  /// the screen opens and when the app comes back to the front.
  void _attachAutoSignIns() {
    if (!mounted) return;
    final controller = widget.controller;
    if (!controller.integrationAuthRecoverySupported) return;
    for (final entry in controller.pendingIntegrationAuth) {
      if (!_isAutoOAuth(entry) ||
          _signInIsEnded(entry) ||
          _signInWaiting.contains(entry.key)) {
        continue;
      }
      unawaited(
        _waitForAutoSignIn(
          entry,
          _providerName(entry.integrationID, _integrations),
        ),
      );
    }
  }

  Future<bool> _pauseAutoWait() {
    final done = Completer<bool>();
    late final Timer timer;
    timer = Timer(integrationAutoWaitPause, () {
      _waitPauses.remove(timer);
      if (!done.isCompleted) done.complete(mounted);
    });
    _waitPauses[timer] = done;
    return done.future;
  }

  void _endSignIn(PendingAuthAttempt entry) {
    if (!mounted) return;
    _set(() {
      _signInEnded.add(entry.key);
      _signInStatus[entry.key] = IntegrationAuthState.expired;
    });
  }

  /// Holds the sign-in's check open until it resolves. Complete: the
  /// provider is connected with no further tap. Refused by the server (the
  /// attempt is gone after a restart, or the code ran out) or failed: the
  /// sign-in ended. A check that never got an answer is tried again a few
  /// times before the sign-in is called ended.
  Future<void> _waitForAutoSignIn(PendingAuthAttempt entry, String name) async {
    final controller = widget.controller;
    final key = entry.key;
    if (!_signInWaiting.add(key)) return;
    _set(() {});
    final source = _authSourceFor(controller);
    final location = controller.locationRevision;
    bool live() =>
        mounted &&
        source == _authSourceFor(controller) &&
        controller.pendingIntegrationAuth.any((e) => e.key == key);
    var unanswered = 0;
    try {
      while (live()) {
        final started = DateTime.now();
        IntegrationAuthStatus status;
        try {
          status = await controller.recoverIntegrationAuth(
            entry,
            locationRevision: location,
          );
        } catch (_) {
          if (!live()) return;
          final refused = controller.takeIntegrationAuthEndedByServer(entry);
          if (DateTime.now().difference(started) >=
              const Duration(seconds: 8)) {
            // It was really waiting and got cut: that does not count.
            unanswered = 0;
          }
          unanswered++;
          if (refused || unanswered > 3) {
            _endSignIn(entry);
            return;
          }
          if (!await _pauseAutoWait()) return;
          continue;
        }
        if (!mounted) return;
        unanswered = 0;
        switch (status.state) {
          case IntegrationAuthState.pending:
            if (!await _pauseAutoWait()) return;
          case IntegrationAuthState.complete:
            await _finishAutoSignIn(entry, name);
            return;
          case IntegrationAuthState.failed:
          case IntegrationAuthState.expired:
            // Cancelled (the row is gone) while the check was open: what it
            // answers then is not the sign-in expiring.
            if (live()) _endSignIn(entry);
            return;
        }
      }
    } finally {
      _signInWaiting.remove(key);
      if (mounted) _set(() {});
    }
  }

  Future<void> _finishAutoSignIn(PendingAuthAttempt entry, String name) async {
    final controller = widget.controller;
    // The same hot reload a finished sign-in gets (OpenCode 1 needs it to
    // load the new provider); replies still running postpone it.
    if (controller.capabilities.providerRuntimeRefresh) {
      try {
        final repository = await controller.prepareActionRepository();
        await repository?.refreshProviderRuntime();
      } catch (_) {
        // Busy replies or a refused reload do not undo the connection; the
        // model picker loads the provider once the server is idle.
      }
    }
    if (!mounted) return;
    await Future.wait([_load(), controller.refreshCatalog()]);
    if (!mounted) return;
    _set(() {
      _signInCodes.remove(entry.key);
      _signInUrls.remove(entry.key);
    });
    if (controller.unloadedProviderIDs.contains(entry.integrationID)) {
      _sayKeySaved(entry.integrationID, name);
    } else {
      _say(_l10n.e7LibraryIsConnected(name));
    }
  }

  /// Opens the sign-in page. The code, when there is one, is copied first,
  /// so it is on the clipboard when the person gets there.
  Future<bool> _launchAuthorization(Uri destination, String? code) async {
    final l10n = _l10n;
    if (code != null) {
      unawaited(
        KitCopy.copy(
          context,
          code,
          announcement: l10n.integrationsCodeCopied,
          redact: false,
        ),
      );
    }
    final opened = await _openAuthorization(destination);
    if (opened && code != null && mounted) {
      _say(l10n.integrationsCodeCopied, brief: true);
    }
    return opened;
  }

  /// "Open browser again" on a waiting sign-in.
  Future<void> _reopenSignInBrowser(
    PendingAuthAttempt entry,
    String name,
  ) async {
    final url = _signInUrls[entry.key];
    if (url == null) return;
    final opened = await _launchAuthorization(url, _signInCodes[entry.key]);
    if (!mounted) return;
    if (opened) {
      unawaited(_waitForAutoSignIn(entry, name));
    } else {
      _say(
        _l10n.e7LibraryAuthorizationWasNotOpenedThePendingAttempt,
        tone: AppStatusTone.failure,
      );
    }
  }

  Future<void> _copySignInCode(PendingAuthAttempt entry) async {
    final code = _signInCodes[entry.key];
    if (code == null) return;
    await KitCopy.copy(
      context,
      code,
      announcement: _l10n.integrationsCodeCopied,
      redact: false,
    );
  }

  /// "Start again" on an ended sign-in: this phone lets go of the old
  /// attempt and asks the server for a new code.
  Future<void> _startSignInAgain(PendingAuthAttempt entry, String name) async {
    final controller = widget.controller;
    final source = _authSourceFor(controller);
    final location = controller.locationRevision;
    try {
      await controller.forgetIntegrationAuth(entry, locationRevision: location);
    } catch (_) {
      if (mounted) {
        _say(_l10n.pendingAuthFailed, tone: AppStatusTone.failure);
      }
      return;
    }
    if (!mounted || source != _authSourceFor(controller)) return;
    _set(() {
      _signInEnded.remove(entry.key);
      _signInStatus.remove(entry.key);
      _signInCodes.remove(entry.key);
      _signInUrls.remove(entry.key);
    });
    final integration = _integrations
        ?.where((candidate) => candidate.id == entry.integrationID)
        .firstOrNull;
    if (integration == null) {
      _say(_l10n.pendingAuthFailed, tone: AppStatusTone.failure);
      return;
    }
    await _connectIntegration(integration);
  }
}
