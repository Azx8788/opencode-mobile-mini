import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../domain/product_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import '../app_iconography.dart';
import '../early_l10n.dart';
import '../kit/kit.dart';
import '../widgets/product_states.dart'
    show productErrorDetails, productErrorText;
import '../widgets/session_handoff.dart';

enum SessionDestinationMode { move, warp }

/// Moves a conversation to another folder of its project (move) or to a
/// cloud machine (warp) (map: session-destination-sheet). One chevron row per
/// place, named and said in words; the current place is marked once.
///
/// The sheet is the choice; once a place is picked it closes and the
/// question follows as its own modal, so the question is never squeezed
/// into the list's sheet (and no sheet sits on a sheet, KIT-16).
Future<void> showSessionDestinationSheet(
  BuildContext context, {
  required ConnectionController controller,
  required String sessionID,
  required SessionDestinationMode mode,
}) async {
  final copy = _sharedCopy(context);
  final moving = mode == SessionDestinationMode.move;
  final pick = await showKitSheet<_DestinationPick>(
    context,
    title: moving ? copy.e7SharedMoveSession : copy.sessionDestinationWarpTitle,
    subtitle: moving
        ? copy.e7SharedChooseAnotherDirectoryInThisProject
        : copy.e7SharedChooseAConnectedWorkspaceOrReturnTo,
    icon: moving ? AppIconography.folders : AppIconography.cloud,
    sheetKey: Key(moving ? 'move-session-sheet' : 'warp-session-sheet'),
    body: (_) => _SessionDestinationSheet(
      controller: controller,
      sessionID: sessionID,
      mode: mode,
    ),
  );
  if (pick == null || !context.mounted) return;
  await _confirmMove(context, controller, sessionID, mode, pick);
}

/// What the sheet hands to the question: the place, what the working
/// changes are, and the session and location as they were when read.
class _DestinationPick {
  const _DestinationPick({
    required this.destination,
    required this.here,
    required this.changes,
    required this.unknownChanges,
    required this.scope,
    required this.session,
  });

  final _SessionDestination destination;
  final String here;
  final int changes;
  final bool unknownChanges;
  final SessionNavigationScope scope;
  final Session? session;
}

/// Asks before moving, naming the destination in the title and every
/// answer, and saying where the working changes go and where they stay.
/// The move runs inside the question: a failure keeps it open with the
/// reason and Try again, so it never closes on an error. "Move to {place}
/// without changes" closes the question and moves; a failure there is said
/// in an alert.
Future<void> _confirmMove(
  BuildContext context,
  ConnectionController controller,
  String sessionID,
  SessionDestinationMode mode,
  _DestinationPick pick,
) async {
  final copy = _sharedCopy(context);
  final moving = mode == SessionDestinationMode.move;
  final destination = pick.destination;
  final hasChanges = pick.changes > 0;
  var withoutChanges = false;
  Future<void> perform(bool transfer) => _performMove(
    controller,
    sessionID,
    mode,
    pick,
    transfer: transfer,
    copy: copy,
  );
  final confirmed = await showKitConfirm(
    context,
    title: copy.e7SharedDetail429(destination.title),
    body: hasChanges
        ? copy.sessionDestinationChangesCount(pick.changes)
        : pick.unknownChanges
        ? copy.e7SharedTheAppCouldNotInspectWorkingChanges
        : copy.sessionDestinationNoChanges(pick.here),
    // Where the changes go and where they stay are two facts of one
    // choice, neither good nor bad news: one neutral mark for both.
    consequenceItems: hasChanges
        ? [
            KitConsequence(
              moving
                  ? copy.sessionDestinationChangesGo(destination.title)
                  : copy.sessionDestinationChangesCopied(destination.title),
              mark: KitConsequenceMark.neutral,
            ),
            KitConsequence(
              copy.sessionDestinationChangesStay(pick.here),
              mark: KitConsequenceMark.neutral,
            ),
          ]
        : null,
    confirmLabel: hasChanges
        ? moving
              ? copy.sessionDestinationMoveWithChanges(destination.title)
              : copy.sessionDestinationWarpWithChanges(destination.title)
        : copy.sessionDestinationMoveTo(destination.title),
    confirmKey: const Key('session-destination-confirm'),
    // The kit places the alternative between the confirm and Cancel.
    alternative: hasChanges
        ? KitAction(
            key: const Key('session-destination-without-changes'),
            label: copy.sessionDestinationMoveWithout(destination.title),
            onPressed: () => withoutChanges = true,
          )
        : null,
    action: () => perform(hasChanges && !pick.unknownChanges),
  );
  if (confirmed || !withoutChanges) return;
  try {
    await perform(false);
  } catch (error) {
    if (!context.mounted) return;
    await showKitAlert(
      context,
      alertKey: const Key('session-destination-move-failed'),
      title: copy.sessionDestinationMoveFailed,
      body: productErrorText(error),
    );
  }
}

/// Moves (or copies) the conversation; [transfer] takes the working changes
/// along. Re-reads the session first so a conversation that moved elsewhere
/// meanwhile is never moved from the wrong place.
Future<void> _performMove(
  ConnectionController controller,
  String sessionID,
  SessionDestinationMode mode,
  _DestinationPick pick, {
  required bool transfer,
  required AppLocalizations copy,
}) async {
  final destination = pick.destination;
  pick.scope.check(controller);
  final repository = await controller.prepareActionRepository();
  pick.scope.check(controller);
  if (repository == null) {
    throw StateError(copy.e7SharedOpenCodeIsReconnectingTryAgain);
  }
  final current = await repository.getSessionDetails(sessionID);
  pick.scope.check(controller);
  if (current.id != sessionID ||
      current.directory != pick.session?.directory ||
      current.workspaceID != pick.session?.workspaceID) {
    throw StateError(copy.e7SharedSessionLocationChangedCloseAndReopenThis);
  }
  if (mode == SessionDestinationMode.move) {
    await controller.moveSessionToDirectory(
      sessionID,
      directory: destination.directory,
      moveChanges: transfer,
    );
  } else {
    await controller.warpSessionToWorkspace(
      sessionID,
      directory: destination.directory,
      workspaceID: destination.workspaceID,
      copyChanges: transfer,
    );
  }
}

/// Switches the OpenCode Console organization (map: console-organization-
/// sheet). Kit-only rebuild of today's layout; the Settings row it becomes is
/// deferred to its account slice (map proposal: redesign).
///
/// The sheet is the choice; the question follows it as its own modal, with
/// what switching changes. The switch runs inside the question, so a
/// failure keeps it open with Try again.
Future<void> showConsoleOrganizationSheet(
  BuildContext context, {
  required ConnectionController controller,
}) async {
  final copy = _sharedCopy(context);
  final organization = await showKitSheet<ConsoleOrganization>(
    context,
    title: copy.e7SharedSwitchOrganization462,
    subtitle: copy.consoleOrganizationWhatChanges,
    icon: AppIconography.account,
    sheetKey: const Key('console-organization-sheet'),
    body: (_) => _ConsoleOrganizationSheet(controller: controller),
  );
  if (organization == null || organization.active || !context.mounted) {
    return;
  }
  await showKitConfirm(
    context,
    title: copy.e7SharedSwitchOrganization,
    body: copy.consoleOrganizationSwitchBody(organization.orgName),
    confirmLabel: copy.consoleOrganizationSwitchConfirm(organization.orgName),
    confirmKey: const Key('console-org-confirm'),
    action: () => controller.switchConsoleOrganization(organization),
  );
}

class _SessionDestination {
  const _SessionDestination({
    required this.title,
    required this.directory,
    required this.kind,
    this.workspaceID,
    this.connected = true,
    this.current = false,
  });

  final String title;
  final String directory;

  /// What kind of place it is, in words: "Main copy", "Separate copy",
  /// "Cloud machine · Connected".
  final String kind;
  final String? workspaceID;
  final bool connected;
  final bool current;
}

class _SessionDestinationSheet extends StatefulWidget {
  const _SessionDestinationSheet({
    required this.controller,
    required this.sessionID,
    required this.mode,
  });

  final ConnectionController controller;
  final String sessionID;
  final SessionDestinationMode mode;

  @override
  State<_SessionDestinationSheet> createState() =>
      _SessionDestinationSheetState();
}

class _SessionDestinationSheetState extends State<_SessionDestinationSheet> {
  List<_SessionDestination>? _destinations;
  List<VersionControlFile> _changes = const [];
  Object? _error;
  Object? _changesError;
  String _query = '';
  late final SessionNavigationScope _scope;
  Session? _session;

  bool get _moving => widget.mode == SessionDestinationMode.move;

  @override
  void initState() {
    super.initState();
    _scope = SessionNavigationScope(widget.controller);
    unawaited(_load());
  }

  Future<void> _load() async {
    // Runs from initState, so inherited lookups are not yet allowed.
    final copy = earlyAppLocalizations(context);
    if (!_scope.matches(widget.controller)) {
      setState(
        () => _error = StateError(
          copy.e7SharedSessionLocationChangedCloseAndReopenThis,
        ),
      );
      return;
    }
    final repository = await widget.controller.prepareActionRepository();
    if (!mounted) return;
    if (!_scope.matches(widget.controller)) {
      setState(
        () => _error = StateError(
          copy.e7SharedSessionLocationChangedCloseAndReopenThis,
        ),
      );
      return;
    }
    if (repository == null) {
      setState(
        () => _error = ProductException(copy.e7SharedOpenCodeIsReconnecting),
      );
      return;
    }
    setState(() {
      _destinations = null;
      _changes = const [];
      _error = null;
      _changesError = null;
    });
    try {
      final session = await repository.getSessionDetails(widget.sessionID);
      _scope.check(widget.controller);
      _session = session;
      final currentDirectory =
          session.directory ?? widget.controller.directory ?? '';
      final projects = await repository.listProjects();
      if (!mounted) return;
      final project = _projectForSession(projects, session, currentDirectory);
      if (project == null) {
        throw ProductException(copy.e7SharedTheSessionProjectIsNotAvailableOn);
      }

      final destinations = _moving
          ? await _loadMoveDestinations(
              repository,
              project,
              session,
              currentDirectory,
            )
          : await _loadWarpDestinations(repository, project, session);
      List<VersionControlFile> changes = const [];
      Object? changesError;
      try {
        final health = await repository.loadVersionControlHealth();
        changes = health.changes;
      } catch (error) {
        changesError = error;
      }
      if (!mounted) return;
      _scope.check(widget.controller);
      setState(() {
        _destinations = destinations;
        _changes = changes;
        _changesError = changesError;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  WorkspaceProject? _projectForSession(
    List<WorkspaceProject> projects,
    Session? session,
    String currentDirectory,
  ) {
    for (final project in projects) {
      if (project.id == session?.projectID) return project;
    }
    final matches =
        projects.where((project) {
            final roots = [project.directory, ...project.worktrees];
            return roots.any((root) => _containsPath(root, currentDirectory));
          }).toList()
          ..sort((a, b) => b.directory.length.compareTo(a.directory.length));
    return matches.isEmpty ? null : matches.first;
  }

  Future<List<_SessionDestination>> _loadMoveDestinations(
    ServerOperationsGateway repository,
    WorkspaceProject project,
    Session? session,
    String currentDirectory,
  ) async {
    final copy = _sharedCopy(context);
    final listed = await repository.listProjectDirectories(project.id);
    final directories = <String>{
      if (currentDirectory.isNotEmpty) currentDirectory,
      ...listed.map((item) => item.directory),
      for (final item in widget.controller.sessionsById.values)
        if (item.projectID == project.id && item.directory?.isNotEmpty == true)
          item.directory!,
    }.toList();
    directories.sort((a, b) {
      if (a == currentDirectory) return -1;
      if (b == currentDirectory) return 1;
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
    return [
      for (final directory in directories)
        _SessionDestination(
          title: _basename(directory),
          directory: directory,
          kind: _samePath(directory, project.directory)
              ? copy.worktreesMainCopy
              : copy.sessionDestinationSeparateCopy,
          current: directory == currentDirectory,
        ),
    ];
  }

  Future<List<_SessionDestination>> _loadWarpDestinations(
    ServerOperationsGateway repository,
    WorkspaceProject project,
    Session? session,
  ) async {
    final copy = _sharedCopy(context);
    final currentWorkspaceID =
        session?.workspaceID ?? widget.controller.workspace;
    final workspaces = await repository.listWorkspaces();
    final projectWorkspaces =
        workspaces
            .where((workspace) => workspace.projectID == project.id)
            .toList()
          ..sort((a, b) {
            if (a.id == currentWorkspaceID) return -1;
            if (b.id == currentWorkspaceID) return 1;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
    return [
      _SessionDestination(
        title: copy.e7SharedLocalProject,
        directory: project.directory,
        kind: copy.worktreesMainCopy,
        current: currentWorkspaceID == null,
      ),
      for (final workspace in projectWorkspaces)
        _SessionDestination(
          title: workspace.name,
          directory: workspace.directory ?? project.directory,
          workspaceID: workspace.id,
          // Unknown status is not "connected": only a machine that says it
          // is connected can take the conversation.
          connected:
              workspace.status == null || workspace.status == 'connected',
          kind: copy.sessionDestinationCloudKind(
            workspace.status == null || workspace.status == 'connected'
                ? copy.sessionDestinationConnected
                : copy.sessionDestinationNotConnected,
          ),
          current: workspace.id == currentWorkspaceID,
        ),
    ];
  }

  void _select(_SessionDestination destination) {
    if (destination.current) return;
    if (!_moving && !destination.connected) return;
    final here =
        _destinations
            ?.firstWhere((item) => item.current, orElse: () => destination)
            .title ??
        destination.title;
    Navigator.of(context).pop(
      _DestinationPick(
        destination: destination,
        here: here,
        changes: _changes.length,
        unknownChanges: _changesError != null,
        scope: _scope,
        session: _session,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final copy = _sharedCopy(context);
    final tokens = KitTokens.of(context);
    final destinations = _destinations;
    final query = _query.trim().toLowerCase();
    final visible = destinations
        ?.where(
          (item) =>
              query.isEmpty ||
              item.title.toLowerCase().contains(query) ||
              item.directory.toLowerCase().contains(query),
        )
        .toList();
    final gap = SizedBox(height: tokens.space3);
    final children = <Widget>[];
    void add(Widget child) {
      if (children.isNotEmpty) children.add(gap);
      children.add(child);
    }

    if ((destinations?.length ?? 0) > 6) {
      add(
        KitSearchField(
          fieldKey: const Key('session-destination-search'),
          label: copy.e7SharedFilterDestinations,
          onChanged: (value) => setState(() => _query = value),
          resultCount: query.isEmpty ? null : visible?.length,
        ),
      );
    }
    if (_error != null && destinations == null) {
      add(
        KitStateView.error(
          title: copy.sessionDestinationLoadFailed,
          body: productErrorText(_error!),
          error: _error,
          details: productErrorDetails(_error!),
          size: KitStateSize.inline,
          retry: KitAction(label: copy.isolatedTaskRetryOpen, onPressed: _load),
        ),
      );
    } else if (visible == null) {
      add(const KitSkeletonRows(count: 4));
    } else if (visible.isEmpty && query.isNotEmpty) {
      add(
        KitSearchNoMatch(
          query: _query,
          onClear: () => setState(() => _query = ''),
        ),
      );
    } else {
      final others = visible.where((item) => !item.current).length;
      final titles = <String, int>{};
      for (final item in visible) {
        titles[item.title] = (titles[item.title] ?? 0) + 1;
      }
      if (visible.isNotEmpty) {
        add(
          KitRowGroup(
            margin: EdgeInsets.zero,
            children: [
              for (final item in visible)
                _destinationRow(item, duplicate: (titles[item.title] ?? 0) > 1),
            ],
          ),
        );
      }
      // Nowhere else to go: say so and why, instead of an empty list.
      if (others == 0 && query.isEmpty) {
        add(
          KitStateView(
            key: const Key('session-destination-none'),
            icon: _moving ? AppIconography.folders : AppIconography.cloudOff,
            title: copy.sessionDestinationNoneTitle,
            body: _moving
                ? copy.sessionDestinationNoneMoveBody
                : copy.sessionDestinationNoneWarpBody,
            size: KitStateSize.inline,
          ),
        );
      }
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _destinationRow(_SessionDestination item, {required bool duplicate}) {
    final copy = _sharedCopy(context);
    final unavailable = !_moving && !item.connected;
    return KitRow(
      key: ValueKey(
        '${_moving ? 'move' : 'warp'}-destination-${item.workspaceID ?? item.directory}',
      ),
      leading: KitRowIcon(
        _moving
            ? AppIconography.folderOpen
            : item.workspaceID == null
            ? AppIconography.computer
            : AppIconography.cloud,
        current: item.current,
      ),
      title: item.title,
      // Name and kind; the path only when two places share a name.
      supporting: TextSpan(
        text: duplicate ? '${item.kind} · ${item.directory}' : item.kind,
      ),
      supportingMaxLines: duplicate || unavailable ? 2 : 1,
      // The current place is marked once (its tile and the word), and is
      // not dimmed: it is where the conversation is, not unavailable.
      trailing: item.current
          ? KitRowValue(copy.e7SharedCurrent, chevron: false)
          : unavailable
          ? null
          : const KitChevron(),
      enabled: !unavailable,
      disabledReason: unavailable
          ? copy.sessionDestinationNotConnectedWhy
          : null,
      onTap: item.current || unavailable ? null : () => _select(item),
    );
  }
}

class _ConsoleOrganizationSheet extends StatefulWidget {
  const _ConsoleOrganizationSheet({required this.controller});

  final ConnectionController controller;

  @override
  State<_ConsoleOrganizationSheet> createState() =>
      _ConsoleOrganizationSheetState();
}

class _ConsoleOrganizationSheetState extends State<_ConsoleOrganizationSheet> {
  List<ConsoleOrganization>? _organizations;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    // Runs from initState, so inherited lookups are not yet allowed.
    final copy = earlyAppLocalizations(context);
    final repository = await widget.controller.prepareActionRepository();
    if (!mounted) return;
    if (repository == null) {
      setState(
        () => _error = ProductException(copy.e7SharedOpenCodeIsReconnecting),
      );
      return;
    }
    setState(() {
      _organizations = null;
      _error = null;
    });
    try {
      final organizations = [...await repository.listConsoleOrganizations()];
      // The account holding the current organization first, then the
      // rest by name; within an account, the current one first.
      final current = {
        for (final organization in organizations)
          if (organization.active) _accountLabel(organization),
      };
      organizations.sort((a, b) {
        final aCurrent = current.contains(_accountLabel(a));
        final bCurrent = current.contains(_accountLabel(b));
        if (aCurrent != bCurrent) return aCurrent ? -1 : 1;
        final account = _accountLabel(a).compareTo(_accountLabel(b));
        if (account != 0) return account;
        if (a.active != b.active) return a.active ? -1 : 1;
        return a.orgName.compareTo(b.orgName);
      });
      if (mounted) setState(() => _organizations = organizations);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  void _switch(ConsoleOrganization organization) {
    if (organization.active) return;
    Navigator.of(context).pop(organization);
  }

  @override
  Widget build(BuildContext context) {
    final copy = _sharedCopy(context);
    final tokens = KitTokens.of(context);
    final organizations = _organizations;
    final gap = SizedBox(height: tokens.space3);
    final children = <Widget>[];
    void add(Widget child) {
      if (children.isNotEmpty) children.add(gap);
      children.add(child);
    }

    if (organizations == null) {
      add(
        _error == null
            ? const KitSkeletonRows(count: 3)
            : KitStateView.error(
                title: copy.consoleOrganizationLoadFailed,
                body: productErrorText(_error!),
                error: _error,
                details: productErrorDetails(_error!),
                size: KitStateSize.inline,
                retry: KitAction(
                  label: copy.isolatedTaskRetryOpen,
                  onPressed: _load,
                ),
              ),
      );
    } else if (organizations.isEmpty) {
      add(
        KitStateView(
          icon: AppIconography.account,
          title: copy.consoleOrganizationNoneTitle,
          body:
              copy.e7SharedNoSwitchableOpenCodeConsoleOrganizationsWereReturned,
          size: KitStateSize.inline,
        ),
      );
    } else {
      // One group per account, its label said once.
      final accounts = <String, List<ConsoleOrganization>>{};
      for (final organization in organizations) {
        accounts
            .putIfAbsent(_accountLabel(organization), () => [])
            .add(organization);
      }
      for (final MapEntry(key: account, value: members) in accounts.entries) {
        add(
          KitRowGroup(
            label: account,
            margin: EdgeInsets.zero,
            children: [
              for (final organization in members)
                KitRow(
                  key: ValueKey(
                    'console-org-${organization.accountID}-${organization.orgID}',
                  ),
                  leading: KitRowIcon(
                    AppIconography.account,
                    current: organization.active,
                  ),
                  title: organization.orgName,
                  trailing: organization.active
                      ? KitRowValue(copy.e7SharedCurrent, chevron: false)
                      : const KitChevron(),
                  onTap: organization.active
                      ? null
                      : () => _switch(organization),
                ),
            ],
          ),
        );
      }
      // Only one organization: nothing to switch to, said in words.
      if (organizations.every((organization) => organization.active)) {
        add(
          KitNotice(
            key: const Key('console-organization-only-one'),
            icon: AppIconography.info,
            message: copy.consoleOrganizationOnlyOne,
          ),
        );
      }
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

String _accountLabel(ConsoleOrganization organization) {
  final uri = Uri.tryParse(organization.accountUrl);
  final host = uri?.host.isNotEmpty == true
      ? uri!.host
      : organization.accountUrl;
  return '${organization.accountEmail} · $host';
}

String _basename(String path) {
  final parts = path
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty)
      .toList();
  return parts.isEmpty ? path : parts.last;
}

String _normalized(String path) =>
    path.replaceAll('\\', '/').replaceFirst(RegExp(r'/+$'), '');

bool _samePath(String a, String b) => _normalized(a) == _normalized(b);

bool _containsPath(String root, String path) {
  final normalizedRoot = _normalized(root);
  final normalizedPath = path.replaceAll('\\', '/');
  return normalizedPath == normalizedRoot ||
      normalizedPath.startsWith('$normalizedRoot/');
}

AppLocalizations _sharedCopy(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));
