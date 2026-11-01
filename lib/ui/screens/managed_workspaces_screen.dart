import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

import '../../domain/product_repository.dart';
import '../../state/connection.dart';
import '../app_iconography.dart';
import '../app_theme.dart' show AppStatusTone;
import '../kit/kit.dart';
import '../widgets/product_states.dart' show productErrorText;

/// Cloud environments (map pages managed-workspaces, -create-dialog and
/// -remove-dialog; revamp unit screen-work-3): the project's environments
/// that a server provider (an OpenCode workspace adapter) runs elsewhere.
///
/// Built from kit parts only: a [KitScreen] page with its top bar
/// (Discover existing in the overflow; pull to refresh reloads), the
/// environments on one [KitRowGroup], and "New environment" pinned at the
/// bottom only while a provider can make one. Which provider makes it is
/// chosen in the New environment sheet, never listed on the page.
///
/// States: loading (the screen's one bar), error with no data (a page
/// [KitStateView.error] with Try again), empty (says what appears here and
/// offers the first step), no provider set up (says where to set one up,
/// and no New environment), creating (a working state that says it usually
/// takes a few minutes), a failed refresh, create, discover or open (an
/// inline [KitNotice.error] with Try again where it can be retried), and
/// loaded. Removing confirms with the typed name and runs inside the
/// confirmation, so a failure stays there with Try again.
class ManagedWorkspacesScreen extends StatefulWidget {
  final ConnectionController controller;
  final WorkspaceProject project;

  const ManagedWorkspacesScreen({
    super.key,
    required this.controller,
    required this.project,
  });

  @override
  State<ManagedWorkspacesScreen> createState() =>
      _ManagedWorkspacesScreenState();
}

/// A one-off outcome shown at the top of the list until the next act.
class _Outcome {
  const _Outcome.error(this.title, this.message, {this.retry}) : error = true;
  const _Outcome.done(this.message) : title = null, error = false, retry = null;

  final String? title;
  final String message;
  final bool error;
  final VoidCallback? retry;
}

class _ManagedWorkspacesScreenState extends State<ManagedWorkspacesScreen> {
  List<WorkspaceInfo>? _workspaces;
  List<WorkspaceAdapterInfo>? _adapters;
  String? _workspaceError;
  String? _adapterError;
  String? _busyWorkspaceID;
  bool _loading = false;
  bool _syncing = false;
  bool _creating = false;
  DateTime? _creatingSince;
  _Outcome? _outcome;
  int _loadGeneration = 0;

  AppLocalizations get _l10n =>
      lookupAppLocalizations(Localizations.localeOf(context));

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    if (mounted) setState(() => _loading = true);
    final repository = await widget.controller.prepareActionRepository();
    if (!mounted || generation != _loadGeneration) return;
    if (repository == null) {
      setState(() {
        _loading = false;
        _workspaceError = _l10n.e7LibraryOpenCodeIsReconnectingTryAgainShortly;
        _adapterError = _workspaceError;
      });
      return;
    }

    List<WorkspaceInfo>? workspaces;
    List<WorkspaceAdapterInfo>? adapters;
    String? workspaceError;
    String? adapterError;
    try {
      workspaces = await repository.listManagedWorkspaces(
        projectDirectory: widget.project.directory,
      );
      workspaces.sort((a, b) => a.name.compareTo(b.name));
    } catch (error) {
      workspaceError = productErrorText(error);
    }
    if (!mounted || generation != _loadGeneration) return;
    try {
      adapters = await repository.listWorkspaceAdapters(
        projectDirectory: widget.project.directory,
      );
      adapters.sort((a, b) => a.name.compareTo(b.name));
    } catch (error) {
      adapterError = productErrorText(error);
    }
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _loading = false;
      if (workspaces != null) _workspaces = workspaces;
      if (adapters != null) _adapters = adapters;
      _workspaceError = workspaceError;
      _adapterError = adapterError;
    });
  }

  bool get _busy => _syncing || _creating || _busyWorkspaceID != null;

  Future<void> _sync() async {
    final l10n = _l10n;
    if (_busy) return;
    setState(() {
      _syncing = true;
      _outcome = null;
    });
    try {
      final repository = await widget.controller.prepareActionRepository();
      if (repository == null) {
        throw ProductException(l10n.e7LibraryOpenCodeIsReconnecting);
      }
      await repository.syncWorkspaceList(
        projectDirectory: widget.project.directory,
      );
      await _load();
      if (mounted) {
        setState(
          () => _outcome = _Outcome.done(l10n.managedWorkspacesDiscovered),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _outcome = _Outcome.error(
            l10n.managedWorkspacesDiscoverFailed,
            productErrorText(error),
            retry: _sync,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _create() async {
    final l10n = _l10n;
    final adapters = _adapters ?? const <WorkspaceAdapterInfo>[];
    if (_busy || adapters.isEmpty) return;
    final form = _CreateForm(adapters.first.type);
    final draft = await showKitSheet<_WorkspaceDraft>(
      context,
      title: l10n.e7LibraryNewManagedWorkspace,
      // One provider leaves nothing to choose: the subtitle names it.
      subtitle: adapters.length == 1
          ? l10n.managedWorkspacesCreateIn(adapters.single.name)
          : null,
      icon: AppIconography.cloud,
      sheetKey: const ValueKey('managed-workspaces-create-sheet'),
      body: (_) => _CreateWorkspaceBody(adapters: adapters, form: form),
      primary: KitAction(
        key: const ValueKey('confirm-create-managed-workspace'),
        label: l10n.e7LibraryCreateAndOpen,
        icon: AppIconography.add,
        onPressed: () => Navigator.of(context).pop(form.draft),
      ),
    );
    if (draft == null || !mounted) return;
    await _runCreate(draft);
  }

  Future<void> _runCreate(_WorkspaceDraft draft) async {
    final l10n = _l10n;
    setState(() {
      _creating = true;
      _creatingSince = DateTime.now();
      _outcome = null;
    });
    try {
      final repository = await widget.controller.prepareActionRepository();
      if (repository == null) {
        throw ProductException(l10n.e7LibraryOpenCodeIsReconnecting);
      }
      final workspace = await repository.createManagedWorkspace(
        projectDirectory: widget.project.directory,
        type: draft.type,
        branch: draft.branch,
      );
      await widget.controller.selectLocation(
        directory: workspace.directory ?? widget.project.directory,
        workspace: workspace.id,
      );
      if (!mounted) return;
      final locationError = widget.controller.locationError;
      if (locationError != null) throw ProductException(locationError);
      Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(
          () => _outcome = _Outcome.error(
            l10n.managedWorkspacesCreateFailed,
            productErrorText(error),
            retry: () => unawaited(_runCreate(draft)),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _creating = false;
          _creatingSince = null;
        });
      }
    }
  }

  Future<void> _open(WorkspaceInfo workspace) async {
    if (_busy) return;
    setState(() {
      _busyWorkspaceID = workspace.id;
      _outcome = null;
    });
    await widget.controller.selectLocation(
      directory: workspace.directory ?? widget.project.directory,
      workspace: workspace.id,
    );
    if (!mounted) return;
    setState(() => _busyWorkspaceID = null);
    final problem = widget.controller.locationError;
    if (problem != null) {
      setState(
        () => _outcome = _Outcome.error(
          _l10n.managedWorkspacesOpenFailed(workspace.name),
          problem,
          retry: () => unawaited(_open(workspace)),
        ),
      );
      return;
    }
    Navigator.of(context).pop(true);
  }

  Future<void> _remove(WorkspaceInfo workspace) async {
    final l10n = _l10n;
    if (_busy) return;
    final active = widget.controller.workspace == workspace.id;
    setState(() => _outcome = null);
    final removed = await showKitConfirm(
      context,
      title: l10n.managedWorkspacesRemoveTitle(workspace.name),
      body: l10n.managedWorkspacesRemoveBody(_providerName(workspace.type)),
      consequences: [
        if (active) l10n.managedWorkspacesRemoveLeavesFirst,
        l10n.managedWorkspacesRemoveHistoryStays,
      ],
      confirmLabel: l10n.managedWorkspacesRemoveConfirm,
      kind: KitConfirmKind.destructive,
      typedName: workspace.name,
      confirmKey: const ValueKey('confirm-remove-managed-workspace'),
      action: () => _removeNow(workspace),
    );
    if (!removed || !mounted) return;
    await _load();
    if (mounted) {
      setState(
        () => _outcome = _Outcome.done(
          l10n.managedWorkspacesRemoved(workspace.name),
        ),
      );
    }
  }

  /// Runs inside the confirmation: a failure keeps it open with Try again.
  Future<void> _removeNow(WorkspaceInfo workspace) async {
    final l10n = _l10n;
    if (mounted) setState(() => _busyWorkspaceID = workspace.id);
    try {
      if (widget.controller.workspace == workspace.id) {
        await widget.controller.selectLocation(
          directory: widget.project.directory,
        );
        final locationError = widget.controller.locationError;
        if (locationError != null) throw ProductException(locationError);
      }
      final repository = await widget.controller.prepareActionRepository();
      if (repository == null) {
        throw ProductException(l10n.e7LibraryOpenCodeIsReconnecting);
      }
      await repository.removeManagedWorkspace(
        projectDirectory: widget.project.directory,
        id: workspace.id,
      );
    } finally {
      if (mounted) setState(() => _busyWorkspaceID = null);
    }
  }

  /// The provider's own name for an environment's type, or the type.
  String _providerName(String type) {
    for (final adapter in _adapters ?? const <WorkspaceAdapterInfo>[]) {
      if (adapter.type == type) return adapter.name;
    }
    return type;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final tokens = KitTokens.of(context);
    final workspaces = _workspaces;
    final adapters = _adapters;
    // New environment only while a provider works and the list is known
    // (an unreadable list never offers create).
    final canCreate = adapters?.isNotEmpty == true && workspaces != null;
    final noProvider = adapters != null && adapters.isEmpty;
    final outcome = _outcome;
    final creatingSince = _creatingSince;
    final gutter = EdgeInsetsDirectional.only(
      start: tokens.gutter,
      top: tokens.space3,
      end: tokens.gutter,
    );
    return KitScreen(
      // A status page read like settings: centred at the reading width.
      width: KitScreenWidth.reading,
      topBar: KitTopBar(
        title: l10n.e7LibraryCloudEnvironments,
        subtitle: widget.project.name,
        menu: [
          KitMenuItem(
            key: const ValueKey('sync-managed-workspaces'),
            label: l10n.e7LibraryDiscoverExistingEnvironments,
            icon: AppIconography.sync,
            enabled: !_busy,
            disabledReason: _busy ? l10n.kitWorking : null,
            onSelected: () => unawaited(_sync()),
          ),
        ],
        menuKey: const ValueKey('managed-workspaces-menu'),
      ),
      loading: _loading || _syncing,
      loadingLabel: l10n.e7LibraryLoading(l10n.e7LibraryEnvironments),
      bottom: canCreate
          ? KitActionBlock(
              primary: KitAction(
                key: const ValueKey('create-managed-workspace'),
                label: l10n.e7LibraryNewEnvironment,
                icon: AppIconography.add,
                working: _creating,
                onPressed: _busy ? null : () => unawaited(_create()),
                disabledReason: _busy && !_creating ? l10n.kitWorking : null,
              ),
            )
          : null,
      body: KitRefresh(
        onRefresh: _load,
        child: ListView(
          key: const ValueKey('managed-workspaces-list'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsetsDirectional.only(
            bottom: KitScreen.endPadding(context),
          ),
          children: [
            if (creatingSince != null)
              KitStateView(
                key: const ValueKey('managed-workspaces-creating'),
                size: KitStateSize.inline,
                icon: AppIconography.cloud,
                tone: AppStatusTone.progress,
                title: l10n.managedWorkspacesCreating,
                body: l10n.managedWorkspacesCreatingBody,
                progress: const KitProgress.waiting(),
                since: creatingSince,
              ),
            if (outcome != null)
              Padding(
                padding: gutter,
                child: outcome.error
                    ? KitNotice.error(
                        key: const ValueKey('managed-workspaces-outcome'),
                        title: outcome.title,
                        message: outcome.message,
                        retry: outcome.retry == null
                            ? null
                            : KitAction(
                                label: l10n.kitTryAgain,
                                onPressed: outcome.retry,
                              ),
                      )
                    : KitNotice(
                        key: const ValueKey('managed-workspaces-outcome'),
                        message: outcome.message,
                        tone: AppStatusTone.ok,
                        onDismiss: () => setState(() => _outcome = null),
                      ),
              ),
            ..._environments(
              l10n,
              gutter,
              noProvider,
              below: creatingSince != null || outcome != null,
            ),
            ?_providerProblem(l10n, gutter),
          ],
        ),
      ),
    );
  }

  List<Widget> _environments(
    AppLocalizations l10n,
    EdgeInsetsGeometry gutter,
    bool noProvider, {
    required bool below,
  }) {
    final workspaces = _workspaces;
    final error = _workspaceError;
    if (error != null && workspaces == null) {
      return [
        KitStateView.error(
          key: const ValueKey('managed-workspaces-error'),
          size: KitStateSize.inline,
          title: l10n.managedWorkspacesLoadFailed,
          body: error,
          retry: KitAction(
            label: l10n.e7LibraryRetryCloudEnvironments,
            onPressed: () => unawaited(_load()),
          ),
        ),
      ];
    }
    if (workspaces == null) return const [KitSkeletonRows(count: 3)];
    if (workspaces.isEmpty) {
      return [
        if (noProvider)
          KitStateView(
            key: const ValueKey('managed-workspaces-no-provider'),
            size: KitStateSize.inline,
            icon: AppIconography.cloudOff,
            title: l10n.managedWorkspacesNoProviderTitle,
            body: l10n.managedWorkspacesNoProviderBody,
            primary: KitAction(
              label: l10n.managedWorkspacesRefresh,
              icon: AppIconography.retry,
              onPressed: _loading ? null : () => unawaited(_load()),
              disabledReason: _loading ? l10n.kitWorking : null,
            ),
          )
        else
          KitStateView(
            key: const ValueKey('managed-workspaces-empty'),
            size: KitStateSize.inline,
            icon: AppIconography.cloud,
            title: l10n.e7LibraryNoCloudEnvironments,
            body: l10n.managedWorkspacesEmptyBody(widget.project.name),
            secondary: KitAction(
              label: l10n.e7LibraryDiscoverExistingEnvironments,
              icon: AppIconography.sync,
              onPressed: _busy ? null : () => unawaited(_sync()),
              disabledReason: _busy ? l10n.kitWorking : null,
            ),
          ),
        if (error != null) _refreshFailed(l10n, gutter, error),
      ];
    }
    // The page title names the list, so it carries no label or count.
    return [
      KitRowGroup(
        key: const ValueKey('managed-workspaces-group'),
        gapBefore: below ? KitTokens.of(context).space3 : null,
        children: [
          for (final workspace in workspaces)
            _WorkspaceRow(
              workspace: workspace,
              provider: _providerName(workspace.type),
              active: widget.controller.workspace == workspace.id,
              busy: _busyWorkspaceID == workspace.id,
              onOpen: () => unawaited(_open(workspace)),
              onRemove: () => unawaited(_remove(workspace)),
            ),
        ],
      ),
      if (error != null) _refreshFailed(l10n, gutter, error),
    ];
  }

  Widget _refreshFailed(
    AppLocalizations l10n,
    EdgeInsetsGeometry gutter,
    String error,
  ) => Padding(
    padding: gutter,
    child: KitNotice.error(
      title: l10n.e7LibraryEnvironmentRefreshFailed,
      message: error,
      retry: KitAction(
        label: l10n.e7LibraryRetryCloudEnvironments,
        onPressed: () => unawaited(_load()),
      ),
    ),
  );

  /// Why New environment is missing while environments are listed: the
  /// providers could not be read, or the server has none. With no
  /// environments either, the page's own state says so instead.
  Widget? _providerProblem(AppLocalizations l10n, EdgeInsetsGeometry gutter) {
    final adapters = _adapters;
    final error = _adapterError;
    final workspaces = _workspaces;
    // An unreadable list already has the page's error, which covers this.
    if (workspaces == null) return null;
    if (error != null) {
      return Padding(
        padding: gutter,
        child: KitNotice.error(
          key: const ValueKey('workspace-adapter-error'),
          title: adapters == null
              ? l10n.managedWorkspacesProvidersFailed
              : l10n.e7LibraryAdapterRefreshFailed,
          message: error,
          retry: KitAction(
            label: l10n.kitTryAgain,
            onPressed: () => unawaited(_load()),
          ),
        ),
      );
    }
    // With no environments, the empty state says there is no provider.
    if (adapters != null && adapters.isEmpty && workspaces.isNotEmpty) {
      return Padding(
        padding: gutter,
        child: KitNotice(
          key: const ValueKey('workspace-adapters-empty'),
          icon: AppIconography.cloudOff,
          title: l10n.managedWorkspacesNoProviderTitle,
          message: l10n.managedWorkspacesNoProviderBody,
        ),
      );
    }
    return null;
  }
}

/// One environment: its name, then "In use ·" when it is the one open, its
/// state word, provider and branch. A tap opens it; long-press, right-click
/// or the menu key offer Open and Remove.
class _WorkspaceRow extends StatelessWidget {
  final WorkspaceInfo workspace;
  final String provider;
  final bool active;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  const _WorkspaceRow({
    required this.workspace,
    required this.provider,
    required this.active,
    required this.busy,
    required this.onOpen,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final (icon, state) = switch (workspace.status?.toLowerCase()) {
      'connected' => (AppIconography.cloudCheck, l10n.e7LibraryConnected),
      'connecting' => (AppIconography.sync, l10n.e7LibraryConnecting),
      'error' => (AppIconography.cloudOff, l10n.capsuleError),
      'disconnected' => (AppIconography.cloudOff, l10n.e7LibraryDisconnected),
      _ => (AppIconography.cloud, l10n.servicesUnknown),
    };
    final facts = [
      if (active) l10n.managedWorkspacesInUse,
      state,
      provider,
      if (workspace.branch?.isNotEmpty == true) KitBidi.ltr(workspace.branch!),
    ].join(' · ');
    return KitRow(
      key: ValueKey('managed-workspace-${workspace.id}'),
      leading: KitRowIcon(icon, current: active),
      title: workspace.name,
      supporting: TextSpan(text: facts),
      supportingMaxLines: 2,
      selected: active,
      enabled: !busy,
      disabledReason: busy ? l10n.kitWorking : null,
      onTap: onOpen,
      menuLabel: l10n.e7LibraryEnvironmentActions,
      menu: [
        KitMenuItem(
          key: const ValueKey('environment-menu-open'),
          label: active ? l10n.e7LibraryOpenAgain : l10n.globalSessionsOpen,
          icon: AppIconography.externalLink,
          onSelected: onOpen,
        ),
        KitMenuItem.copy(
          label: l10n.managedWorkspacesCopyId,
          text: () => workspace.id,
        ),
        KitMenuItem(
          key: const ValueKey('environment-menu-remove'),
          label: l10n.managedWorkspacesRemoveAction,
          icon: AppIconography.delete,
          destructive: true,
          onSelected: onRemove,
        ),
      ],
    );
  }
}

class _WorkspaceDraft {
  final String type;
  final String? branch;

  const _WorkspaceDraft({required this.type, this.branch});
}

/// What the create sheet's body has chosen so far; read by its primary.
class _CreateForm {
  _CreateForm(this.type);

  String type;
  String branch = '';

  _WorkspaceDraft get draft {
    final value = branch.trim();
    return _WorkspaceDraft(type: type, branch: value.isEmpty ? null : value);
  }
}

/// The create sheet's body: the provider (a choice only when there are
/// several; one is named in the sheet's subtitle), the branch, and how long
/// it usually takes.
class _CreateWorkspaceBody extends StatefulWidget {
  const _CreateWorkspaceBody({required this.adapters, required this.form});

  final List<WorkspaceAdapterInfo> adapters;
  final _CreateForm form;

  @override
  State<_CreateWorkspaceBody> createState() => _CreateWorkspaceBodyState();
}

class _CreateWorkspaceBodyState extends State<_CreateWorkspaceBody> {
  late final TextEditingController _branch = TextEditingController(
    text: widget.form.branch,
  )..addListener(() => widget.form.branch = _branch.text);

  @override
  void dispose() {
    _branch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final tokens = KitTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.adapters.length > 1) ...[
          KitSectionLabel(
            l10n.managedWorkspacesProvider,
            margin: EdgeInsets.zero,
          ),
          KitChoiceList<String>.single(
            key: const ValueKey('workspace-adapter-picker'),
            choices: [
              for (final adapter in widget.adapters)
                KitChoice(
                  value: adapter.type,
                  title: adapter.name,
                  supporting: adapter.description.isEmpty
                      ? null
                      : adapter.description,
                ),
            ],
            selected: widget.form.type,
            actsOnTap: false,
            onSelected: (value) => setState(() => widget.form.type = value),
          ),
          SizedBox(height: tokens.space4),
        ],
        KitField(
          label: l10n.managedWorkspacesBranchLabel,
          controller: _branch,
          kind: KitFieldKind.mono,
          helper: l10n.managedWorkspacesBranchHelper,
          fieldKey: const ValueKey('workspace-branch-input'),
        ),
        SizedBox(height: tokens.space4),
        KitNotice(
          icon: AppIconography.clock,
          message: l10n.managedWorkspacesCreateTakes,
          liveRegion: false,
        ),
      ],
    );
  }
}
