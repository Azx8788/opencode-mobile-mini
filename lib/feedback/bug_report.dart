import 'dart:async';

import 'package:flutter/widgets.dart';

import '../diagnostics/failed_job_report.dart';
import '../l10n/app_localizations.dart';
import '../ui/kit/kit_buttons.dart' show KitAction;
import '../ui/kit/kit_notice.dart' show KitReport;
import '../ui/screens/app_diagnostics_screen.dart' show openReportProblem;

export 'problem_report.dart' show bugReportPlatformLabel, bugReportRepoUrl;

/// "Report a problem" from anywhere: opens the one Report a problem page
/// (P8.2), which previews exactly what is sent and then opens the prefilled
/// GitHub form through `openExternalLink`, or copies or shares the report.
/// [error] attaches the failure that brought the person there.
///
/// Kept under this name for the failure states that already call it.
Future<void> openBugReport(BuildContext context, {KitReport? error}) =>
    openReportProblem(context, error: error);

/// Opens Report a problem with a failed job attached (P8.4): its redacted
/// log excerpt shows in the page's KitLogPanel and goes in the report, or
/// the page says none was kept. [title] is the failure as the surface
/// words it. Nothing is sent from here.
Future<void> openFailedJobReport(
  BuildContext context,
  FailedJobReport report, {
  String? title,
}) => openReportProblem(context, error: report.toKitReport(title: title));

/// The "Report this failure" action for a failed job's surface (a v2 setup
/// row, a KitLogPanel header, a failure notice), or null when [capture]
/// finds nothing reportable now, so no dead button shows (STATE-13).
///
/// [capture] runs again at the tap, before any retry or clear can drop the
/// state, and the page opens with that snapshot (nothing opens when it is
/// gone by then). [before] runs just before the page opens, to close a
/// sheet the action sits in; [context] must outlive that sheet.
///
/// A setup v2 failed row, for example:
///
/// ```dart
/// failedJobReportAction(
///   context,
///   capture: () => FailedJobReport.setup(
///     engine.progress.value,
///     componentId: row.id,
///   ),
/// )
/// ```
KitAction? failedJobReportAction(
  BuildContext context, {
  required FailedJobReport? Function() capture,
  String? title,
  VoidCallback? before,
  Key? key,
}) {
  if (capture() == null) return null;
  return KitAction(
    key: key ?? const ValueKey('failed-job-report'),
    label: lookupAppLocalizations(
      Localizations.localeOf(context),
    ).failedJobReport,
    onPressed: () {
      final report = capture();
      if (report == null) return;
      before?.call();
      unawaited(openFailedJobReport(context, report, title: title));
    },
  );
}
