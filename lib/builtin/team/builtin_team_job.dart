import 'package:flutter/foundation.dart';

import 'builtin_team.dart';

/// One turn-on or start of the in-app team, kept outside the Plugins
/// section so it goes on when the person leaves the screen and shows where
/// it is when they come back (the section is rebuilt; this is not).
///
/// It records when each stage began, so the section can list the stages
/// with the current one marked and how long each took, and so a slow phone
/// shows where its minutes go.
class BuiltinTeamJob extends ChangeNotifier {
  BuiltinTeamJob({DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// The one job of the app; tests replace it.
  static BuiltinTeamJob get shared =>
      debugShared ?? (_shared ??= BuiltinTeamJob());
  static BuiltinTeamJob? _shared;

  @visibleForTesting
  static BuiltinTeamJob? debugShared;

  final DateTime Function() _now;

  bool _running = false;
  List<BuiltinTeamStage> _stages = const [];
  final Map<BuiltinTeamStage, DateTime> _began = {};
  final Map<BuiltinTeamStage, Duration> _took = {};
  BuiltinTeamStage? _stage;
  String? _project;
  Object? _error;

  bool get running => _running;

  /// The stages this job passes, in order (all four for a turn-on; starting
  /// and waiting for a start).
  List<BuiltinTeamStage> get stages => _stages;

  /// The stage under way, or the one that failed.
  BuiltinTeamStage? get stage => _stage;

  /// The project a turn-on is for.
  String? get project => _project;

  /// What stopped the last job ([BuiltinTeamException] or anything else);
  /// null after a job that finished.
  Object? get error => _error;

  DateTime get now => _now();

  /// How long [stage] took, once it is over.
  Duration? took(BuiltinTeamStage stage) => _took[stage];

  /// How long [stage] has been going, while it is the current one.
  Duration? elapsed(BuiltinTeamStage stage) {
    if (!_running || stage != _stage) return null;
    final began = _began[stage];
    return began == null ? null : _now().difference(began);
  }

  /// Runs [work], which reports each stage it enters. Does nothing while a
  /// job runs. Never throws: the error is kept in [error].
  Future<void> run({
    required List<BuiltinTeamStage> stages,
    String? project,
    required Future<void> Function(void Function(BuiltinTeamStage) onStage)
    work,
  }) async {
    if (_running) return;
    _running = true;
    _stages = List.unmodifiable(stages);
    _project = project;
    _began.clear();
    _took.clear();
    _stage = null;
    _error = null;
    notifyListeners();
    try {
      await work(_enter);
      _finishStage();
    } catch (error) {
      _error = error;
      _finishStage(keepStage: true);
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  /// Forgets a finished job's error (the section shows it once).
  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  void _enter(BuiltinTeamStage stage) {
    if (stage == _stage) return;
    _finishStage();
    _stage = stage;
    _began[stage] = _now();
    notifyListeners();
  }

  void _finishStage({bool keepStage = false}) {
    final current = _stage;
    if (current == null) return;
    final began = _began[current];
    if (began != null && !keepStage) {
      _took[current] = _now().difference(began);
    }
    if (!keepStage) _stage = null;
  }
}
