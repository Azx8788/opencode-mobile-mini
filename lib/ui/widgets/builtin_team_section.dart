/// AI Team for the OpenCode inside this app (no Termux): the one place the
/// in-app server's team is added, turned on for a project, started and
/// stopped. Shown in Settings › Plugins for the in-app profile, where the
/// Termux "On this phone" section appears for the Termux server.
///
/// - Not installed: "Run an AI team on this phone" with Add, which opens
///   Add tools with AI Team switched on (the reusable setup engine installs
///   it, with its own progress screen).
/// - Installed, not on for the open project: "Turn on AI Team for
///   {project}", which runs [BuiltinTeam.turnOn] as the app's one
///   [BuiltinTeamJob] (it goes on when the person leaves the screen), shown
///   here as its stages with the current one marked and how long each took,
///   then gives the profile the team's plugin config, so the Team card and
///   the rest of the AI Team screens light up. While it runs no action is
///   offered: the stages say what is happening.
/// - On: running or stopped, with Start / Stop, and the plain explanation
///   of Android's limit on an app's child processes.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../builtin/builtin_linux.dart' show BuiltinLinuxException;
import '../../builtin/builtin_server.dart' show looksLikeInAppServer;
import '../../builtin/setup/aiteam_scripts.dart';
import '../../builtin/setup/setup_contract.dart' show setupToolsChanged;
import '../../builtin/team/builtin_team.dart';
import '../../builtin/team/builtin_team_job.dart';
import '../../diagnostics/failed_job_report.dart';
import '../../feedback/bug_report.dart' show failedJobReportAction;
import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import '../../state/profiles.dart';
import '../app_theme.dart';
import '../kit/kit_buttons.dart';
import '../kit/kit_details_fold.dart';
import '../kit/kit_illustration.dart';
import '../kit/kit_notice.dart';
import '../kit/kit_progress.dart';
import '../kit/kit_redact.dart';
import '../kit/kit_row.dart';
import '../kit/kit_sheet.dart';
import '../kit/kit_status_mark.dart';
import '../kit/kit_surface.dart';
import '../kit/kit_text.dart';
import '../kit/kit_tokens.dart';
import '../kit/scenes/team_scenes.dart';
import '../screens/phone_setup/phone_setup_selection.dart' show setupSizeText;
import 'product_states.dart' show productErrorDetails, productErrorText;
import 'team_phone_onboarding.dart'
    show TeamPhoneReadyScreen, openTeamOnThisPhone;

AppLocalizations _copy(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

/// The in-app team runtime the section uses; tests replace it.
BuiltinTeam? debugBuiltinTeam;

BuiltinTeam get _sharedTeam => debugBuiltinTeam ?? (_team ??= BuiltinTeam());
BuiltinTeam? _team;

/// The in-app team the phone's screens share (this section and the team's
/// ready page, [TeamPhoneReadyScreen]), so one turn-on runs at a time.
BuiltinTeam get sharedBuiltinTeam => _sharedTeam;

/// After the in-app team was turned off or removed (P1.4): every saved
/// profile whose AI Team config points at the in-app team loses it, with
/// the plugin's cached state, so no screen keeps reading a team that is
/// gone. A remote or Termux team is left as it is.
Future<void> forgetBuiltinTeam(ConnectionController connection) async {
  for (final profile in [...connection.store.profiles]) {
    if (!BuiltinTeam.isBuiltinConfig(profile.orchestration)) continue;
    final current = connection.orchestration;
    if (current != null && current.profileId == profile.id) {
      await current.remove();
    } else {
      await connection.orchestrationStore.sweep(profile.id);
    }
    profile.orchestration = null;
    await connection.store.upsert(profile);
  }
  connection.syncOrchestration();
}

/// Opens Add tools with AI Team switched on and, when the person goes
/// ahead, installs it and turns it on for the project: the one "Set up AI
/// Team on this phone" ([openTeamOnThisPhone]). Tests replace it.
@visibleForTesting
Future<void> Function(BuildContext context)? debugAddAiTeam;

Future<void> _addAiTeam(
  BuildContext context,
  ConnectionController connection,
) async {
  final override = debugAddAiTeam;
  if (override != null) return override(context);
  await openTeamOnThisPhone(context, connection);
}

/// The words for a failed turn-on or start.
String builtinTeamFailureText(
  AppLocalizations l10n,
  BuiltinTeamException error,
) {
  if (error.exited) {
    return l10n.aiteamComponentFailed(l10n.aiteamComponentFailedExited);
  }
  if (error.timedOut) {
    return l10n.aiteamComponentFailed(l10n.aiteamComponentFailedTimeout);
  }
  // The script's last line when it is a sentence for people; its output
  // otherwise is said in words (the output itself is under Details).
  final lines = error.detail.trim().split('\n');
  final last = lines.isEmpty ? '' : lines.last.trim();
  return l10n.aiteamComponentFailed(
    productErrorText(BuiltinLinuxException(last), l10n: l10n),
  );
}

String builtinTeamStageText(
  AppLocalizations l10n,
  BuiltinTeamStage stage,
  String project,
) => switch (stage) {
  BuiltinTeamStage.preparing => l10n.aiteamComponentStageTeam,
  BuiltinTeamStage.addingProject => l10n.aiteamComponentStageProject(project),
  BuiltinTeamStage.starting => l10n.aiteamComponentStageStarting,
  BuiltinTeamStage.waiting => l10n.aiteamComponentStageWaiting,
};

/// What happened to the team's latest merge in [project]'s folder
/// ([BuiltinTeam.originHook]).
String builtinTeamBringInText(
  AppLocalizations l10n,
  BuiltinTeamBringIn bringIn,
  String project,
) {
  final commit = bringIn.commit ?? '';
  return switch (bringIn.outcome) {
    BuiltinTeamBringInOutcome.broughtIn ||
    BuiltinTeamBringInOutcome.upToDate => l10n.aiteamBringInDone(
      project,
      [commit, bringIn.detail].where((part) => part.isNotEmpty).join(' '),
    ),
    BuiltinTeamBringInOutcome.dirty => l10n.aiteamBringInDirty(
      commit,
      project,
      bringIn.detail,
    ),
    BuiltinTeamBringInOutcome.diverged => l10n.aiteamBringInDiverged(
      commit,
      project,
    ),
    BuiltinTeamBringInOutcome.skipped || BuiltinTeamBringInOutcome.failed =>
      l10n.aiteamBringInFailed(project, bringIn.detail),
  };
}

/// A stage's time as minutes and seconds ("2:05").
String builtinTeamElapsedText(Duration elapsed) {
  final seconds = elapsed.inSeconds < 0 ? 0 : elapsed.inSeconds;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// The project's folder name, as the person named it.
String builtinTeamProjectName(String path) {
  final trimmed = path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;
  return trimmed.substring(trimmed.lastIndexOf('/') + 1);
}

/// A team job's stages, each with its mark: done with how long it took,
/// the current one with its time so far (or failed), the rest waiting.
/// [project] is the project's name, for "Adding {project}".
List<Widget> builtinTeamStageRows(
  AppLocalizations l10n,
  BuiltinTeamJob job, {
  required bool failed,
  required String project,
}) {
  final current = job.stage;
  final rows = <Widget>[];
  var reached = false;
  for (final stage in job.stages) {
    final took = job.took(stage);
    final isCurrent = stage == current;
    final KitMarkState mark;
    String? supporting;
    if (isCurrent) {
      reached = true;
      final elapsed = job.elapsed(stage);
      mark = failed ? KitMarkState.failed : KitMarkState.working;
      if (!failed && elapsed != null) {
        supporting = l10n.aiteamComponentStageSoFar(
          builtinTeamElapsedText(elapsed),
        );
      }
    } else if (took != null) {
      mark = KitMarkState.done;
      supporting = l10n.aiteamComponentStageTook(builtinTeamElapsedText(took));
    } else {
      // A stage the job skipped (a store made during setup) reads as done
      // once a later one began.
      mark = reached || current == null
          ? KitMarkState.waiting
          : KitMarkState.done;
    }
    rows.add(
      KitRow(
        key: ValueKey('builtin-team-stage-${stage.name}'),
        padding: EdgeInsets.zero,
        leading: KitStatusMark(state: mark),
        title: builtinTeamStageText(l10n, stage, project),
        supporting: supporting == null ? null : TextSpan(text: supporting),
        titleKey: isCurrent ? const ValueKey('builtin-team-stage') : null,
      ),
    );
  }
  return rows;
}

class BuiltinTeamSection extends StatefulWidget {
  const BuiltinTeamSection({
    super.key,
    required this.connection,
    required this.profile,
  });

  final ConnectionController connection;

  /// The in-app server's profile.
  final ServerProfile profile;

  /// Whether [profile] gets this section: the in-app server on Android.
  static bool appliesTo(ServerProfile? profile) =>
      looksLikeInAppServer(profile);

  @override
  State<BuiltinTeamSection> createState() => _BuiltinTeamSectionState();
}

class _BuiltinTeamSectionState extends State<BuiltinTeamSection> {
  BuiltinTeam get _team => _sharedTeam;
  BuiltinTeamJob get _job => BuiltinTeamJob.shared;

  BuiltinTeamState? _state;
  bool _loading = true;

  /// A quick action of this section (stop, bring in) runs.
  bool _busy = false;
  String? _error;
  String? _detail;
  bool _jobWasRunning = false;

  /// Moves the stage times on while the job runs.
  Timer? _ticker;

  bool get _working => _busy || _job.running;

  String? get _project {
    final directory = widget.connection.directory;
    if (directory == null || directory.trim().isEmpty) return null;
    return directory;
  }

  bool get _configured =>
      BuiltinTeam.isBuiltinConfig(widget.profile.orchestration);

  @override
  void initState() {
    super.initState();
    _jobWasRunning = _job.running;
    _job.addListener(_onJob);
    // A setup job ending changed the tools on the phone: read them again
    // rather than keep what was read when this page opened.
    setupToolsChanged.addListener(_onSetup);
    _syncTicker();
    unawaited(_load());
  }

  @override
  void dispose() {
    setupToolsChanged.removeListener(_onSetup);
    _job.removeListener(_onJob);
    _ticker?.cancel();
    super.dispose();
  }

  void _syncTicker() {
    if (_job.running) {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  void _onSetup() {
    if (mounted) unawaited(_load());
  }

  void _onJob() {
    if (!mounted) return;
    final finished = _jobWasRunning && !_job.running;
    _jobWasRunning = _job.running;
    _syncTicker();
    setState(() {});
    if (finished) unawaited(_load());
  }

  Future<void> _load() async {
    BuiltinTeamState state;
    try {
      state = await _team.status();
    } catch (_) {
      state = const BuiltinTeamState();
    }
    // Installed without a store yet (just added): make it now, quietly, so
    // Turn on skips its longest first step. Turn on waits for it.
    if (state.installed && !state.hasCity && !_job.running) {
      unawaited(_team.prepare());
    }
    if (!mounted) return;
    setState(() {
      _state = state;
      _loading = false;
    });
  }

  String get _notice => _copy(context).aiteamComponentNotice;

  Future<void> _add() async {
    await _addAiTeam(context, widget.connection);
    if (mounted) await _load();
  }

  /// A quick action; the long ones go through [_job].
  Future<void> _run(Future<void> Function() work) async {
    if (_working) return;
    setState(() {
      _busy = true;
      _error = null;
      _detail = null;
    });
    try {
      await work();
    } on BuiltinTeamException catch (error) {
      if (mounted) {
        setState(() {
          _error = builtinTeamFailureText(_copy(context), error);
          _detail = error.detail;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = _copy(context).aiteamComponentFailed(
            productErrorText(error, l10n: _copy(context)),
          );
          _detail = productErrorDetails(error);
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _load();
      }
    }
  }

  /// Turns the team on for [project] as the app's one job: it goes on, and
  /// gives the profile its config, even when this screen is left.
  Future<void> _turnOn(String project) {
    if (_working) return Future.value();
    final notice = _notice;
    final team = _team;
    final connection = widget.connection;
    final profile = widget.profile;
    setState(() => _error = null);
    return _job.run(
      stages: BuiltinTeamStage.values,
      project: project,
      work: (onStage) async {
        await team.turnOn(project, notice: notice, onStage: onStage);
        await _enable(connection, profile);
      },
    );
  }

  Future<void> _start() {
    if (_working) return Future.value();
    final notice = _notice;
    final team = _team;
    final connection = widget.connection;
    final profile = widget.profile;
    setState(() => _error = null);
    return _job.run(
      stages: const [BuiltinTeamStage.starting, BuiltinTeamStage.waiting],
      work: (onStage) async {
        await team.start(notice: notice, onStage: onStage);
        if (!BuiltinTeam.isBuiltinConfig(profile.orchestration)) {
          await _enable(connection, profile);
        }
      },
    );
  }

  /// Turns the team off for good (P1.4): it stops, and stays off when the
  /// app comes back, until the person turns it on again. Asks first; the
  /// question says what stays. The profile then loses the team's config,
  /// so the Team card and the AI Team screens stop reading a team that is
  /// not running.
  Future<void> _turnOff() async {
    if (_working) return;
    final l10n = _copy(context);
    final confirmed = await showKitConfirm(
      context,
      title: l10n.aiteamComponentTurnOffTitle,
      body: l10n.aiteamComponentTurnOffBody,
      confirmLabel: l10n.aiteamComponentTurnOff,
      kind: KitConfirmKind.stop,
      icon: AppIconography.stop,
      consequenceItems: [
        KitConsequence(
          l10n.aiteamComponentTurnOffKept,
          mark: KitConsequenceMark.kept,
        ),
      ],
      sheetKey: const ValueKey('builtin-team-turn-off-sheet'),
      confirmKey: const ValueKey('builtin-team-turn-off-confirm'),
    );
    if (!confirmed || !mounted) return;
    final connection = widget.connection;
    setState(() {
      _busy = true;
      _error = null;
      _detail = null;
    });
    try {
      await _team.turnOff();
      await forgetBuiltinTeam(connection);
    } catch (error) {
      // Plain words; the bridge's own (redacted) text only under Details.
      if (mounted) {
        setState(() {
          _error = l10n.aiteamComponentTurnOffFailed;
          _detail = error is BuiltinLinuxException
              ? error.message
              : KitRedact.text('$error');
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _load();
      }
    }
  }

  /// Tries again what the origin's hook does after every merge; the section
  /// then shows the new outcome (still left alone when it is not safe).
  Future<void> _bringIn(String project) => _run(() => _team.bringIn(project));

  /// Gives the in-app profile the team's plugin config and lets the
  /// connection build its controller: the Team card, Inbox gates and the
  /// AI Team screens then read this team.
  static Future<void> _enable(
    ConnectionController connection,
    ServerProfile profile,
  ) async {
    profile.orchestration = BuiltinTeam.config();
    await connection.store.upsert(profile);
    connection.syncOrchestration();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _copy(context);
    final tokens = KitTokens.of(context);
    final state = _state;
    final children = <Widget>[];
    if (_loading || state == null) {
      children.add(
        KitLoadingBar(loading: true, label: l10n.aiteamComponentSectionTitle),
      );
    } else if (!state.installed) {
      // The cost is said before the one action that spends it (KIT-37).
      children
        ..add(
          KitText(
            l10n.aiteamComponentOfferBody(
              setupSizeText(l10n, AiTeamPins.deviceDownloadBytes),
            ),
            key: const ValueKey('builtin-team-offer'),
            role: KitTextRole.secondary,
            tone: KitTextTone.secondary,
          ),
        )
        ..add(SizedBox(height: tokens.space3))
        ..add(
          KitActionBlock(
            primary: KitAction(
              key: const ValueKey('builtin-team-add'),
              label: l10n.aiteamComponentAdd,
              icon: AppIconography.add,
              onPressed: _add,
            ),
          ),
        );
    } else {
      children.addAll(_installed(context, l10n, state));
    }
    final job = _job;
    final jobError = job.running ? null : job.error;
    if (job.running) {
      children
        ..add(SizedBox(height: tokens.space3))
        ..add(
          Row(
            children: [
              // The team waking up while it starts on this phone.
              const KitIllustration(
                key: ValueKey('builtin-team-waking'),
                scene: TeamWakingScene(),
                width: KitTokens.illustrationInline,
                ambient: true,
              ),
              SizedBox(width: tokens.space3),
              Expanded(
                child: KitText(
                  job.stages.contains(BuiltinTeamStage.preparing)
                      ? l10n.aiteamComponentTurnOnExpectation
                      : l10n.aiteamComponentStartExpectation,
                  key: const ValueKey('builtin-team-expectation'),
                  role: KitTextRole.secondary,
                  tone: KitTextTone.secondary,
                ),
              ),
            ],
          ),
        )
        ..add(SizedBox(height: tokens.space2))
        ..add(
          KitLoadingBar(
            loading: true,
            label: job.stages.contains(BuiltinTeamStage.preparing)
                ? l10n.aiteamComponentTurnOnExpectation
                : l10n.aiteamComponentStartExpectation,
          ),
        );
    }
    if (job.stages.isNotEmpty && (job.running || jobError != null)) {
      children
        ..add(SizedBox(height: tokens.space1))
        ..addAll(
          builtinTeamStageRows(
            l10n,
            job,
            failed: jobError != null,
            project: builtinTeamProjectName(job.project ?? _project ?? ''),
          ),
        );
    }
    final error =
        _error ??
        switch (jobError) {
          null => null,
          final BuiltinTeamException e => builtinTeamFailureText(l10n, e),
          final other => l10n.aiteamComponentFailed('$other'),
        };
    final detail = _error != null
        ? _detail
        : jobError is BuiltinTeamException
        ? jobError.detail
        : null;
    if (error != null) {
      children
        ..add(SizedBox(height: tokens.space3))
        ..add(
          KitNotice(
            key: const ValueKey('builtin-team-error-notice'),
            tone: AppStatusTone.failure,
            message: error,
            messageKey: const ValueKey('builtin-team-error'),
            // A failed turn-on or start is a job: Report carries its log
            // (P8.4), captured at the tap before Retry can clear it.
            actions: [
              if (_error == null)
                ?failedJobReportAction(
                  context,
                  key: const ValueKey('builtin-team-report'),
                  title: error,
                  capture: () => FailedJobReport.teamSetup(_job),
                ),
            ],
          ),
        );
      // The raw output, last and folded (KIT-33).
      if (detail != null && detail.trim().isNotEmpty) {
        children.add(
          KitDetailsFold(
            label: l10n.aiteamComponentShowDetails,
            text: detail,
            foldKey: const ValueKey('builtin-team-details'),
          ),
        );
      }
    }
    return KitSurface.panel(
      key: const ValueKey('builtin-team-section'),
      title: l10n.aiteamComponentSectionTitle,
      icon: AppIconography.phone,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  List<Widget> _installed(
    BuildContext context,
    AppLocalizations l10n,
    BuiltinTeamState state,
  ) {
    final tokens = KitTokens.of(context);
    final project = _project;
    final projectOn = project != null && state.hasProject(project);
    final on = _configured && state.rigs.isNotEmpty;
    final widgets = <Widget>[];
    if (on) {
      widgets
        ..add(
          KitText(
            state.running
                ? l10n.aiteamComponentRunning
                : l10n.aiteamComponentStopped,
            key: const ValueKey('builtin-team-status'),
            role: KitTextRole.rowTitle,
          ),
        )
        ..add(
          KitText(
            l10n.aiteamComponentProjects(state.rigs.join(', ')),
            role: KitTextRole.secondary,
            tone: KitTextTone.secondary,
          ),
        );
    } else {
      widgets.add(
        KitText(
          project == null
              ? l10n.aiteamComponentNoProject
              : l10n.aiteamComponentTurnOnBody,
          key: const ValueKey('builtin-team-turn-on-body'),
          role: KitTextRole.secondary,
          tone: KitTextTone.secondary,
        ),
      );
    }
    final bringIn = on && projectOn ? state.bringInFor(project) : null;
    if (bringIn != null) {
      final name = builtinTeamProjectName(project!);
      widgets
        ..add(SizedBox(height: tokens.space2))
        ..add(
          KitText(
            builtinTeamBringInText(l10n, bringIn, name),
            key: const ValueKey('builtin-team-bring-in'),
            role: KitTextRole.secondary,
            tone: bringIn.leftBehind
                ? KitTextTone.primary
                : KitTextTone.secondary,
          ),
        );
    }
    // While something runs, its stages say what is happening; no action is
    // offered beside them, never a disabled one (design standard §2). Each
    // action names what it acts on: "Stop AI Team", "Turn on AI Team for
    // my-app", "Bring the team's work into my-app".
    KitAction? primary;
    KitAction? secondary;
    final tertiary = <KitAction>[];
    if (!_working) {
      if (project != null && !(on && projectOn)) {
        primary = KitAction(
          key: const ValueKey('builtin-team-turn-on'),
          label: l10n.aiteamComponentTurnOn(builtinTeamProjectName(project)),
          onPressed: () => _turnOn(project),
        );
      }
      if (on && !state.running) {
        final start = KitAction(
          key: const ValueKey('builtin-team-start'),
          label: l10n.aiteamComponentStart,
          icon: AppIconography.play,
          onPressed: _start,
        );
        if (primary == null) {
          primary = start;
        } else {
          secondary = start;
        }
      }
      if (bringIn != null &&
          (bringIn.outcome == BuiltinTeamBringInOutcome.dirty ||
              bringIn.outcome == BuiltinTeamBringInOutcome.failed)) {
        final bring = KitAction(
          key: const ValueKey('builtin-team-bring-in-action'),
          label: l10n.aiteamBringInAction(builtinTeamProjectName(project!)),
          onPressed: () => _bringIn(project),
        );
        if (primary == null) {
          primary = bring;
        } else {
          tertiary.add(bring);
        }
      }
      // Turning off ends the team's work on this phone until it is turned
      // on again: a quiet action, last.
      if (on) {
        tertiary.add(
          KitAction(
            key: const ValueKey('builtin-team-turn-off'),
            label: l10n.aiteamComponentTurnOff,
            icon: AppIconography.stop,
            onPressed: () => unawaited(_turnOff()),
          ),
        );
      }
    }
    final actions = KitActionBlock(
      primary: primary,
      secondary: secondary,
      tertiary: tertiary,
    );
    if (!actions.isEmpty) {
      widgets
        ..add(SizedBox(height: tokens.space3))
        ..add(actions);
    }
    if (on || _configured) {
      widgets
        ..add(SizedBox(height: tokens.space3))
        ..add(
          KitText(
            l10n.aiteamComponentChildProcesses,
            key: const ValueKey('builtin-team-child-processes'),
            role: KitTextRole.secondary,
            tone: KitTextTone.secondary,
          ),
        );
    }
    return widgets;
  }
}
