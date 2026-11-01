import 'dart:async';

import '../platform/thermal.dart';
import 'app_diagnostics.dart';
import 'perf_trace.dart';
import 'report_problem.dart';

/// Connects existing process diagnostics and optional thermal events to a
/// durable [ReportProblem]. Create one after opening the report at startup,
/// retain it for the app lifetime, and [close] before disposing its sources.
///
/// Existing buffered errors and finished timings are captured once. Calling
/// [AppDiagnosticsController.clear] also clears restored persistent evidence,
/// including when the process-local error buffer is empty. Timing snapshots
/// are imported only at attachment; clearing never replays old timings.
/// Android exit errors already collected by AppExitBridge enter through the
/// diagnostics controller; callers needing typed exits may instead call
/// [ReportProblem.recordAndroidExit] explicitly and pass [typedAndroidExits]
/// so the same exit is not also kept as an error event.
///
/// Capture never throws storage errors into the application being diagnosed;
/// callers observe [ReportProblem.storageFailed] on the report instead.
class ReportProblemCapture {
  ReportProblemCapture({
    required ReportProblem report,
    required AppDiagnosticsController diagnostics,
    Stream<ThermalReading>? thermalReadings,
    this.typedAndroidExits = false,
  }) : _report = report,
       _diagnostics = diagnostics {
    final timings = PerfTrace.spans;
    final first = timings.length > report.maxEntries
        ? timings.length - report.maxEntries
        : 0;
    diagnostics.addListener(_onDiagnostics);
    _timings = PerfTrace.recorded.listen(_onTiming);
    _captureErrors();
    _safely(() => _report.recordTimings(timings.skip(first)));
    _thermal = thermalReadings?.listen(
      (reading) => _safely(() => _report.recordThermal(reading)),
      onError: (Object error, StackTrace stack) => _safely(
        () => _report.recordError(error, stack, source: 'thermal.stream'),
      ),
    );
  }

  /// The error source `AppExitRecovery` uses for Android's exit record.
  static const androidExitSource = 'android.exit';

  /// True when the caller feeds exits through
  /// [ReportProblem.recordAndroidExit]; diagnostics errors from
  /// [androidExitSource] are then skipped instead of stored twice.
  final bool typedAndroidExits;

  final ReportProblem _report;
  final AppDiagnosticsController _diagnostics;
  final Map<int, (DateTime, int)> _seenErrors = {};
  late final StreamSubscription<PerfSpan> _timings;
  StreamSubscription<ThermalReading>? _thermal;
  bool _closed = false;

  void _onDiagnostics() {
    if (_closed) return;
    if (_diagnostics.isEmpty) {
      _seenErrors.clear();
      _safely(_report.clear);
      return;
    }
    _captureErrors();
  }

  void _captureErrors() {
    final entries = _diagnostics.entries;
    final currentIds = entries.map((entry) => entry.id).toSet();
    _seenErrors.removeWhere((id, _) => !currentIds.contains(id));
    for (final entry in entries) {
      final revision = (entry.timestamp, entry.occurrences);
      if (_seenErrors[entry.id] == revision) continue;
      _seenErrors[entry.id] = revision;
      if (typedAndroidExits && entry.source == androidExitSource) continue;
      _safely(
        () => _report.recordError(
          entry.message,
          entry.stack.isEmpty ? null : StackTrace.fromString(entry.stack),
          source: entry.source,
          at: entry.timestamp,
        ),
      );
    }
  }

  // The synchronous completion stream reaches durable storage in the same
  // turn as a finished span. Each event is new regardless of ID order; a
  // long-running span may finish after one with a newer ID.
  void _onTiming(PerfSpan span) => _safely(() => _report.recordTiming(span));

  void _safely(void Function() action) {
    if (_closed) return;
    try {
      action();
    } catch (_) {
      // ReportProblem exposes storageFailed. Do not recursively diagnose a
      // failing diagnostics store or print the original filesystem exception.
    }
  }

  /// Detaches diagnostics and cancels the timing and thermal subscriptions.
  /// Does not clear evidence or dispose either caller-owned controller.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _diagnostics.removeListener(_onDiagnostics);
    await _timings.cancel();
    await _thermal?.cancel();
    _thermal = null;
  }
}
