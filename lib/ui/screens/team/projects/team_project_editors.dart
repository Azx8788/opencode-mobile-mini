import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../domain/relative_age.dart';
import '../../../../builtin/builtin_linux.dart';
import '../../../../builtin/builtin_server.dart' show BuiltinProjectFolders;
import '../../../../domain/server_gateway.dart' show CatalogModel;
import '../../../../state/team_model.dart' show teamModelSpec;
import '../../../../state/team_project_controller.dart';
import '../../../app_theme.dart' show AppStatusTone;
import '../../../kit/kit.dart';
import '../../project_folder_actions.dart';
import '../team_model_sheet.dart';
import 'team_execution_gate.dart';
import 'team_refusal.dart';

part 'team_project_editors_roles.dart';

/// Opens the team's model sheet for a role; [fallback] picks the fallback
/// model. Null means the sheet was dismissed.
typedef TeamRolesModelPicker =
    Future<TeamModelChoice?> Function(
      BuildContext context, {
      required String? current,
      required bool fallback,
    });

/// Picks the repo folder (the phone's folder browser). Null: dismissed, or
/// the person chose to type a path.
typedef TeamFolderPicker = Future<String?> Function(BuildContext context);

/// Tests hand in a picker and a first-commit maker; the app uses the phone's
/// own folder browser and its Ubuntu.
@visibleForTesting
TeamFolderPicker? teamFolderPickerOverride;
@visibleForTesting
Future<void> Function(String path)? teamFirstCommitOverride;
@visibleForTesting
Future<bool> Function(String path)? teamRepoEmptyOverride;

Future<void> openTeamNewProject(
  BuildContext context,
  TeamProjectController controller, {
  bool quick = false,
}) => _open(context, controller, quick ? _Kind.quick : _Kind.create);
Future<void> openTeamSpecEditor(
  BuildContext context,
  TeamProjectController controller,
  String projectId,
) => _open(context, controller, _Kind.spec, projectId);
Future<void> openTeamPlanEditor(
  BuildContext context,
  TeamProjectController controller,
  String projectId,
) => _open(context, controller, _Kind.plan, projectId);
Future<void> openTeamProjectSettings(
  BuildContext context,
  TeamProjectController controller,
  String projectId,
) => _open(context, controller, _Kind.settings, projectId);
Future<void> openTeamRoles(
  BuildContext context,
  TeamProjectController controller, {
  TeamRolesModelPicker? modelPicker,
}) => _open(context, controller, _Kind.roles, '', modelPicker);

/// Team settings. [focusPlannerModel] opens it on the Planner's model choice
/// (the recovery for a plan that failed on its model); [retryProjectId] is the
/// project to offer "Ask again" for once that choice is saved.
Future<void> openTeamDefaults(
  BuildContext context,
  TeamProjectController controller, {
  bool focusPlannerModel = false,
  String? retryProjectId,
  TeamRolesModelPicker? modelPicker,
}) => _open(
  context,
  controller,
  _Kind.defaults,
  '',
  modelPicker,
  focusPlannerModel,
  retryProjectId,
);

enum _Kind { create, quick, spec, plan, settings, roles, defaults }

Future<void> _open(
  BuildContext context,
  TeamProjectController controller,
  _Kind kind, [
  String projectId = '',
  TeamRolesModelPicker? modelPicker,
  bool focusPlannerModel = false,
  String? retryProjectId,
]) async {
  final gate = TeamExecutionGate.of(controller);
  final startsWork =
      kind == _Kind.create ||
      kind == _Kind.quick ||
      (kind == _Kind.plan &&
          controller.snapshot?.projects
                  .where((p) => p.id == projectId)
                  .firstOrNull
                  ?.status ==
              'plan');
  if (gate != null && startsWork && !gate.permits(TeamExecutionNeed.lanes)) {
    // Not a form that cannot be sent: the one line and the fix.
    final l = lookupAppLocalizations(Localizations.localeOf(context));
    if (await showKitConfirm(
      context,
      title: l.phoneTeamBlockedTitle,
      body: l.phoneTeamBlocked,
      confirmLabel: l.teamIntroTurnOnPhone,
      cancelLabel: l.phoneTeamStopCancel,
    )) {
      if (context.mounted) await gate.setUp(context);
    }
    return;
  }
  await showKitFramedSheet<void>(
    context,
    builder: (_) => _Editor(
      controller: controller,
      kind: kind,
      projectId: projectId,
      modelPicker: modelPicker ?? _gatePicker(controller),
      focusPlannerModel: focusPlannerModel,
      retryProjectId: retryProjectId,
    ),
  );
}

/// The phone's model catalog, when the page that owns the team bound one;
/// the simulated demo has no catalog and keeps typed names.
TeamRolesModelPicker? _gatePicker(TeamProjectController controller) {
  final connection = TeamExecutionGate.of(controller)?.connection;
  if (connection == null) return null;
  return (context, {required current, required fallback}) {
    final l = lookupAppLocalizations(Localizations.localeOf(context));
    unawaited(connection.ensureCatalog());
    return showTeamModelSheet(
      context,
      connection: connection,
      current: current,
      title: fallback ? l.teamProjectEditorFallback : l.teamProjectEditorModel,
      defaultTitle: fallback
          ? l.teamProjectEditorNoFallback
          : l.teamModelServerDefault,
      defaultHint: fallback
          ? l.teamProjectEditorNoFallbackHint
          : l.teamModelServerDefaultHint,
    );
  };
}

/// Keeps the KitField draft contract while delegating every persistent
/// operation to the deletion-aware, redacting controller writer.
class _ControllerDraft extends KitDraft {
  _ControllerDraft({
    required super.target,
    required this.owner,
    required super.controller,
    required this.isAlive,
    required this.onFailure,
  }) : super(profileId: owner.profileId);
  final TeamProjectController owner;
  final bool Function() isAlive;
  final VoidCallback onFailure;

  @override
  Future<void> save() async {
    final value = controller.text;
    try {
      await owner.saveEditorDraft(target, value);
    } catch (_) {
      if (isAlive()) onFailure();
    }
  }

  @override
  Future<void> restore() async {
    try {
      final value = await owner.readEditorDraft(target);
      if (isAlive() &&
          value != null &&
          value.isNotEmpty &&
          controller.text.isEmpty) {
        controller.text = value;
      }
    } catch (_) {
      if (isAlive()) onFailure();
    }
  }

  @override
  Future<void> clear() => owner.clearEditorDraft(target);
}

class _Editor extends StatefulWidget {
  const _Editor({
    required this.controller,
    required this.kind,
    required this.projectId,
    this.modelPicker,
    this.focusPlannerModel = false,
    this.retryProjectId,
  });
  final TeamProjectController controller;
  final _Kind kind;
  final String projectId;
  final TeamRolesModelPicker? modelPicker;
  final bool focusPlannerModel;
  final String? retryProjectId;
  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  final Map<String, TextEditingController> _fields = {};
  final Map<String, KitDraft> _fieldDrafts = {};
  late final String _draftTarget;
  bool _restoring = true;
  bool _complete = false;
  int? _reviewedRevision;
  late TeamProjectSettings _settings;
  late List<TeamRepo> _repos;
  late List<TeamMilestone> _milestones;
  late List<TeamTask> _tasks;
  late List<TeamPhase> _phases;
  String? _serverId;
  String? _roleId;
  String? _budgetChoice;
  String? _error;
  TeamRefusal? _refusal;
  bool _working = false;
  bool _planFirst = true;
  bool _history = false;
  bool _chargingTouched = false;
  bool _typePath = false;
  bool _draftRestored = false;
  bool _starterSeeded = false;
  bool _makingCommit = false;
  bool _repoEmpty = false;
  final GlobalKey _noticeKey = GlobalKey();
  String? _commitFailure;
  String? _askAgainProject;
  TeamProjectRole? _role;
  int _id = 0;
  TeamProjectController get _controller => widget.controller;
  String get _contextFilesHelp => _controller.snapshot?.simulated == false
      ? _l.teamProjectEditorContextFilesHelpReal
      : _l.teamProjectEditorContextFilesHelp;
  TeamProject? get _project => _controller.snapshot?.projects
      .where((p) => p.id == widget.projectId)
      .firstOrNull;
  AppLocalizations get _l => AppLocalizations.of(context);
  bool get _creating =>
      widget.kind == _Kind.create || widget.kind == _Kind.quick;
  String _newId() => 'edit-${DateTime.now().microsecondsSinceEpoch}-${_id++}';

  @override
  void initState() {
    super.initState();
    final p = _project;
    _reviewedRevision = p?.revision;
    final defaults =
        _controller.snapshot?.defaultSettings ?? const TeamProjectSettings();
    _settings =
        p?.settings ?? (_creating ? _creationDefaults(defaults) : defaults);
    _repos = [...?p?.repos];
    _milestones = [...?p?.specDraft.milestones];
    // A first-time spec is not a blank acceptance-criteria form: one
    // milestone, drafted from the task the person typed, ready to edit.
    if (widget.kind == _Kind.spec && p != null && _milestones.isEmpty) {
      final goal = p.specDraft.goal.trim();
      if (goal.isNotEmpty) {
        final line = goal.split('\n').first.trim();
        _milestones = [
          TeamMilestone(
            id: _newId(),
            title: line.length > 60 ? '${line.substring(0, 60).trim()}…' : line,
            criteria: [line],
          ),
        ];
        _starterSeeded = true;
      }
    }
    _tasks = [...?p?.tasks];
    _phases = [...?p?.phases];
    if (_settings.budget.chosen) {
      _budgetChoice = _settings.budget.unlimited ? 'unlimited' : 'limited';
    }
    _text('name', p?.name ?? '');
    _text('goal', p?.specDraft.goal ?? '');
    _text('constraints', p?.specDraft.constraints ?? '');
    _text('decisions', p?.specDraft.decisions ?? '');
    _text('outOfScope', p?.specDraft.outOfScope ?? '');
    _text('contextFiles', p?.specDraft.contextFiles.join('\n') ?? '');
    _text('lanes', '${_settings.maxLanes}');
    _text('daily', _plain(_settings.budget.daily));
    _text('total', _plain(_settings.budget.total));
    _text('tokens', _settings.budget.taskTokens?.toString() ?? '');
    _text('rounds', '${_settings.maxFixRounds}');
    _draftTarget = 'team-editor.${widget.kind.name}.${widget.projectId}';
    unawaited(_restore());
  }

  /// A new project starts from the team's own defaults. Where those never
  /// chose a mode or a budget, a simple task still just starts: one lane and
  /// a modest limit the person can read and change.
  static TeamProjectSettings _creationDefaults(TeamProjectSettings defaults) {
    final budget = defaults.budget.chosen
        ? defaults.budget
        : const TeamBudget(chosen: true, daily: 5, total: 20);
    return defaults.copyWith(
      mode: defaults.mode.isEmpty ? 'single' : defaults.mode,
      budget: budget,
    );
  }

  static String _plain(double? v) => v == null
      ? ''
      : v == v.roundToDouble()
      ? v.toInt().toString()
      : v.toString();

  TextEditingController _text(String key, [String initial = '']) =>
      _fields.putIfAbsent(key, () => TextEditingController(text: initial));
  String _value(String key) => _text(key).text.trim();
  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _change(VoidCallback action) {
    setState(action);
    if (!_restoring && !_complete) _persist();
  }

  /// The sheet is long and its button is pinned at the bottom, so what the
  /// last tap produced (the progress line, a problem and its way forward)
  /// sits above the fold. Bring it into view as soon as it appears.
  void _revealNotices() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _noticeKey.currentContext;
      if (!mounted || target == null) return;
      unawaited(
        Scrollable.ensureVisible(
          target,
          duration: KitMotion.reduced(target)
              ? Duration.zero
              : KitMotion.standard,
          curve: KitMotion.emphasized,
        ),
      );
    });
  }

  void _persist() {
    final payload = jsonEncode({
      'fields': {for (final e in _fields.entries) e.key: e.value.text},
      'settings': _settings.toJson(),
      'repos': _repos.map((r) => r.toJson()).toList(),
      'milestones': _milestones.map((m) => m.toJson()).toList(),
      'tasks': _tasks.map((t) => t.toJson()).toList(),
      'phases': _phases.map((p) => p.toJson()).toList(),
      'server': _serverId,
      'roleId': _roleId,
      'budget': _budgetChoice,
      'planFirst': _planFirst,
      'chargingTouched': _chargingTouched,
      'role': _role?.toJson(),
      'reviewedRevision': _reviewedRevision,
    });
    // The controller serializes these writes, redacts content, and closes
    // the writer before deleting a profile. No UI write can recreate it.
    unawaited(
      _controller.saveEditorDraft(_draftTarget, payload).catchError((Object _) {
        if (mounted && !_complete) {
          setState(() => _error = _l.teamProjectEditorDraftFailed);
        }
      }),
    );
  }

  Future<void> _restore() async {
    try {
      final saved = await _controller.readEditorDraft(_draftTarget);
      if (!mounted) return;
      if (saved != null && saved.isNotEmpty) {
        final data = jsonDecode(saved) as Map<String, dynamic>;
        setState(() {
          _draftRestored = _creating;
          _starterSeeded = false;
          for (final e in (data['fields'] as Map<String, dynamic>).entries) {
            _text(e.key).text = e.value as String;
          }
          _settings = TeamProjectSettings.fromJson(
            Map<String, dynamic>.from(data['settings'] as Map),
          );
          _repos = [
            for (final r in data['repos'] as List)
              TeamRepo.fromJson(Map<String, dynamic>.from(r as Map)),
          ];
          _milestones = [
            for (final m in data['milestones'] as List)
              TeamMilestone.fromJson(Map<String, dynamic>.from(m as Map)),
          ];
          _tasks = [
            for (final t in data['tasks'] as List)
              TeamTask.fromJson(Map<String, dynamic>.from(t as Map)),
          ];
          _phases = [
            for (final p in data['phases'] as List)
              TeamPhase.fromJson(Map<String, dynamic>.from(p as Map)),
          ];
          _serverId = data['server'] as String?;
          _roleId = data['roleId'] as String?;
          _budgetChoice = data['budget'] as String?;
          _planFirst = data['planFirst'] as bool? ?? true;
          _chargingTouched = data['chargingTouched'] as bool? ?? false;
          if (data['role'] != null) {
            _role = TeamProjectRole.fromJson(
              Map<String, dynamic>.from(data['role'] as Map),
            );
          }
          _reviewedRevision =
              data['reviewedRevision'] as int? ?? _reviewedRevision;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = _l.teamProjectEditorDraftFailed);
    }
    if (mounted) setState(() => _restoring = false);
    if (mounted &&
        widget.kind == _Kind.defaults &&
        widget.focusPlannerModel &&
        widget.modelPicker != null) {
      unawaited(_pickRoleModel('planner'));
    }
  }

  Widget _field(
    String key,
    String label, {
    String initial = '',
    bool multiline = false,
    bool number = false,
    bool decimal = false,
  }) => KitField(
    key: ValueKey(key),
    label: label,
    controller: _text(key, initial),
    draft: _fieldDrafts.putIfAbsent(
      key,
      () => _ControllerDraft(
        target: '$_draftTarget.$key',
        owner: _controller,
        controller: _text(key, initial),
        isAlive: () => mounted && !_complete,
        onFailure: () {
          if (mounted && !_complete) {
            setState(() => _error = _l.teamProjectEditorDraftFailed);
          }
        },
      ),
    ),
    kind: multiline
        ? KitFieldKind.multiline
        : number
        ? KitFieldKind.number
        : KitFieldKind.text,
    decimal: decimal,
    onChanged: (_) => _change(() {}),
  );
  Widget _choice(
    String label,
    Map<String, String> options,
    String? selected,
    ValueChanged<String> onChanged,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      KitSectionLabel.inline(label),
      if (options.isEmpty)
        KitNotice(message: _l.teamProjectEditorNoOptions)
      else
        KitChoiceList<String>.single(
          semanticsLabel: label,
          choices: [
            for (final e in options.entries)
              KitChoice(value: e.key, title: e.value),
          ],
          selected: selected,
          onSelected: onChanged,
        ),
    ],
  );
  Widget _button(
    String label,
    VoidCallback action, {
    bool destructive = false,
  }) => KitButton.tertiary(
    label: label,
    onPressed: _working ? null : action,
    destructive: destructive,
  );

  TeamProjectSettings _editedSettings() => _settings.copyWith(
    maxLanes: _settings.mode == 'single'
        ? 1
        : int.tryParse(_value('lanes')) ?? 0,
    maxFixRounds: int.tryParse(_value('rounds')) ?? 0,
    budget: TeamBudget(
      chosen: _budgetChoice != null,
      unlimited: _budgetChoice == 'unlimited',
      daily: _budgetChoice == 'unlimited'
          ? null
          : double.tryParse(_value('daily')),
      total: _budgetChoice == 'unlimited'
          ? null
          : double.tryParse(_value('total')),
      taskTokens: int.tryParse(_value('tokens')),
    ),
  );
  String? _settingsError() {
    final s = _editedSettings();
    if (s.mode.isEmpty && !s.budget.chosen) {
      return _l.teamProjectEditorChooseModeBudget;
    }
    if (s.mode.isEmpty) return _l.teamProjectEditorChooseMode;
    if (s.maxLanes < 1 || s.maxLanes > 32) {
      return _l.teamProjectEditorPositiveLanes;
    }
    if (!s.budget.chosen) return _l.teamProjectEditorChooseBudget;
    if (!s.budget.unlimited &&
        ((s.budget.daily ?? 0) <= 0 || (s.budget.total ?? 0) <= 0)) {
      return _l.teamProjectEditorPositiveBudget;
    }
    if (s.maxFixRounds < 0 || s.maxFixRounds > 3) {
      return _l.teamProjectEditorFixRoundsRange;
    }
    if (_value('tokens').isNotEmpty && (s.budget.taskTokens ?? 0) <= 0) {
      return _l.teamProjectEditorPositiveTokens;
    }
    return null;
  }

  String? _creationError() {
    final settingsError = _settingsError();
    if (settingsError != null) return settingsError;
    final noGoal = _value('goal').isEmpty;
    if (noGoal || _allRepos().isEmpty) {
      if (noGoal && _allRepos().isEmpty && !_repoTyped) {
        return _l.teamProjectEditorRequired;
      }
      if (noGoal) return _l.teamProjectEditorGoalRequired;
      return _repoTyped
          ? _l.teamProjectEditorRepoIncomplete
          : _l.teamProjectEditorRepoMissing;
    }
    if (widget.kind == _Kind.quick && (_roleId == null || _serverId == null)) {
      return _l.teamProjectEditorChooseRoleServer;
    }
    return null;
  }

  /// A repo the person typed but has not added yet. It counts once it has a
  /// name, a folder and a place to run, so "Add repo" is optional for the
  /// first one.
  bool get _repoTyped =>
      _value('repoName').isNotEmpty || _value('repoPath').isNotEmpty;
  TeamRepo? _pendingRepo() {
    if (_serverId == null ||
        _value('repoName').isEmpty ||
        _value('repoPath').isEmpty) {
      return null;
    }
    return TeamRepo(
      id: _pendingRepoId ??= _newId(),
      name: _value('repoName'),
      path: _value('repoPath'),
      serverId: _serverId!,
    );
  }

  String? _pendingRepoId;
  List<TeamRepo> _allRepos() => [..._repos, ?_pendingRepo()];

  void _updateCharging() {
    if (_chargingTouched) return;
    final phone =
        _controller.snapshot?.servers.any(
          (s) =>
              s.phone &&
              (_serverId == s.id || _allRepos().any((r) => r.serverId == s.id)),
        ) ??
        false;
    _settings = _settings.copyWith(
      chargingOnly:
          phone && _settings.mode == 'parallel' && DateTime.now().hour >= 23,
    );
  }

  Future<bool> _send(
    TeamProjectAction action, {
    TeamSpec? spec,
    List<TeamTask>? tasks,
    List<TeamPhase>? phases,
    TeamProjectRole? role,
    String? text,
    String? projectId,
    int? expectedRevision,
    bool close = true,
  }) async {
    if (_working || _complete) return false;
    _change(() {
      _working = true;
      _error = null;
      _refusal = null;
    });
    _revealNotices();
    final result = await _controller.execute(
      TeamProjectCommand(
        requestId: _controller.newRequestId(),
        action: action,
        projectId: projectId ?? widget.projectId,
        expectedRevision: expectedRevision ?? _reviewedRevision,
        name: _creating ? _projectName() : _value('name'),
        text: text ?? _value('goal'),
        settings: _editedSettings(),
        spec: spec,
        tasks: tasks,
        phases: phases,
        repos: _allRepos(),
        roleId: _roleId ?? '',
        serverId: _serverId ?? '',
        role: role,
        confirmed: !_planFirst,
      ),
    );
    if (result.accepted) _reviewedRevision = result.revision;
    // A completed command consumes its draft even if the person dismissed
    // the sheet while the write was in flight.
    if (result.accepted && close) {
      _complete = true;
      try {
        await _controller.clearEditorDraft(_draftTarget);
        for (final draft in _fieldDrafts.values) {
          await draft.clear();
        }
      } catch (_) {
        if (mounted) {
          setState(() {
            _working = false;
            _error = _l.teamProjectEditorDraftClearFailed;
          });
        }
        return true;
      }
    }
    if (!mounted) return result.accepted;
    _change(() {
      _working = false;
      _refusal = result.accepted || result.code == 'staleRevision'
          ? null
          : teamRefusalFor(
              _l,
              action,
              result.code.isEmpty ? 'saveFailed' : result.code,
            );
      _error = result.accepted
          ? null
          : result.code == 'staleRevision'
          ? _l.teamProjectEditorChangedElsewhere
          : _refusal!.message;
    });
    if (!result.accepted) _revealNotices();
    if (result.accepted && close) Navigator.of(context).pop();
    return result.accepted;
  }

  /// The plain sentence, a way forward, and the code under Details.
  List<Widget> _refusalNotice(TeamRefusal refusal) {
    final empty = refusal.code == 'repository_empty';
    final canCommit = empty && _canFirstCommit;
    return [
      KitNotice(
        key: const ValueKey('team-refusal'),
        message: refusal.message,
        notes: [
          refusal.next,
          // Where this app cannot make the commit, say exactly what to do.
          if (empty && !canCommit) _l.teamProjectEditorFirstCommitManual,
          ?_commitFailure,
        ],
        actions: [
          if (canCommit)
            KitAction(
              key: const ValueKey('team-first-commit'),
              label: _l.teamProjectEditorFirstCommit,
              onPressed: _makingCommit ? null : _makeFirstCommit,
            ),
          KitAction(label: _l.teamProjectRetry, onPressed: _save),
        ],
      ),
      KitDetailsFold(
        values: [KitTechnicalValue(_l.teamRefusalCode, refusal.code)],
      ),
    ];
  }

  /// The first commit can be made here for a folder on this phone.
  bool get _canFirstCommit {
    final repo = _allRepos().firstOrNull;
    if (repo == null) return false;
    final onPhone =
        _controller.snapshot?.servers.any(
          (s) => s.id == repo.serverId && s.phone,
        ) ??
        false;
    return onPhone &&
        (teamFirstCommitOverride != null ||
            TeamExecutionGate.of(_controller) != null);
  }

  /// An empty commit in the chosen folder (no file touched), then the same
  /// "Start planning" again.
  Future<void> _makeFirstCommit({bool thenStart = true}) async {
    final repo = _allRepos().firstOrNull;
    if (repo == null || _makingCommit) return;
    _change(() {
      _makingCommit = true;
      _commitFailure = null;
    });
    try {
      final commit = teamFirstCommitOverride;
      if (commit != null) {
        await commit(repo.path);
      } else {
        await BuiltinProjectFolders(BuiltinLinux()).makeFirstCommit(repo.path);
      }
    } catch (_) {
      if (mounted) {
        _change(() {
          _makingCommit = false;
          _commitFailure = _l.teamProjectEditorFirstCommitFailed;
        });
      }
      return;
    }
    if (!mounted) return;
    _change(() {
      _makingCommit = false;
      _repoEmpty = false;
      _error = null;
      _refusal = null;
    });
    if (thenStart) await _save();
  }

  TeamFolderPicker? get _folderPicker {
    final override = teamFolderPickerOverride;
    if (override != null) return override;
    final gate = TeamExecutionGate.of(_controller);
    if (gate == null) return null;
    return (context) =>
        ProjectFolderActions.pickFolder(context, gate.connection);
  }

  /// The folder browser the New chat flow uses. A folder from this phone
  /// also settles where the work runs.
  Future<void> _pickFolder() async {
    final pick = _folderPicker;
    if (pick == null || _working) return;
    final path = await pick(context);
    if (path == null || !mounted) return;
    final servers = _controller.snapshot?.servers ?? const <TeamServer>[];
    final phone = servers.where((s) => s.phone).firstOrNull;
    _change(() {
      _text('repoPath').text = path;
      if (_value('repoName').isEmpty) {
        _text('repoName').text =
            path.split('/').where((part) => part.isNotEmpty).lastOrNull ?? path;
      }
      if (_serverId == null && phone != null) _serverId = phone.id;
      _pendingRepoId = null;
      _commitFailure = null;
      _error = null;
      _repoEmpty = false;
      _updateCharging();
    });
    unawaited(_probeRepo(path));
  }

  /// Looks at the chosen folder before anyone taps Start planning: a repo
  /// with no commit is said at the folder, with the fix beside it.
  Future<void> _probeRepo(String path) async {
    if (!_canFirstCommit) return;
    try {
      final probe = teamRepoEmptyOverride;
      final empty = probe != null
          ? await probe(path)
          : await BuiltinProjectFolders(BuiltinLinux()).isEmptyRepo(path);
      if (mounted && empty && _value('repoPath') == path) {
        _change(() => _repoEmpty = true);
      }
    } catch (_) {
      // Unknown is fine: Start planning still explains an empty repo.
    }
  }

  Future<void> _reload() async {
    final approved = await showKitConfirm(
      context,
      title: _l.teamProjectEditorReloadConfirmTitle,
      body: _l.teamProjectEditorDiscardDraft,
      confirmLabel: _l.teamProjectEditorReload,
    );
    if (!approved || !mounted) return;
    await _discardAndReopen();
  }

  /// Drops every saved draft of this form and opens it again, empty.
  Future<void> _discardAndReopen() async {
    _complete = true;
    try {
      await _controller.clearEditorDraft(_draftTarget);
      for (final draft in _fieldDrafts.values) {
        await draft.clear();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _complete = false;
          _error = _l.teamProjectEditorDraftFailed;
        });
      }
      return;
    }
    if (!mounted) return;
    final navigator = Navigator.of(context);
    final controller = _controller;
    final kind = widget.kind;
    final id = widget.projectId;
    navigator.pop();
    unawaited(_open(navigator.context, controller, kind, id));
  }

  Future<void> _save() async {
    if (_complete) return;
    if (_creating ||
        widget.kind == _Kind.settings ||
        widget.kind == _Kind.defaults) {
      final error = _settingsError();
      if (error != null) {
        _change(() => _error = error);
        _revealNotices();
        return;
      }
    }
    if (_creating) {
      final error = _creationError();
      if (error != null) {
        _change(() => _error = error);
        _revealNotices();
        return;
      }
      await _send(
        widget.kind == _Kind.quick
            ? TeamProjectAction.createQuickTask
            : TeamProjectAction.createProject,
        spec: TeamSpec(
          goal: _value('goal'),
          contextFiles: _lines(_value('contextFiles')),
        ),
      );
    } else if (widget.kind == _Kind.spec) {
      await _saveSpec(approve: true);
    } else if (widget.kind == _Kind.plan) {
      final edited = [
        for (final t in _tasks)
          t.copyWith(
            title: _value('task-${t.id}'),
            criteria: _lines(_value('criteria-${t.id}')),
          ),
      ];
      await _send(
        _project?.status == 'plan'
            ? TeamProjectAction.approvePlan
            : TeamProjectAction.replan,
        tasks: edited,
        phases: _phases,
      );
    } else if (widget.kind == _Kind.settings || widget.kind == _Kind.defaults) {
      await _send(
        widget.kind == _Kind.defaults
            ? TeamProjectAction.updateDefaults
            : TeamProjectAction.updateSettings,
      );
    } else if (_role != null) {
      if (_value('roleName').isEmpty) {
        _change(() => _error = _l.teamProjectEditorRoleRequired);
        return;
      }
      final saved = await _send(
        TeamProjectAction.saveRole,
        role: _role!.copyWith(
          name: _value('roleName'),
          instructions: _value('roleInstructions'),
          model: _value('roleModel'),
          fallbackModel: _value('roleFallback'),
        ),
        close: false,
      );
      if (saved && mounted) _change(() => _role = null);
    }
  }

  String _projectName() {
    final name = _value('name');
    if (name.isNotEmpty) return name;
    final goal = _value('goal').split('\n').first.trim();
    return goal.length > 40 ? '${goal.substring(0, 40).trim()}…' : goal;
  }

  List<String> _lines(String value) => value
      .split('\n')
      .map((v) => v.trim())
      .where((v) => v.isNotEmpty)
      .toList();
  TeamSpec _currentSpec() => TeamSpec(
    version: (_project?.specVersions.lastOrNull?.version ?? 0) + 1,
    goal: _value('goal'),
    constraints: _value('constraints'),
    decisions: _value('decisions'),
    outOfScope: _value('outOfScope'),
    contextFiles: _lines(_value('contextFiles')),
    milestones: [
      for (final m in _milestones)
        m.copyWith(
          title: _value('milestone-${m.id}'),
          criteria: _lines(_value('milestoneCriteria-${m.id}')),
        ),
    ],
  );
  Future<void> _saveSpec({required bool approve}) async {
    final spec = _currentSpec();
    if (spec.goal.isEmpty ||
        (approve &&
            (spec.milestones.isEmpty ||
                spec.milestones.any(
                  (m) => m.title.isEmpty || m.criteria.isEmpty,
                )))) {
      _change(() => _error = _l.teamProjectEditorSpecRequired);
      return;
    }
    if (await _send(
          TeamProjectAction.saveSpecDraft,
          spec: spec,
          close: !approve,
        ) &&
        approve &&
        mounted) {
      await _send(TeamProjectAction.approveSpec, spec: spec);
    }
  }

  Future<void> _requestChange() async {
    final text = _value('changeRequest');
    if (text.isEmpty || _value('goal').isEmpty) {
      _change(() => _error = _l.teamProjectEditorChangeRequired);
      return;
    }
    if (!await _send(
          TeamProjectAction.saveSpecDraft,
          spec: _currentSpec(),
          close: false,
        ) ||
        !mounted) {
      return;
    }
    if (!await _send(
          TeamProjectAction.requestSpecChange,
          text: text,
          close: false,
        ) ||
        !mounted) {
      return;
    }
    final spec = _project!.specDraft;
    _change(() {
      _text('goal').text = spec.goal;
      _text('constraints').text = spec.constraints;
      _text('decisions').text = spec.decisions;
      _text('outOfScope').text = spec.outOfScope;
      _text('contextFiles').text = spec.contextFiles.join('\n');
      _milestones = [...spec.milestones];
      for (final m in _milestones) {
        _text('milestone-${m.id}').text = m.title;
        _text('milestoneCriteria-${m.id}').text = m.criteria.join('\n');
      }
      _text('changeRequest').clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (widget.kind) {
      _Kind.create => _l.teamProjectEditorNewProject,
      _Kind.quick => _l.teamProjectEditorQuickTask,
      _Kind.spec => _l.teamProjectEditorSpec,
      _Kind.plan => _l.teamProjectEditorPlan,
      _Kind.settings => _l.teamProjectEditorSettings,
      _Kind.roles => _l.teamProjectEditorRoles,
      _Kind.defaults => _l.teamProjectEditorDefaults,
    };
    final creationError = _creating ? _creationError() : null;
    // At large text the hint under the pinned button would eat the form, so
    // it moves to the end of the scrolling form instead (still shown once).
    final large = MediaQuery.textScalerOf(context).scale(1) >= 1.5;
    final inlineReason = large && creationError != null;
    return KitSheet(
      title: title,
      handle: false,
      fill: true,
      loading: _working || _restoring,
      onClose: () => Navigator.of(context).pop(),
      primary:
          (widget.kind == _Kind.roles && _role == null) ||
              (widget.kind == _Kind.plan && _project?.status == 'planFailed')
          ? null
          : KitAction(
              label: switch (widget.kind) {
                _Kind.create => _l.teamProjectEditorStartPlanning,
                _Kind.quick =>
                  _planFirst
                      ? _l.teamProjectEditorStartPlanning
                      : _l.teamProjectEditorStartTask,
                _Kind.spec => _l.teamProjectEditorApproveSpec,
                _Kind.plan =>
                  _project?.status == 'plan'
                      ? _l.teamProjectEditorApprovePlan
                      : _l.teamProjectEditorApplyPlan,
                _ => _l.teamProjectEditorSave,
              },
              onPressed:
                  _working || _restoring || _complete || creationError != null
                  ? null
                  : _save,
              disabledReason: inlineReason ? null : creationError,
              working: _working,
            ),
      secondary: widget.kind == _Kind.spec
          ? KitAction(
              label: _l.teamProjectEditorSaveDraft,
              onPressed: _working || _restoring
                  ? null
                  : () => _saveSpec(approve: false),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            key: _noticeKey,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null && _refusal?.message == _error)
                ..._refusalNotice(_refusal!)
              else if (_error != null)
                KitNotice(message: _error!),
              // Right after "Start planning" the sheet says what is
              // happening, so the seconds the engine takes are never silent.
              KitReveal(
                child: _working && _creating
                    ? KitNotice(
                        key: const ValueKey('team-starting'),
                        message: _l.teamProjectEditorStarting,
                        tone: AppStatusTone.progress,
                      )
                    : null,
              ),
            ],
          ),
          KitReveal(
            child: _draftRestored && !_working
                ? KitNotice(
                    key: const ValueKey('team-draft-restored'),
                    message: _l.teamProjectEditorDraftRestored,
                    actions: [
                      KitAction(
                        key: const ValueKey('team-draft-start-fresh'),
                        label: _l.teamProjectEditorStartFresh,
                        onPressed: _discardAndReopen,
                      ),
                    ],
                  )
                : null,
          ),
          if (_project != null && _project!.revision != _reviewedRevision)
            _button(_l.teamProjectEditorReload, _reload),
          if (_restoring)
            const KitSkeletonRows()
          else ...[
            if (_creating) ..._creation(),
            if (widget.kind == _Kind.defaults && widget.focusPlannerModel)
              ..._modelFields(),
            if (_creating ||
                widget.kind == _Kind.settings ||
                widget.kind == _Kind.defaults)
              ..._settingsFields(),
            if (widget.kind == _Kind.defaults && !widget.focusPlannerModel)
              ..._modelFields(),
            if (widget.kind == _Kind.spec) ..._specFields(),
            if (widget.kind == _Kind.plan) ..._planFields(),
            if (widget.kind == _Kind.roles) ..._roleFields(),
            if (inlineReason) KitNotice(message: creationError),
          ],
        ],
      ),
    );
  }

  List<Widget> _creation() => [
    _field('goal', _l.teamProjectEditorGoalLabel, multiline: true),
    KitSectionLabel.inline(_l.teamProjectEditorRepos),
    for (final r in _repos)
      KitRow(
        title: r.name,
        supporting: TextSpan(
          text: _controller.snapshot?.servers
              .where((s) => s.id == r.serverId)
              .firstOrNull
              ?.name,
        ),
        action: KitAction(
          label: _l.teamProjectEditorRemove,
          onPressed: () => _change(() => _repos.remove(r)),
        ),
      ),
    _field('repoName', _l.teamProjectEditorRepoName),
    ..._folderFields(),
    _choice(
      _l.teamProjectEditorWhereRuns,
      {
        for (final s in _controller.snapshot?.servers ?? <TeamServer>[])
          s.id: s.name,
      },
      _serverId,
      (v) => _change(() {
        _serverId = v;
        _updateCharging();
      }),
    ),
    _button(_l.teamProjectEditorAddRepo, () {
      if (_serverId == null ||
          _value('repoPath').isEmpty ||
          _value('repoName').isEmpty) {
        _change(() => _error = _l.teamProjectEditorRepoRequired);
        return;
      }
      _change(() {
        _repos.add(
          TeamRepo(
            id: _newId(),
            name: _value('repoName'),
            path: _value('repoPath'),
            serverId: _serverId!,
          ),
        );
        _text('repoName').clear();
        _text('repoPath').clear();
        _pendingRepoId = null;
        _error = null;
        _updateCharging();
      });
    }),
    if (widget.kind == _Kind.quick) ...[
      _choice(
        _l.teamProjectEditorRole,
        {
          for (final r in _controller.snapshot?.roles ?? <TeamProjectRole>[])
            r.id: r.name,
        },
        _roleId,
        (v) => _change(() => _roleId = v),
      ),
      KitSwitchRow(
        title: _l.teamProjectEditorPlanFirst,
        value: _planFirst,
        onChanged: (v) => _change(() => _planFirst = v),
      ),
    ],
  ];

  /// The repo folder: chosen in the phone's folder browser, with typing a path
  /// as the quiet second way (and the only one where there is no browser).
  List<Widget> _folderFields() {
    final servers = _controller.snapshot?.servers ?? const <TeamServer>[];
    final chosen = servers.where((s) => s.id == _serverId).firstOrNull;
    final browse = _folderPicker != null && (chosen == null || chosen.phone);
    final path = _value('repoPath');
    return [
      if (browse) ...[
        KitRow(
          key: const ValueKey('team-repo-folder'),
          title: _l.teamProjectEditorChooseFolder,
          supporting: TextSpan(
            text: path.isEmpty ? _l.teamProjectEditorFolderNone : path,
          ),
          onTap: _working ? null : _pickFolder,
        ),
        KitReveal(
          child: _repoEmpty && _canFirstCommit
              ? KitNotice(
                  key: const ValueKey('team-repo-empty'),
                  message: _l.teamProjectEditorFolderEmpty,
                  notes: [?_commitFailure],
                  actions: [
                    KitAction(
                      key: const ValueKey('team-first-commit-inline'),
                      label: _l.teamProjectEditorFirstCommit,
                      onPressed: _makingCommit
                          ? null
                          : () => _makeFirstCommit(thenStart: false),
                    ),
                  ],
                )
              : null,
        ),
        if (!_typePath)
          _button(
            _l.teamProjectEditorTypePath,
            () => _change(() => _typePath = true),
          ),
      ],
      KitReveal(
        child: !browse || _typePath
            ? _field('repoPath', _l.teamProjectEditorRepoPath)
            : null,
      ),
    ];
  }

  /// The host that will run the work: the chosen one, else where the first
  /// repo lives. Only measured numbers are shown; with none, it says so.
  String _costLine() {
    final servers = _controller.snapshot?.servers ?? const <TeamServer>[];
    final id = _serverId ?? _allRepos().firstOrNull?.serverId;
    final host = servers.where((s) => s.id == id).firstOrNull;
    if (host == null) return _l.teamProjectEditorCostNoHost;
    final name = host.phone ? _l.teamProjectEditorThisPhone : host.name;
    final memory = host.memoryMb;
    if (memory == null || memory <= 0) {
      return _l.teamProjectEditorCostNotMeasured(name);
    }
    return _l.teamProjectEditorCostMeasured(name, memory.round().toString());
  }

  List<Widget> _modeFields() => [
    _choice(
      _l.teamProjectEditorMode,
      {
        'single': _l.teamProjectEditorSingle,
        'parallel': _l.teamProjectEditorParallel,
      },
      _settings.mode.isEmpty ? null : _settings.mode,
      (v) => _change(() {
        _settings = _settings.copyWith(mode: v);
        _updateCharging();
      }),
    ),
    if (_settings.mode == 'parallel')
      _field('lanes', _l.teamProjectEditorMaxLanes, number: true),
    KitNotice(message: _costLine()),
    KitSwitchRow(
      title: _l.teamProjectEditorCharging,
      value: _settings.chargingOnly,
      onChanged: (v) => _change(() {
        _chargingTouched = true;
        _settings = _settings.copyWith(chargingOnly: v);
      }),
    ),
  ];
  List<Widget> _screenFields() => [
    KitSwitchRow(
      title: _l.teamProjectEditorScreenOff,
      value: _settings.keepWorkingScreenOff,
      onChanged: (v) => _change(
        () => _settings = _settings.copyWith(keepWorkingScreenOff: v),
      ),
    ),
    KitNotice(message: _l.teamProjectEditorScreenOffHelp),
  ];
  List<Widget> _reviewFields() => [
    _choice(
      _l.teamProjectEditorReview,
      {
        'milestones': _l.teamProjectEditorMilestonesRisk,
        'every_step': _l.teamProjectEditorEveryStep,
      },
      _settings.reviewLevel,
      (v) => _change(() => _settings = _settings.copyWith(reviewLevel: v)),
    ),
  ];
  List<Widget> _budgetFields() => [
    _choice(
      _l.teamProjectEditorBudget,
      {
        'limited': _l.teamProjectEditorSetLimits,
        'unlimited': _l.teamProjectEditorNoLimit,
      },
      _budgetChoice,
      (v) => _change(() => _budgetChoice = v),
    ),
    if (_budgetChoice == 'limited') ...[
      _field(
        'daily',
        _l.teamProjectEditorDailyBudget,
        number: true,
        decimal: true,
      ),
      _field(
        'total',
        _l.teamProjectEditorTotalBudget,
        number: true,
        decimal: true,
      ),
      KitNotice(message: _l.teamProjectEditorBudgetHelp),
    ],
  ];
  List<Widget> _limitFields() => [
    _field('tokens', _l.teamProjectEditorTaskTokens, number: true),
    KitSwitchRow(
      title: _l.teamProjectEditorAutoFix,
      value: _settings.autoFix,
      onChanged: (v) =>
          _change(() => _settings = _settings.copyWith(autoFix: v)),
    ),
    if (_settings.autoFix)
      _field('rounds', _l.teamProjectEditorMaxRounds, number: true),
  ];

  /// Settings and defaults keep one flat order. A new project shows what it
  /// must decide first (mode, review, budget) and folds the rest below.
  List<Widget> _settingsFields() => _creating
      ? [
          ..._modeFields(),
          ..._reviewFields(),
          ..._budgetFields(),
          KitSectionLabel.inline(_l.teamProjectEditorMoreOptions),
          _field('name', _l.teamProjectEditorName),
          KitNotice(message: _l.teamProjectEditorNameHelp),
          _field(
            'contextFiles',
            _l.teamProjectEditorContextFiles,
            multiline: true,
          ),
          KitNotice(message: _contextFilesHelp),
          ..._screenFields(),
          ..._limitFields(),
        ]
      : [
          ..._modeFields(),
          ..._screenFields(),
          ..._reviewFields(),
          ..._budgetFields(),
          ..._limitFields(),
        ];
  List<Widget> _specFields() => [
    KitNotice(message: _l.teamProjectEditorDraftApproval),
    if (_starterSeeded)
      KitNotice(
        key: const ValueKey('team-starter-milestone'),
        message: _l.teamProjectEditorStarterNote,
      ),
    _field('changeRequest', _l.teamProjectEditorChangeRequest, multiline: true),
    _button(_l.teamProjectEditorAskChange, _requestChange),
    _field('goal', _l.teamProjectEditorGoal, multiline: true),
    _field('contextFiles', _l.teamProjectEditorContextFiles, multiline: true),
    KitNotice(message: _contextFilesHelp),
    _field('constraints', _l.teamProjectEditorConstraints, multiline: true),
    _field('decisions', _l.teamProjectEditorDecisions, multiline: true),
    _field('outOfScope', _l.teamProjectEditorOutOfScope, multiline: true),
    KitSectionLabel.inline(_l.teamProjectEditorMilestones),
    for (final m in _milestones) ...[
      _field(
        'milestone-${m.id}',
        _l.teamProjectEditorMilestoneTitle,
        initial: m.title,
      ),
      _field(
        'milestoneCriteria-${m.id}',
        _l.teamProjectEditorCriteria,
        initial: m.criteria.join('\n'),
        multiline: true,
      ),
      Wrap(
        children: [
          if (_milestones.indexOf(m) > 0)
            _button(
              _l.teamProjectEditorMoveUp,
              () => _change(() {
                final i = _milestones.indexOf(m);
                _milestones.removeAt(i);
                _milestones.insert(i - 1, m);
              }),
            ),
          if (_milestones.indexOf(m) < _milestones.length - 1)
            _button(
              _l.teamProjectEditorMoveDown,
              () => _change(() {
                final i = _milestones.indexOf(m);
                _milestones.removeAt(i);
                _milestones.insert(i + 1, m);
              }),
            ),
          _button(
            _l.teamProjectEditorRemove,
            () => _change(() => _milestones.remove(m)),
          ),
        ],
      ),
    ],
    _button(
      _l.teamProjectEditorAddMilestone,
      () => _change(() => _milestones.add(TeamMilestone(id: _newId()))),
    ),
    _button(
      _l.teamProjectEditorHistory,
      () => _change(() => _history = !_history),
    ),
    if (_history)
      for (final spec in _project?.specVersions.reversed ?? <TeamSpec>[])
        _historyVersion(spec),
  ];
  String _specText(TeamSpec spec) => [
    _l.teamProjectEditorGoal,
    spec.goal,
    _l.teamProjectEditorConstraints,
    spec.constraints,
    _l.teamProjectEditorDecisions,
    spec.decisions,
    _l.teamProjectEditorOutOfScope,
    spec.outOfScope,
    _l.teamProjectEditorContextFiles,
    ...spec.contextFiles,
    _l.teamProjectEditorMilestones,
    for (final m in spec.milestones) ...[m.title, ...m.criteria],
  ].join('\n');
  Widget _historyVersion(TeamSpec spec) {
    final previous = _project?.specVersions
        .where((s) => s.version < spec.version)
        .lastOrNull;
    final at = DateTime.tryParse(spec.approvedAt);
    final age = at == null
        ? _l.teamProjectEditorUnknownDate
        : relativeAgeLabel(DateTime.now().difference(at), at: at, l10n: _l);
    final actor = spec.approvedBy == 'person'
        ? _l.teamProjectEditorYou
        : KitRedact.text(spec.approvedBy);
    final title = '${_l.teamProjectEditorVersion} ${spec.version}';
    final diff = previous == null
        ? <KitDiffFile>[]
        : [
            KitDiffFile.fromTexts(
              '${_l.teamProjectEditorVersion} ${previous.version} → $title',
              before: _specText(previous),
              after: _specText(spec),
            ),
          ];
    return KitExpandRow(
      title: title,
      supporting: TextSpan(
        text: '${_l.teamProjectEditorApprovedBy} $actor · $age',
      ),
      children: [
        KitText(_specText(spec)),
        if (diff.isNotEmpty)
          KitDiffView(
            files: diff,
            maxLines: 12,
            onOpenAll: () => showKitDiff(context, title: title, files: diff),
          ),
      ],
    );
  }
}
