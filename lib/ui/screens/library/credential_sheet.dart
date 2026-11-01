part of '../library_screen.dart';

// Local equality token only. No credential material is displayed or persisted.
Object _integrationSourceFor(ConnectionController controller) {
  final profile = controller.profile;
  return (
    controller.promptShelfProfileID,
    profile?.baseUrl,
    profile?.username,
    profile?.password,
    controller.locationRevision,
    controller.repository,
  );
}

enum _CredentialAction { activate, rename, remove }

class _CredentialManagementSheet extends StatefulWidget {
  const _CredentialManagementSheet({
    required this.controller,
    required this.integrationID,
    required this.integrationName,
  });
  final ConnectionController controller;
  final String integrationID;
  final String integrationName;

  @override
  State<_CredentialManagementSheet> createState() =>
      _CredentialManagementSheetState();
}

class _CredentialManagementSheetState
    extends State<_CredentialManagementSheet> {
  late final Object _source;
  late final int _location;
  late int _connectionRevision;
  StreamSubscription<dynamic>? _events;
  IntegrationInfo? _integration;
  bool _invalidated = false;
  bool _loading = false;
  bool _activeKnown = false;
  String? _activeID;
  String? _busyCredential;
  String? _error;
  String? _message;

  ConnectionController get _controller => widget.controller;
  AppLocalizations get _l10n =>
      lookupAppLocalizations(Localizations.localeOf(context));
  bool get _current =>
      mounted &&
      !_invalidated &&
      _source == _integrationSourceFor(_controller) &&
      _controller.isProfileReadable(_controller.promptShelfProfileID);
  bool get _canAct => _current && !_loading && _busyCredential == null;

  @override
  void initState() {
    super.initState();
    _source = _integrationSourceFor(_controller);
    _location = _controller.locationRevision;
    _connectionRevision = _controller.connectionRevision;
    _controller.addListener(_connectionChanged);
    _controller.profileDataChanges.addListener(_connectionChanged);
    _events = _controller.events.listen((event) {
      if (!_current ||
          _controller.status != StreamStatus.connected ||
          _connectionRevision != _controller.connectionRevision ||
          event.type != 'credential.switched') {
        return;
      }
      final properties = event.properties;
      if (properties['integrationID'] != widget.integrationID ||
          !properties.containsKey('credentialID')) {
        return;
      }
      final id = properties['credentialID'];
      if (id != null && (id is! String || id.isEmpty)) return;
      if (_integration == null ||
          (id != null && !_integration!.credentialIDs.contains(id))) {
        return;
      }
      setState(() {
        _activeKnown = true;
        _activeID = id as String?;
        _message = _l10n.credentialActiveUpdated;
      });
    });
    unawaited(_load());
  }

  void _connectionChanged() {
    if (!mounted) return;
    if (!_current) {
      setState(() {
        _invalidated = true;
        _integration = null;
        _activeKnown = false;
        _activeID = null;
        _message = null;
      });
      return;
    }
    if (_controller.status != StreamStatus.connected ||
        _connectionRevision != _controller.connectionRevision) {
      setState(() {
        _connectionRevision = _controller.connectionRevision;
        _activeKnown = false;
        _activeID = null;
        _message = null;
      });
    }
  }

  Future<void> _load() async {
    if (!_current || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repository = _controller.repository;
      if (repository == null ||
          repository is! IntegrationCredentialGateway ||
          !_controller.capabilities.integrationCredentials) {
        throw StateError(
          lookupAppLocalizations(
            Localizations.localeOf(context),
          ).e7LibraryUnavailable,
        );
      }
      final values = await repository.listIntegrations();
      if (!_current) return;
      final matches = values
          .where((value) => value.id == widget.integrationID)
          .toList();
      setState(() {
        _integration = matches.isEmpty ? null : matches.single;
        if (_integration == null) _error = _l10n.credentialProviderMissing;
        if (_activeID != null &&
            !(_integration?.credentialIDs.contains(_activeID) ?? false)) {
          // A disappeared ID does not tell us which other account is active.
          _activeKnown = false;
          _activeID = null;
        }
      });
    } catch (_) {
      if (_current) setState(() => _error = _l10n.credentialLoadFailed);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _act(
    IntegrationConnectionInfo connection,
    String label,
    _CredentialAction action,
  ) async {
    final id = connection.id;
    if (!_canAct ||
        id == null ||
        id.isEmpty ||
        connection.type != 'credential') {
      return;
    }
    final route = ModalRoute.of(context);
    bool canFinish() => _current && (route?.isCurrent ?? true);
    setState(() {
      _error = null;
      _message = null;
    });
    var dispatched = false;
    try {
      if (action == _CredentialAction.rename) {
        // The rename runs inside the dialog: a refused label or a failed
        // save keeps it open with the reason under the field.
        final saved = await showKitInputDialog(
          context,
          title: _l10n.credentialRename,
          label: _l10n.credentialLabel,
          confirmLabel: _l10n.credentialSave,
          initial: connection.label,
          maxLength: _labelLimit,
          fieldKey: const ValueKey('credential-label-field'),
          validate: (value) => _labelError(_l10n, value),
          onSubmit: (value) async {
            if (!_current) return _l10n.credentialScopeChanged;
            dispatched = true;
            try {
              await _controller.renameIntegrationCredential(
                widget.integrationID,
                id,
                value.trim(),
                locationRevision: _location,
              );
              return null;
            } catch (_) {
              return _l10n.credentialMutationFailed;
            }
          },
        );
        if (saved == null || !canFinish()) return;
        setState(() => _message = _l10n.credentialSheetRenamed(saved.trim()));
        return;
      }
      if (action == _CredentialAction.remove) {
        final confirmed = await showKitConfirm(
          context,
          kind: KitConfirmKind.destructive,
          icon: AppIconography.personRemove,
          title: _l10n.credentialRemoveAccountTitle(
            widget.integrationName,
            label,
          ),
          body: _l10n.credentialSheetRemoveBody(
            label,
            _integration?.name ?? widget.integrationName,
          ),
          confirmLabel: _l10n.credentialRemoveConfirmNamed(label),
          confirmKey: const ValueKey('credential-remove-confirm'),
        );
        if (!confirmed || !canFinish()) return;
      }
      if (!canFinish()) return;
      dispatched = true;
      // The row shows it is working only once the change is on its way.
      setState(() => _busyCredential = id);
      switch (action) {
        case _CredentialAction.activate:
          await _controller.activateIntegrationCredential(
            widget.integrationID,
            id,
            locationRevision: _location,
          );
        case _CredentialAction.rename:
          break;
        case _CredentialAction.remove:
          await _controller.removeIntegrationCredential(
            widget.integrationID,
            id,
            locationRevision: _location,
          );
      }
      if (!canFinish()) return;
      setState(() {
        _message = action == _CredentialAction.activate
            ? (_activeKnown && _activeID == id
                  ? _l10n.credentialActiveUpdated
                  : _l10n.credentialSwitchRequested)
            : null;
      });
    } catch (_) {
      if (canFinish()) setState(() => _error = _l10n.credentialMutationFailed);
    } finally {
      if (dispatched && canFinish()) {
        final mutationError = _error;
        await _load();
        if (_current && mutationError != null) {
          setState(() => _error = mutationError);
        }
      }
      if (mounted) setState(() => _busyCredential = null);
    }
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    _controller.removeListener(_connectionChanged);
    _controller.profileDataChanges.removeListener(_connectionChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final tokens = KitTokens.of(context);
    final gap = SizedBox(height: tokens.space3);
    final connections =
        _integration?.connections ?? const <IntegrationConnectionInfo>[];
    final credentials = connections
        .where(
          (value) => value.type == 'credential' && value.id?.isNotEmpty == true,
        )
        .toList();
    final environment = connections.where((value) => value.type == 'env');
    final working = _loading || _busyCredential != null;
    // The body of showKitSheet: the frame owns the rails and the scroll.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KitText(
          l10n.credentialMetadataOnly,
          role: KitTextRole.secondary,
          tone: KitTextTone.secondary,
        ),
        gap,
        if (!_current)
          KitNotice(message: l10n.credentialScopeChanged)
        else ...[
          KitLoadingBar(loading: working, label: l10n.credentialSheetLoading),
          if (_error case final error?) ...[
            KitNotice(
              key: const ValueKey('credential-error'),
              tone: AppStatusTone.failure,
              message: error,
              actions: [
                KitAction(
                  key: const ValueKey('credential-refresh'),
                  label: l10n.credentialRefresh,
                  onPressed: working ? null : _load,
                ),
              ],
            ),
            gap,
          ],
          if (_message case final message?) ...[
            KitNotice(tone: AppStatusTone.ok, message: message),
            gap,
          ],
          // Which account is in use shows only as the row's "Active" mark,
          // set once a server event says so; no paragraph explains an
          // unknown (slice-P3.11a).
          if (!_loading && credentials.isEmpty && _error == null)
            KitStateView(
              key: const ValueKey('credential-empty'),
              size: KitStateSize.inline,
              icon: AppIconography.manageAccount,
              title: l10n.credentialEmpty,
              body: l10n.credentialSheetEmptyBody(
                _integration?.name ?? widget.integrationName,
              ),
            ),
          if (credentials.isNotEmpty || environment.isNotEmpty)
            KitRowGroup(
              margin: EdgeInsets.zero,
              children: [
                for (var index = 0; index < credentials.length; index++)
                  _credentialRow(credentials[index], index),
                for (final connection in environment)
                  KitRow(
                    leading: KitRow.icon(context, AppIconography.locked),
                    title: connection.label,
                    supporting: TextSpan(text: l10n.credentialEnvironment),
                    supportingMaxLines: 2,
                  ),
              ],
            ),
        ],
      ],
    );
  }

  Widget _credentialRow(IntegrationConnectionInfo connection, int index) {
    final l10n = _l10n;
    final label = connection.label.trim().isEmpty
        ? l10n.credentialUnnamed(index + 1)
        : connection.label;
    final id = connection.id!;
    final active = _activeKnown && _activeID == id;
    final busy = _busyCredential == id;
    final menu = !_canAct
        ? const <KitMenuItem>[]
        : [
            KitMenuItem(
              key: ValueKey('credential-use-$id'),
              label: l10n.credentialSheetUseNamed(label),
              icon: AppIconography.check,
              enabled: !active,
              disabledReason: active ? l10n.credentialSheetInUse : null,
              onSelected: () =>
                  _act(connection, label, _CredentialAction.activate),
            ),
            KitMenuItem(
              key: ValueKey('credential-rename-$id'),
              label: l10n.credentialSheetRenameNamed(label),
              icon: AppIconography.edit,
              onSelected: () =>
                  _act(connection, label, _CredentialAction.rename),
            ),
            KitMenuItem(
              key: ValueKey('credential-remove-$id'),
              label: l10n.credentialSheetRemoveNamed(label),
              icon: AppIconography.personRemove,
              destructive: true,
              onSelected: () =>
                  _act(connection, label, _CredentialAction.remove),
            ),
          ];
    return KitRow(
      key: ValueKey('credential-$id'),
      leading: KitRow.icon(context, AppIconography.manageAccount),
      title: label,
      supporting: active ? TextSpan(text: l10n.credentialActive) : null,
      // The account's actions are one tap away, and say so.
      trailing: busy
          ? const KitTaskMark(state: KitTaskState.working)
          : KitRowMenu(
              items: menu,
              menuLabel: l10n.credentialSheetActions(label),
              tooltip: l10n.credentialSheetActions(label),
            ),
      menuLabel: l10n.credentialSheetActions(label),
      menu: menu,
    );
  }
}

/// The longest account label the server keeps.
const _labelLimit = 128;

/// Why [value] cannot be an account label, or null when it can.
String? _labelError(AppLocalizations l10n, String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return l10n.credentialSheetLabelEmpty;
  if (trimmed.runes.length > _labelLimit ||
      RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(trimmed)) {
    return l10n.credentialSheetLabelInvalid;
  }
  return null;
}
