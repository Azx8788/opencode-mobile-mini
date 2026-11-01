import 'package:flutter/foundation.dart';

/// The steps of the in-app team coming up, in order. Each one ends on a
/// signal the app can see, never on a timer:
///
/// * [service]: the native service started and its process is alive
///   (`BuiltinLinux.status`).
/// * [answering]: the supervisor answers `GET /health` with status ok.
/// * [store]: the team is registered and `GET /v0/city/phone/health` says ok
///   (the city, with its task store, is loaded).
/// * [agents]: `GET /v0/city/phone/status` lists the team's agents.
enum BuiltinTeamStartStep { service, answering, store, agents }

/// One coming-up of the in-app team, seen from outside: which step it is
/// at, when each began and how long it took. Written by [BuiltinTeam] both
/// for the explicit start and for the automatic one after an app restart, and
/// read by the AI Team page. Lives outside any screen, so leaving the page
/// does not lose it.
class BuiltinTeamStartProgress extends ChangeNotifier {
  BuiltinTeamStartProgress({DateTime Function()? now})
    : _now = now ?? DateTime.now;

  static BuiltinTeamStartProgress get shared =>
      debugShared ?? (_shared ??= BuiltinTeamStartProgress());
  static BuiltinTeamStartProgress? _shared;

  @visibleForTesting
  static BuiltinTeamStartProgress? debugShared;

  /// How long each step may take before the page says the phone is busy.
  /// The step keeps going; this only changes the words.
  static const slowAfter = <BuiltinTeamStartStep, Duration>{
    BuiltinTeamStartStep.service: Duration(seconds: 15),
    BuiltinTeamStartStep.answering: Duration(seconds: 45),
    BuiltinTeamStartStep.store: Duration(seconds: 60),
    BuiltinTeamStartStep.agents: Duration(seconds: 30),
  };

  final DateTime Function() _now;

  int _generation = 0;
  bool _running = false;
  BuiltinTeamStartStep? _step;
  BuiltinTeamStartStep? _failedStep;
  Object? _error;
  final Map<BuiltinTeamStartStep, DateTime> _began = {};
  final Map<BuiltinTeamStartStep, Duration> _took = {};

  bool get running => _running;

  /// The step under way; the one that failed after a failure.
  BuiltinTeamStartStep? get step => _step;
  BuiltinTeamStartStep? get failedStep => _failedStep;

  /// What stopped the last coming-up; null while one runs or after one that
  /// finished.
  Object? get error => _error;

  Duration? took(BuiltinTeamStartStep step) => _took[step];

  bool isDone(BuiltinTeamStartStep step) => _took.containsKey(step);

  /// How long [step] has been going, while it is the current one.
  Duration? elapsed(BuiltinTeamStartStep step) {
    if (!_running || step != _step) return null;
    final began = _began[step];
    return began == null ? null : _now().difference(began);
  }

  /// Whether [step] has been going longer than [slowAfter] says is usual.
  bool isSlow(BuiltinTeamStartStep step) {
    final elapsed = this.elapsed(step);
    return elapsed != null && elapsed >= slowAfter[step]!;
  }

  /// Steps done over all steps: a real count, moved only by [enter].
  double get fraction => _took.length / BuiltinTeamStartStep.values.length;

  /// Starts a new coming-up and returns its token; a writer holding an older
  /// token is ignored from then on.
  int begin() {
    _generation++;
    _running = true;
    _step = null;
    _failedStep = null;
    _error = null;
    _began.clear();
    _took.clear();
    notifyListeners();
    return _generation;
  }

  /// Supersedes pending observers without completing any unfinished step.
  void cancel() {
    _generation++;
    _running = false;
    _step = null;
    _failedStep = null;
    _error = null;
    notifyListeners();
  }

  bool isCurrent(int generation) => generation == _generation;

  /// [step] begins; the one before it is done.
  void enter(int generation, BuiltinTeamStartStep step) {
    if (!isCurrent(generation) || step == _step) return;
    _finishStep();
    _step = step;
    _began[step] = _now();
    notifyListeners();
  }

  /// One poll went by: the elapsed seconds move.
  void tick(int generation) {
    if (isCurrent(generation) && _running) notifyListeners();
  }

  void finish(int generation) {
    if (!isCurrent(generation)) return;
    _finishStep();
    _step = null;
    _running = false;
    notifyListeners();
  }

  void fail(int generation, Object error) {
    if (!isCurrent(generation)) return;
    _failedStep = _step;
    _error = error;
    _running = false;
    notifyListeners();
  }

  void _finishStep() {
    final current = _step;
    final began = current == null ? null : _began[current];
    if (current != null && began != null) {
      _took[current] = _now().difference(began);
    }
  }
}
