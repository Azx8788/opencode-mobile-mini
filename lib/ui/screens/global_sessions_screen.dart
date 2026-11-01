import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/product_repository.dart';
import '../../domain/team_directories.dart';
import '../../feedback/bug_report.dart';
import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import '../app_theme.dart';
import '../kit/kit.dart';
import '../kit/scenes/states_scenes.dart';
import '../widgets/product_states.dart'
    show productErrorDetails, productErrorKind, productErrorText;
import '../widgets/relative_time.dart';
import '../widgets/session_handoff.dart';
import '../widgets/session_title.dart';
import 'session_import_screen.dart';
import 'session_relations_screen.dart';

/// All conversations (docs/ux-system/map/all.json `global-sessions`,
/// proposal "redesign"): every conversation on this server, search first.
/// A kit-only rebuild of today's layout: the pinned search with one project
/// filter menu (it never runs off screen), an Active / Archived choice
/// (archived conversations are a filter of this page, P3.12), one grouped
/// panel per project named by its project, and Work's row shape. Opening a
/// row switches Work to that conversation's project first.
///
/// Deferred to the Work redesign (wave 3): auto-paging for every list,
/// restoring an archived conversation (no unarchive call exists).
class GlobalSessionsScreen extends StatefulWidget {
  final ConnectionController controller;

  /// Opens on the Archived filter (Work's "Archived conversations" row).
  final bool archived;

  const GlobalSessionsScreen({
    super.key,
    required this.controller,
    this.archived = false,
  });

  @override
  State<GlobalSessionsScreen> createState() => _GlobalSessionsScreenState();
}

class _GlobalSessionsScope {
  const _GlobalSessionsScope({
    required this.profileID,
    required this.query,
    required this.includeArchived,
  });

  final String? profileID;
  final String query;
  final bool includeArchived;

  @override
  bool operator ==(Object other) =>
      other is _GlobalSessionsScope &&
      other.profileID == profileID &&
      other.query == query &&
      other.includeArchived == includeArchived;

  @override
  int get hashCode => Object.hash(profileID, query, includeArchived);
}

class _GlobalSessionsScreenState extends State<GlobalSessionsScreen> {
  static const _pageSize = 50;

  final _search = TextEditingController();
  final _scroll = ScrollController();
  List<GlobalSessionResult> _results = const [];

  /// The text the last invalidation saw: the controller also notifies on
  /// selection changes, which must not restart the search.
  String _lastText = '';

  /// The results this filter shows: every loaded one, or on the Archived
  /// filter only the archived ones.
  List<GlobalSessionResult> get _shown => _archived
      ? _results.where((result) => result.session.archived).toList()
      : _results;

  /// The shown results grouped by working directory, newest first: the
  /// groups are ordered by their most recent session, and each group lists
  /// its sessions from newest to oldest. Rebuilt on every build so a loaded
  /// page slots into the right group.
  List<_GlobalGroup> get _groups => _groupByDirectory(_shown, _l10n(context));

  /// The project filter narrows the list to one group; null shows every
  /// group.
  String? _folderFilter;

  static int _recency(GlobalSessionResult result) =>
      result.session.time?.updated ?? result.session.time?.created ?? 0;

  /// Whether a conversation waits on the person: a permission, a question
  /// or a form (what Work's rows call "Needs you").
  bool _needsYou(String sessionID) {
    final controller = widget.controller;
    return controller.permissionsForSession(sessionID).isNotEmpty ||
        controller.questionForSession(sessionID) != null ||
        controller.formForSession(sessionID) != null;
  }

  /// One project's rows by urgency: the ones that need the person, then
  /// the working ones, then the rest; newest first within each (the group
  /// arrives newest first, and the sort is stable).
  List<GlobalSessionResult> _byUrgency(List<GlobalSessionResult> results) {
    final busy = widget.controller.busySessions;
    int rank(GlobalSessionResult result) {
      final id = result.session.id;
      if (_needsYou(id)) return 0;
      if (busy.contains(id)) return 1;
      return 2;
    }

    final ranked = [for (final (i, r) in results.indexed) (rank(r), i, r)]
      ..sort((a, b) {
        final byRank = a.$1.compareTo(b.$1);
        return byRank != 0 ? byRank : a.$2.compareTo(b.$2);
      });
    return [for (final (_, _, result) in ranked) result];
  }

  /// The loaded conversations that need the person or are working, as one
  /// key: when it changes, the rows re-order and re-mark themselves.
  String _urgencyKey() {
    final busy = widget.controller.busySessions;
    return [
      for (final result in _results)
        if (_needsYou(result.session.id))
          '!${result.session.id}'
        else if (busy.contains(result.session.id))
          '~${result.session.id}',
    ].join(',');
  }

  String _lastUrgencyKey = '';

  static String _directoryOf(GlobalSessionResult result) {
    final value = (result.session.directory ?? result.projectDirectory)?.trim();
    return value == null || value.isEmpty
        ? ''
        : ConnectionController.normalizeDirectoryPath(value);
  }

  static List<_GlobalGroup> _groupByDirectory(
    List<GlobalSessionResult> results,
    AppLocalizations l10n,
  ) {
    final indexed = results.indexed.toList()
      ..sort((a, b) {
        final byRecency = _recency(b.$2).compareTo(_recency(a.$2));
        return byRecency != 0 ? byRecency : a.$1.compareTo(b.$1);
      });
    final groups = <String, List<GlobalSessionResult>>{};
    for (final (_, result) in indexed) {
      groups.putIfAbsent(_directoryOf(result), () => []).add(result);
    }
    // Two folders can share a name (a project and its worktree, or two
    // checkouts). Those get their parent folder in the label so the
    // filter and the section names stay distinguishable.
    final labels = {
      for (final entry in groups.entries)
        entry.key: _projectLabel(entry.value.first, l10n),
    };
    final counts = <String, int>{};
    for (final label in labels.values) {
      counts[label] = (counts[label] ?? 0) + 1;
    }
    return [
      for (final entry in groups.entries)
        _GlobalGroup(
          directory: entry.key,
          label: (counts[labels[entry.key]] ?? 0) > 1
              ? _pathTail(entry.key, fallback: labels[entry.key]!)
              : labels[entry.key]!,
          results: entry.value,
        ),
    ];
  }

  /// The last two path segments, `parent/name`, for a label that would
  /// otherwise collide with another folder's.
  static String _pathTail(String directory, {required String fallback}) {
    final parts = directory
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.length < 2) return fallback;
    return '${parts[parts.length - 2]}/${parts.last}';
  }

  static String _projectLabel(
    GlobalSessionResult result,
    AppLocalizations l10n,
  ) {
    final named = result.projectName?.trim();
    if (named?.isNotEmpty == true) return named!;
    return _basename(result.projectDirectory) ??
        _basename(result.session.directory) ??
        l10n.e7WorkspaceUnknownProject;
  }

  static String? _basename(String? path) {
    final parts = (path ?? '')
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    return parts.isEmpty ? null : parts.last;
  }

  Object? _error;
  late bool _archived = widget.archived;
  bool _loading = true;
  bool _loadingMore = false;
  String? _nextCursor;
  final Set<String> _usedCursors = {};
  bool _restartPagination = false;
  bool get _hasMore => _nextCursor != null;
  String? _openingSessionID;
  String? _stealingSessionID;
  int _queryGeneration = 0;

  /// A failed open or move, said above the list until dismissed.
  String? _notice;

  int _dataRefreshRevision = 0;
  ServerOperationsGateway? _activeRepository;
  String? _profileID;
  _GlobalSessionsScope? _loadedScope;
  bool _errorWasRefresh = false;

  _GlobalSessionsScope get _scope => _GlobalSessionsScope(
    profileID: widget.controller.profile?.id,
    query: _search.text.trim(),
    includeArchived: _archived,
  );

  bool _requestIsCurrent(
    int generation,
    _GlobalSessionsScope scope,
    ServerOperationsGateway repository,
  ) =>
      mounted &&
      generation == _queryGeneration &&
      scope == _scope &&
      identical(repository, widget.controller.repository);

  @override
  void initState() {
    super.initState();
    _dataRefreshRevision = widget.controller.dataRefreshRevision;
    _activeRepository = widget.controller.repository;
    _profileID = widget.controller.profile?.id;
    widget.controller.addListener(_controllerChanged);
    _scroll.addListener(_scrollChanged);
    _search.addListener(_searchTyped);
    unawaited(_reload());
  }

  void _controllerChanged() {
    if (!mounted) return;
    // A conversation starting, finishing or asking something moves its row
    // and changes its mark, without reloading the list.
    final urgency = _urgencyKey();
    if (urgency != _lastUrgencyKey) {
      _lastUrgencyKey = urgency;
      setState(() {});
    }
    final revision = widget.controller.dataRefreshRevision;
    final repository = widget.controller.repository;
    final profileID = widget.controller.profile?.id;
    final profileChanged = profileID != _profileID;
    final repositoryChanged = !identical(repository, _activeRepository);
    // Location selection and chat refreshes must not discard older pages.
    if ((_openingSessionID != null || _stealingSessionID != null) &&
        !profileChanged &&
        !repositoryChanged) {
      _dataRefreshRevision = revision;
      _activeRepository = repository;
      return;
    }
    if (revision == _dataRefreshRevision &&
        !repositoryChanged &&
        !profileChanged) {
      return;
    }
    // A replacement transport must retire delayed pages even though the
    // server-wide list remains logically scoped to the same profile.
    if (repositoryChanged || profileChanged) _queryGeneration++;
    if (profileID == _profileID && _results.isNotEmpty) {
      // The global inventory is profile-scoped, not location-scoped. Keep the
      // search, cursor chain and loaded older rows until an explicit refresh.
      _dataRefreshRevision = revision;
      _activeRepository = repository;
      // Rebuild callbacks against the current location after reconnecting.
      // Keeping the rows must not keep their retired navigation guards.
      setState(() {
        // A replacement repository retires any request it was serving. The
        // retained rows and cursor chain remain available for a retry.
        if (repositoryChanged) {
          _loading = false;
          _loadingMore = false;
          _error = null;
          _errorWasRefresh = false;
        }
      });
      return;
    }
    _dataRefreshRevision = revision;
    _activeRepository = repository;
    _profileID = profileID;
    unawaited(_reload());
  }

  void _scrollChanged() {
    if (!_scroll.hasClients ||
        _scroll.position.extentAfter > 280 ||
        !_hasMore ||
        _error != null ||
        _loadingMore) {
      return;
    }
    unawaited(_loadMore());
  }

  /// The Archived filter keeps paging by itself while the loaded pages hold
  /// too few archived conversations to fill the screen: the server has no
  /// archived-only query, so the filter narrows what it sends.
  void _fillArchived() {
    if (!_archived || !_hasMore) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_archived || _error != null || _loading) return;
      if (_scroll.hasClients) {
        _scrollChanged();
      } else {
        unawaited(_loadMore());
      }
    });
  }

  /// Every keystroke retires in-flight pages at once; the field reports the
  /// settled query to [_searchSettled].
  void _searchTyped() {
    final text = _search.text;
    if (text == _lastText) return;
    _lastText = text;
    setState(() {
      _queryGeneration++;
      _loading = true;
      _loadingMore = false;
      _nextCursor = null;
      _usedCursors.clear();
      _restartPagination = false;
      _error = null;
      _errorWasRefresh = false;
      if (_loadedScope != _scope) {
        _results = const [];
        _loadedScope = null;
      }
    });
  }

  void _searchSettled(String _) {
    if (mounted) unawaited(_reload());
  }

  void _clearSearch() {
    _search.clear();
    unawaited(_reload());
  }

  void _setArchived(bool archived) {
    setState(() {
      _archived = archived;
      _folderFilter = null;
    });
    unawaited(_reload());
  }

  Future<ServerOperationsGateway> _repository() async {
    final repository = await widget.controller.prepareActionRepository();
    if (repository != null) return repository;
    if (!mounted) throw StateError('Session search closed');
    throw ProductException(_l10n(context).e7WorkspaceReconnectingAgain);
  }

  Future<void> _reload() async {
    final generation = ++_queryGeneration;
    final scope = _scope;
    final retainRows = _loadedScope == scope && _results.isNotEmpty;
    final previousCursor = _nextCursor;
    final previousCursors = Set<String>.of(_usedCursors);
    final previousRestartPagination = _restartPagination;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
      _errorWasRefresh = false;
      if (!retainRows) {
        _nextCursor = null;
        _usedCursors.clear();
        _restartPagination = false;
        _results = const [];
        _loadedScope = null;
      }
    });
    try {
      final repository = await _repository();
      if (!_requestIsCurrent(generation, scope, repository)) return;
      final results = await repository.listGlobalSessions(
        search: scope.query,
        includeArchived: scope.includeArchived,
        limit: _pageSize,
      );
      if (!_requestIsCurrent(generation, scope, repository)) return;
      setState(() {
        final seen = <String>{};
        _results = results.items
            .where(
              (result) =>
                  !isAiTeamConversation(result) && seen.add(result.session.id),
            )
            .toList();
        _nextCursor = results.hasMore ? results.nextCursor : null;
        _usedCursors.clear();
        _restartPagination = false;
        _loadedScope = scope;
      });
    } catch (error) {
      if (!mounted || generation != _queryGeneration || scope != _scope) {
        return;
      }
      setState(() {
        if (retainRows) {
          _nextCursor = previousCursor;
          _usedCursors
            ..clear()
            ..addAll(previousCursors);
          _restartPagination = previousRestartPagination;
          _errorWasRefresh = true;
        } else {
          _results = const [];
          _loadedScope = null;
        }
        _error = error;
      });
    } finally {
      if (mounted && generation == _queryGeneration && scope == _scope) {
        setState(() => _loading = false);
        if (_error == null) _fillArchived();
      }
    }
  }

  Future<void> _loadMore() async {
    final failureMessage = _l10n(context).e7WorkspacePaginationStuck;
    final generation = _queryGeneration;
    final scope = _scope;
    final cursor = _nextCursor;
    if (_loading || _loadingMore || !_hasMore || cursor == null) return;
    setState(() {
      _loadingMore = true;
      _error = null;
      _errorWasRefresh = false;
    });
    try {
      final repository = await _repository();
      if (!_requestIsCurrent(generation, scope, repository)) return;
      final page = await repository.listGlobalSessions(
        search: scope.query,
        includeArchived: scope.includeArchived,
        cursor: cursor,
        limit: _pageSize,
      );
      if (!_requestIsCurrent(generation, scope, repository)) return;
      final existing = _results.map((result) => result.session.id).toSet();
      final added = page.items
          .where(
            (result) =>
                !isAiTeamConversation(result) &&
                existing.add(result.session.id),
          )
          .toList();
      final nextCursor = page.hasMore ? page.nextCursor : null;
      if (nextCursor != null &&
          (nextCursor == cursor || _usedCursors.contains(nextCursor))) {
        _restartPagination = true;
        throw ProductException(failureMessage);
      }
      setState(() {
        _results = [..._results, ...added];
        _usedCursors.add(cursor);
        _nextCursor = nextCursor;
      });
    } catch (error) {
      if (mounted && generation == _queryGeneration && scope == _scope) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted && generation == _queryGeneration && scope == _scope) {
        setState(() => _loadingMore = false);
        if (_error == null) _fillArchived();
      }
    }
  }

  void _say(Object error) {
    if (!mounted) return;
    setState(() => _notice = productErrorText(error, l10n: _l10n(context)));
  }

  Future<void> _open(
    GlobalSessionResult result, {
    bool related = false,
    bool handoff = false,
  }) async {
    final session = result.session;
    if (_openingSessionID != null) return;
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(session.id)) {
      _say(ProductException(_l10n(context).e7WorkspaceReferenceRetry));
      return;
    }
    final profileID = widget.controller.profile?.id;
    final directory = session.directory ?? result.projectDirectory;
    if (profileID != _profileID || directory == null) {
      _say(ProductException(_l10n(context).e7WorkspaceLocationRetry));
      return;
    }
    setState(() {
      _openingSessionID = session.id;
      _notice = null;
    });
    try {
      // Opening switches Work to the conversation's project first.
      await widget.controller.selectLocationForExistingSession(
        directory: directory,
        workspace: session.workspaceID,
      );
      if (!mounted) return;
      if (widget.controller.profile?.id != profileID ||
          widget.controller.directory != directory ||
          widget.controller.workspace != session.workspaceID) {
        throw ProductException(_l10n(context).e7WorkspaceLocationChangedReturn);
      }
      // Speed contract item 2: the conversation's newest history is read
      // while its details are checked; the chat joins that same read.
      if (!handoff && !related) {
        unawaited(widget.controller.prefetchSessionTail(session.id));
      }
      final scope = SessionNavigationScope(widget.controller);
      final repository = await _repository();
      scope.check(widget.controller);
      final current = await repository.getSessionDetails(session.id);
      scope.check(widget.controller);
      if (!mounted) return;
      if (current.id != session.id ||
          current.directory != session.directory ||
          current.workspaceID != session.workspaceID) {
        throw ProductException(_l10n(context).e7WorkspaceLocationChangedRetry);
      }
      if (handoff) {
        await showSessionHandoff(
          context,
          controller: widget.controller,
          sessionID: current.id,
          projectID: current.projectID,
        );
      } else if (related) {
        final selected = await pushKitPage<Session>(
          context,
          (_) => SessionRelationsScreen(
            controller: widget.controller,
            sessionID: session.id,
          ),
        );
        scope.check(widget.controller);
        if (!mounted || selected == null) return;
        if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(selected.id)) {
          throw ProductException(
            _l10n(context).e7WorkspaceReferenceUnavailable,
          );
        }
        await Navigator.of(context).pushNamed('/chat/${selected.id}');
      } else {
        await Navigator.of(context).pushNamed('/chat/${session.id}');
      }
    } catch (error) {
      _say(error);
    } finally {
      if (mounted) setState(() => _openingSessionID = null);
    }
  }

  /// True when a steal can genuinely move this session here. Live OpenCode
  /// 1.18.23 refuses `/sync/steal` (BadRequest) for plain cross-directory
  /// sessions — steal operates on the workspace sync system only, and plain
  /// directory transfer remains the /move workflow. So the affordance shows
  /// only when a workspace is involved on either side, never for ordinary
  /// cross-project rows.
  bool _isElsewhere(GlobalSessionResult result) {
    final active = widget.controller.directory?.trim() ?? '';
    if (active.isEmpty) return false;
    final activeWorkspace = widget.controller.workspace?.trim() ?? '';
    final sessionWorkspace = result.session.workspaceID?.trim() ?? '';
    if (sessionWorkspace.isEmpty && activeWorkspace.isEmpty) return false;
    if (sessionWorkspace != activeWorkspace) return true;
    final sessionDirectory =
        (result.session.directory ?? result.projectDirectory)?.trim() ?? '';
    return sessionDirectory.isNotEmpty && sessionDirectory != active;
  }

  /// The current project's name, for the move question.
  String _currentProjectLabel(AppLocalizations l10n) {
    final active = widget.controller.directory?.trim() ?? '';
    if (active.isEmpty) return l10n.e7WorkspaceUnknownProject;
    final normalized = ConnectionController.normalizeDirectoryPath(active);
    for (final result in _results) {
      if (_directoryOf(result) == normalized) {
        return _projectLabel(result, l10n);
      }
    }
    return _basename(active) ?? l10n.e7WorkspaceUnknownProject;
  }

  /// "Continue here" (`global-sessions-continue-here-sheet`): a question
  /// naming both projects, whether it can be moved back, and that a
  /// working conversation is interrupted. The move runs inside the
  /// question, so a failure keeps it open with Try again.
  Future<void> _steal(GlobalSessionResult result) async {
    final session = result.session;
    if (_stealingSessionID != null || _openingSessionID != null) return;
    final l10n = _l10n(context);
    final scope = SessionNavigationScope(widget.controller);
    final title = presentedSessionTitle(
      session,
      fallback: l10n.globalSessionsUntitled,
      l10n: l10n,
    );
    final from = _projectLabel(result, l10n);
    final to = _currentProjectLabel(l10n);
    final working = widget.controller.busySessions.contains(session.id);
    String? stolenID;
    // Kept while the question is open so refreshes keep older pages; the
    // question itself shows the move working.
    _stealingSessionID = session.id;
    if (_notice != null) setState(() => _notice = null);
    try {
      final moved = await showKitConfirm(
        context,
        icon: AppIconography.inbox,
        title: l10n.globalSessionsMoveTitle(to),
        body: l10n.globalSessionsMoveBody(title, from, to),
        confirmLabel: l10n.e7SharedMoveSession,
        consequenceItems: [
          if (working)
            KitConsequence(
              l10n.globalSessionsMoveWhileWorking,
              mark: KitConsequenceMark.lost,
            ),
          KitConsequence(l10n.globalSessionsMoveBack(from)),
        ],
        confirmKey: const ValueKey('global-sessions-move-confirm'),
        action: () async {
          scope.check(widget.controller);
          final repository = await _repository();
          scope.check(widget.controller);
          final id = await repository.stealSessionIntoWorkspace(session.id);
          scope.check(widget.controller);
          if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
            throw ProductException(l10n.e7WorkspaceReferenceUnavailable);
          }
          stolenID = id;
        },
      );
      final id = stolenID;
      if (!moved || id == null || !mounted) return;
      await Navigator.of(context).pushNamed('/chat/$id');
    } catch (error) {
      _say(error);
    } finally {
      _stealingSessionID = null;
    }
  }

  /// The server takes an exported conversation file.
  bool get _canImport {
    final repository = widget.controller.repository;
    return widget.controller.capabilities.sessionImportExport &&
        repository is SessionImportGateway &&
        (repository as SessionImportGateway).sessionImportSupported;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final tokens = KitTokens.of(context);
    final groups = _groups;
    final filter = groups.any((group) => group.directory == _folderFilter)
        ? _folderFilter
        : null;
    final visible = filter == null
        ? groups
        : groups.where((group) => group.directory == filter).toList();
    final query = _search.text.trim();
    final activeFilter = filter == null
        ? null
        : groups.firstWhere((group) => group.directory == filter).label;

    return KitScreen(
      width: KitScreenWidth.list,
      // Importing adds a conversation to this list, so it lives in this
      // page's menu (R2), not among the agent's settings.
      topBar: KitTopBar(
        title: l10n.globalSessionsTitle,
        menu: [
          if (_canImport)
            KitMenuItem(
              key: const ValueKey('global-sessions-import'),
              label: l10n.libraryImportAConversation,
              icon: AppIconography.fileUpload,
              onSelected: () => unawaited(
                pushKitPage<void>(
                  context,
                  (_) => SessionImportScreen(controller: widget.controller),
                ),
              ),
            ),
        ],
      ),
      // 1. Search first: the page exists to find one conversation among
      // every project on the server. The project filter is one menu, so
      // any number of projects fits.
      search: KitSearchField(
        label: l10n.globalSessionsSearchLabel,
        controller: _search,
        onChanged: _searchSettled,
        resultCount: query.isEmpty || _loading ? null : _shown.length,
        partial: _hasMore,
        filters: [
          if (groups.length > 1)
            for (final group in groups)
              KitMenuItem(
                key: ValueKey('global-session-folder-${group.directory}'),
                label: group.label,
                icon: AppIconography.folders,
                checked: filter == group.directory,
                onSelected: () => setState(
                  () => _folderFilter = filter == group.directory
                      ? null
                      : group.directory,
                ),
              ),
        ],
        activeFilter: activeFilter,
        onClearFilter: () => setState(() => _folderFilter = null),
        fieldKey: const ValueKey('global-session-search'),
        filterKey: const ValueKey('global-session-filters'),
      ),
      // 2. Active or archived: the filters stay live over an error.
      header: [
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            tokens.gutter,
            tokens.space1,
            tokens.gutter,
            tokens.space2,
          ),
          child: KitSegmented<bool>(
            semanticsLabel: l10n.globalSessionsFilterLabel,
            selected: _archived,
            onChanged: _setArchived,
            segments: [
              KitSegment(
                key: const ValueKey('global-sessions-active'),
                value: false,
                label: l10n.globalSessionsFilterActive,
              ),
              KitSegment(
                key: const ValueKey('include-archived-sessions'),
                value: true,
                label: l10n.globalSessionsArchivedShort,
                icon: AppIconography.archive,
              ),
            ],
          ),
        ),
      ],
      loading: _loading || _loadingMore,
      loadingLabel: l10n.globalSessionsRefresh,
      body: _content(context, groups, visible, filter, l10n),
    );
  }

  Widget _content(
    BuildContext context,
    List<_GlobalGroup> groups,
    List<_GlobalGroup> visible,
    String? filter,
    AppLocalizations l10n,
  ) {
    final tokens = KitTokens.of(context);
    final rails = EdgeInsets.symmetric(horizontal: tokens.gutter);
    if (_loading && _results.isEmpty) {
      return ListView(
        key: const ValueKey('global-sessions-loading'),
        physics: const NeverScrollableScrollPhysics(),
        children: const [KitSkeletonRows(count: 7)],
      );
    }
    if (_error != null && _results.isEmpty) {
      final retry = _hasMore && !_restartPagination ? _loadMore : _reload;
      // Every load failure draws the unplugged cable (design standard §10).
      return KitStateView(
        key: const ValueKey('global-sessions-load-failed'),
        icon: AppIconography.error,
        tone: AppStatusTone.failure,
        illustration: const StatesUnpluggedScene(),
        title: l10n.globalSessionsLoadFailedTitle,
        body: productErrorText(_error!, l10n: l10n),
        details: productErrorDetails(_error),
        primary: KitAction(
          label: l10n.commonRetry,
          onPressed: () => unawaited(retry()),
        ),
        tertiary: [
          KitAction(
            key: const ValueKey('product-error-report-bug'),
            label: l10n.e7LibraryReportABug,
            onPressed: () => unawaited(openBugReport(context)),
          ),
        ],
      );
    }
    if (_shown.isEmpty && !_hasMore && !_loadingMore) {
      final query = _search.text.trim();
      if (query.isNotEmpty) {
        // A search that found nothing is the magnifier.
        return KitStateView(
          key: const ValueKey('global-sessions-no-match'),
          icon: AppIconography.searchList,
          illustration: const StatesSearchScene(),
          title: l10n.globalSessionsNoMatchTitle,
          body: _archived
              ? l10n.globalSessionsArchivedNoMatchMessage
              : l10n.globalSessionsNoMatchMessage,
          secondary: KitAction(
            label: l10n.commonClearSearch,
            onPressed: _clearSearch,
          ),
        );
      }
      // Nothing yet is the fresh sheet.
      return KitStateView(
        key: ValueKey(
          _archived
              ? 'global-sessions-archived-empty'
              : 'global-sessions-empty',
        ),
        icon: _archived ? AppIconography.archive : AppIconography.searchList,
        illustration: const StatesSheetScene(),
        title: _archived
            ? l10n.globalSessionsArchivedEmptyTitle
            : l10n.globalSessionsEmptyTitle,
        body: _archived
            ? l10n.globalSessionsArchivedEmptyMessage
            : l10n.globalSessionsEmptyMessage,
        secondary: _archived
            ? KitAction(
                label: l10n.globalSessionsShowActive,
                onPressed: () => _setArchived(false),
              )
            : null,
        tertiary: [
          if (!_archived)
            KitAction(
              label: l10n.globalSessionsRefresh,
              onPressed: () => unawaited(_reload()),
            ),
        ],
      );
    }

    final scope = SessionNavigationScope(widget.controller);
    void guarded(VoidCallback action) {
      if (!scope.matches(widget.controller)) {
        _say(ProductException(_l10n(context).e7WorkspaceLocationChangedReturn));
        return;
      }
      action();
    }

    final current = widget.controller.directory?.trim() ?? '';
    final currentDirectory = current.isEmpty
        ? null
        : ConnectionController.normalizeDirectoryPath(current);
    final notice = _notice;

    // 3. One panel per project, newest project first, each row a
    // conversation newest first. The section names the project, so rows
    // keep only what differs between them.
    return KitRefresh(
      onRefresh: _reload,
      child: ListView(
        key: const PageStorageKey('global-sessions-list'),
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsetsDirectional.only(
          bottom: KitScreen.endPadding(context),
        ),
        children: [
          if (notice != null)
            Padding(
              padding: rails.add(
                EdgeInsetsDirectional.only(bottom: tokens.space3),
              ),
              child: KitNotice(
                key: const ValueKey('global-sessions-notice'),
                message: notice,
                tone: AppStatusTone.failure,
                icon: AppIconography.warning,
                onDismiss: () => setState(() => _notice = null),
                dismissLabel: l10n.workspaceDismissNotice,
              ),
            ),
          // Each project's label keeps the section gap from what is above
          // it (none for the first); the page title and the rows already
          // say how many there are, so no count is repeated.
          for (final group in visible)
            KitRowGroup(
              key: ValueKey('global-session-group-${group.directory}'),
              label: group.directory == currentDirectory
                  ? l10n.globalSessionsProjectInUse(group.label)
                  : group.label,
              children: [
                for (final result in _byUrgency(group.results))
                  _GlobalSessionRow(
                    controller: widget.controller,
                    result: result,
                    unknownLocation: l10n.globalSessionsUnknownLocation,
                    opening: _openingSessionID == result.session.id,
                    needsYou: _needsYou(result.session.id),
                    onTap: () => guarded(() => _open(result)),
                    onRelated: () =>
                        guarded(() => _open(result, related: true)),
                    onHandoff: () =>
                        guarded(() => _open(result, handoff: true)),
                    // §7 row 7: "Continue here" is steal + sync-start,
                    // neither of which v2 has. A future rebuild is
                    // export+import+move.
                    onSteal:
                        widget.controller.capabilities.sessionSteal &&
                            _isElsewhere(result)
                        ? () => guarded(() => unawaited(_steal(result)))
                        : null,
                  ),
              ],
            ),
          if (_footer(l10n) case final footer?)
            Padding(
              padding: visible.isEmpty
                  ? rails
                  : rails.add(
                      EdgeInsetsDirectional.only(top: tokens.sectionGap),
                    ),
              child: footer,
            ),
        ],
      ),
    );
  }

  /// The paging tail: a load error with Try again, or the explicit Load
  /// more control. Null once everything is in; a page on its way is the
  /// screen's one loading bar.
  Widget? _footer(AppLocalizations l10n) {
    if (_error != null) {
      // What failed in the title, why in words, the raw text only behind
      // Copy details (never "ApiException: … page 2" as the words).
      return KitNotice.error(
        key: const ValueKey('global-sessions-page-failed'),
        title: _errorWasRefresh
            ? l10n.globalSessionsRefreshFailed
            : l10n.globalSessionsLoadMoreFailed,
        message: productErrorText(_error!, l10n: l10n),
        error: _error,
        errorKind: productErrorKind(_error),
        details: productErrorDetails(_error),
        reportSource: 'global-sessions',
        copyDetailsKey: const ValueKey('global-sessions-page-failed-copy'),
        retry: KitAction(
          label: l10n.commonRetry,
          onPressed: _errorWasRefresh || _restartPagination
              ? () => unawaited(_reload())
              : () => unawaited(_loadMore()),
        ),
      );
    }
    if (_hasMore && !_loading && !_loadingMore) {
      return KitButton.secondary(
        key: const ValueKey('global-sessions-load-more'),
        label: l10n.globalSessionsLoadMore,
        onPressed: () => unawaited(_loadMore()),
      );
    }
    return null;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    _scroll
      ..removeListener(_scrollChanged)
      ..dispose();
    _search
      ..removeListener(_searchTyped)
      ..dispose();
    super.dispose();
  }
}

/// The loaded results for one working directory, newest session first.
class _GlobalGroup {
  const _GlobalGroup({
    required this.directory,
    required this.label,
    required this.results,
  });

  /// Normalized working directory; empty when the server reported none.
  final String directory;
  final String label;
  final List<GlobalSessionResult> results;
}

/// One conversation in Work's row shape: a leading chat tile (or the
/// working mark), the title in the person's own words, and a supporting
/// line that leads with its state word. Rare acts open on long-press,
/// right-click and as semantic actions (KIT-28).
class _GlobalSessionRow extends StatelessWidget {
  final ConnectionController controller;
  final GlobalSessionResult result;
  final String unknownLocation;
  final bool opening;

  /// A permission, question or form waits on the person.
  final bool needsYou;
  final VoidCallback onTap;
  final VoidCallback onRelated;
  final VoidCallback onHandoff;
  final VoidCallback? onSteal;

  const _GlobalSessionRow({
    required this.controller,
    required this.result,
    required this.unknownLocation,
    required this.opening,
    this.needsYou = false,
    required this.onTap,
    required this.onRelated,
    required this.onHandoff,
    this.onSteal,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final tokens = KitTokens.of(context);
    final session = result.session;
    final title = presentedSessionTitle(
      session,
      fallback: l10n.globalSessionsUntitled,
      l10n: l10n,
    );
    final working = !needsYou && controller.busySessions.contains(session.id);
    final unread = !needsYou && !working && controller.isSessionUnread(session);
    final updated = session.time?.updated ?? session.time?.created;
    final directory = (session.directory ?? result.projectDirectory)?.trim();
    final busy = opening;
    // The state word leads (STATE-9): "Needs you", "Working", "Archived",
    // "Unread result" at label weight, then the muted facts.
    final state = working
        ? l10n.globalSessionsWorking
        : session.archived
        ? l10n.globalSessionsArchivedShort
        : unread
        ? l10n.sessionUnread
        : null;
    final facts = [
      if (updated != null && updated > 0)
        relativeTimeLabel(updated, l10n: l10n),
      if (session.path?.trim().isNotEmpty == true) session.path!.trim(),
    ];
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.25;
    Widget lead(Widget child) => SizedBox.square(
      dimension: tokens.iconTileSize,
      child: Center(child: child),
    );
    return KitRow(
      key: ValueKey('global-session-${session.id}'),
      titleMaxLines: 2,
      supportingMaxLines: largeText ? 3 : 2,
      leading: needsYou && !busy
          ? lead(
              KitNeedsYou.mark(
                key: ValueKey('global-session-needs-you-${session.id}'),
              ),
            )
          : busy || working
          ? lead(const KitTaskMark(state: KitTaskState.working))
          : KitRow.icon(
              context,
              session.archived ? AppIconography.archive : AppIconography.chat,
            ),
      title: title,
      supporting: !needsYou && state == null && facts.isEmpty
          ? null
          : TextSpan(
              children: [
                if (needsYou) KitNeedsYou.span(context),
                if (state != null)
                  TextSpan(
                    text: state,
                    style: KitText.styleOf(
                      context,
                      KitTextRole.label,
                      tone: KitTextTone.primary,
                    ),
                  ),
                if (facts.isNotEmpty)
                  TextSpan(
                    text: state == null
                        ? facts.join(' · ')
                        : facts.map((fact) => ' · $fact').join(),
                  ),
              ],
            ),
      onTap: busy ? null : onTap,
      menuLabel: l10n.globalSessionsActions,
      menu: busy
          ? const []
          : [
              KitMenuItem(
                key: const ValueKey('global-session-menu-open'),
                label: l10n.globalSessionsOpen,
                icon: AppIconography.externalLink,
                onSelected: onTap,
              ),
              KitMenuItem(
                key: ValueKey('global-session-related-${session.id}'),
                label: l10n.sessionOpenRelated,
                icon: AppIconography.link,
                onSelected: onRelated,
              ),
              KitMenuItem(
                key: ValueKey('global-session-handoff-${session.id}'),
                label: l10n.sessionCopyHandoff,
                icon: AppIconography.copy,
                onSelected: onHandoff,
              ),
              if (onSteal != null)
                KitMenuItem(
                  key: ValueKey('steal-session-${session.id}'),
                  label: l10n.globalSessionsContinueHere,
                  icon: AppIconography.inbox,
                  onSelected: onSteal!,
                ),
              KitMenuItem.copy(
                key: ValueKey('global-session-copy-folder-${session.id}'),
                label: l10n.globalSessionsCopyFolder,
                text: () => directory?.isNotEmpty == true
                    ? directory!
                    : unknownLocation,
              ),
            ],
    );
  }
}

AppLocalizations _l10n(BuildContext context) =>
    Localizations.of<AppLocalizations>(context, AppLocalizations) ??
    lookupAppLocalizations(Localizations.localeOf(context));
