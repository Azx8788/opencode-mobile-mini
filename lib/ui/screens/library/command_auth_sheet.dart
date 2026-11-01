part of '../library_screen.dart';

class _CommandAuthSheet extends StatefulWidget {
  const _CommandAuthSheet({
    required this.controller,
    required this.integration,
    required this.method,
    required this.name,
  });
  final ConnectionController controller;
  final IntegrationInfo integration;
  final IntegrationMethodInfo method;

  /// The provider's presented name, as the sheet's title says it.
  final String name;
  @override
  State<_CommandAuthSheet> createState() => _CommandAuthSheetState();
}

class _CommandAuthSheetState extends State<_CommandAuthSheet> {
  late final Object _source;
  late final int _location;
  String? _attempt;
  IntegrationAuthState? _status;
  bool _busy = false;
  bool _invalidated = false;
  bool _uncertainStart = false;
  String? _error;

  /// The last attempt ended without signing in (it failed or timed out):
  /// the start button reads "Try again".
  bool _ended = false;

  /// The server has had [_answerWait] to finish a started sign-in without
  /// the sheet hearing back: "Check {provider} sign-in now" is offered.
  /// An attempt found already running when the sheet opens offers it at
  /// once.
  bool _checkOffered = false;
  Timer? _answerTimer;
  static const _answerWait = Duration(seconds: 8);
  AppLocalizations get _l10n =>
      lookupAppLocalizations(Localizations.localeOf(context));
  bool get _current =>
      mounted &&
      !_invalidated &&
      _source == _authSourceFor(widget.controller) &&
      widget.controller.isProfileReadable(
        widget.controller.promptShelfProfileID,
      );

  @override
  void initState() {
    super.initState();
    _source = _authSourceFor(widget.controller);
    _location = widget.controller.locationRevision;
    widget.controller.addListener(_changed);
    widget.controller.profileDataChanges.addListener(_changed);
    try {
      _attempt = widget.controller.pendingIntegrationCommand(
        widget.integration.id,
        locationRevision: _location,
      );
      _checkOffered = _attempt != null;
    } catch (_) {
      _invalidated = true;
    }
  }

  /// Waits [_answerWait] after a start before offering the check, so the
  /// person first finishes what the server asks of them.
  void _waitForAnswer() {
    _answerTimer?.cancel();
    _answerTimer = Timer(_answerWait, () {
      if (mounted && _attempt != null) setState(() => _checkOffered = true);
    });
  }

  void _changed() {
    if (mounted && !_current) setState(() => _invalidated = true);
  }

  Future<void> _start() async {
    if (!_current || _busy || _attempt != null || _uncertainStart) return;
    final route = ModalRoute.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    var dispatched = false;
    try {
      // The sheet itself is the question (slice-P3.11a: the separate
      // "Start sign-in on the server?" confirm merged into it): its intro
      // says what starting does and whom it trusts, and Start acts.
      if (!_current || !(route?.isCurrent ?? true)) return;
      dispatched = true;
      final launch = await widget.controller.startIntegrationCommand(
        widget.integration.id,
        widget.method.id!,
        locationRevision: _location,
      );
      if (!_current) return;
      setState(() {
        _attempt = launch.attemptID;
        _status = IntegrationAuthState.pending;
        _checkOffered = false;
        _ended = false;
      });
      _waitForAnswer();
    } catch (_) {
      if (_current) {
        String? recovered;
        try {
          recovered = widget.controller.pendingIntegrationCommand(
            widget.integration.id,
            locationRevision: _location,
          );
        } catch (_) {}
        setState(() {
          _attempt = recovered;
          _checkOffered = recovered != null;
          _uncertainStart = dispatched && recovered == null;
          // Nothing left the phone: say it did not start, and Start is
          // there again. Once it left, the pending or unconfirmed state
          // says what is known instead.
          _error = dispatched ? null : _l10n.commandAuthStartFailed;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _check({bool cancel = false}) async {
    final attempt = _attempt;
    if (!_current || _busy || attempt == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (cancel) {
        await widget.controller.cancelIntegrationCommand(
          widget.integration.id,
          attempt,
          locationRevision: _location,
        );
        if (!_current) return;
        setState(() {
          _attempt = null;
          _status = null;
        });
      } else {
        final result = await widget.controller.integrationCommandStatus(
          widget.integration.id,
          attempt,
          locationRevision: _location,
        );
        if (!_current) return;
        setState(() {
          _status = result.state;
          switch (result.state) {
            case IntegrationAuthState.complete:
              _attempt = null;
            case IntegrationAuthState.failed || IntegrationAuthState.expired:
              // Over on the server: nothing to check or cancel, only to
              // try again.
              _attempt = null;
              _ended = true;
            case IntegrationAuthState.pending:
          }
        });
        if (result.state == IntegrationAuthState.complete) {
          await widget.controller.refreshCatalog();
        }
      }
    } catch (_) {
      if (_current) setState(() => _error = _l10n.commandAuthCheckFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _answerTimer?.cancel();
    widget.controller.removeListener(_changed);
    widget.controller.profileDataChanges.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final tokens = KitTokens.of(context);
    final gap = SizedBox(height: tokens.space3);
    final canStart =
        _attempt == null &&
        !_uncertainStart &&
        _status != IntegrationAuthState.complete;
    final notices = <Widget>[
      if (!_current)
        KitNotice(message: l10n.commandAuthScopeChanged)
      else ...[
        if (_error case final error?)
          KitNotice(tone: AppStatusTone.failure, message: error),
        if (_uncertainStart)
          KitNotice(
            tone: AppStatusTone.failure,
            message: l10n.commandAuthUncertainStart,
            notes: [l10n.uncertainAuthCloseHint],
          ),
        if (widget.controller.pendingAuthPersistenceUncertain)
          KitNotice(
            tone: AppStatusTone.failure,
            message: l10n.pendingAuthSaveUncertain,
          ),
        if (_attempt != null)
          KitNotice(
            tone: AppStatusTone.progress,
            message: l10n.commandAuthPending,
          ),
        if (_status == IntegrationAuthState.complete)
          KitNotice(tone: AppStatusTone.ok, message: l10n.commandAuthComplete),
        if (_status == IntegrationAuthState.failed)
          KitNotice(
            tone: AppStatusTone.failure,
            message: l10n.commandAuthFailed,
          ),
        if (_status == IntegrationAuthState.expired)
          KitNotice(message: l10n.commandAuthExpired),
      ],
    ];
    // The body of showKitSheet: the frame owns the rails and the scroll.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KitText(
          widget.method.label,
          role: KitTextRole.secondary,
          tone: KitTextTone.secondary,
        ),
        SizedBox(height: tokens.space1),
        KitText(l10n.commandAuthSheetIntro(widget.name)),
        if (_current) ...[
          gap,
          KitLoadingBar(loading: _busy, label: l10n.commandAuthSheetWorking),
        ],
        for (final notice in notices) ...[gap, notice],
        if (_current && (canStart || _attempt != null)) ...[
          SizedBox(height: tokens.space5),
          KitActionBlock(
            primary: canStart
                ? KitAction(
                    key: const ValueKey('command-auth-start'),
                    label: _ended || _error != null
                        ? l10n.commandAuthTryAgain
                        : l10n.commandAuthStart,
                    working: _busy,
                    onPressed: _busy ? null : _start,
                  )
                : _checkOffered
                ? KitAction(
                    key: const ValueKey('command-auth-check'),
                    label: l10n.commandAuthCheckNamed(widget.name),
                    working: _busy,
                    onPressed: _busy ? null : () => _check(),
                  )
                : null,
            secondary: _attempt == null
                ? null
                : KitAction(
                    key: const ValueKey('command-auth-cancel'),
                    label: l10n.commandAuthCancel,
                    onPressed: _busy ? null : () => _check(cancel: true),
                  ),
          ),
        ],
      ],
    );
  }
}
