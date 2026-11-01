import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../../domain/factsbook/factsbook_types.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/factsbook/factsbook_store.dart' show FactsBookLink;
import '../../app_iconography.dart';
import '../../kit/kit.dart';

/// The app's words for FactsBook values. Plain words only: no code, no
/// exception text (owner rule); technical detail goes under Details.

KitProvenance kitProvenanceOf(FactProvenance provenance) =>
    switch (provenance) {
      FactProvenance.told => KitProvenance.told,
      FactProvenance.seen => KitProvenance.seen,
      FactProvenance.calculated => KitProvenance.calculated,
      // An unverified hand edit reads like a guess, never as told.
      FactProvenance.guessed ||
      FactProvenance.external => KitProvenance.guessed,
    };

final _idShape = RegExp(r'^(?:[a-z]{1,3}_[0-9A-Z]{26}|[0-9a-f]{64})$');

/// "a shared message": the node's words as they are, or, when the source is
/// an id (an inbox item the node holds), the app's words for it. Null when
/// there is no source to name (what the person told directly).
String? sourceWords(AppLocalizations l10n, String? source) {
  if (source == null || source.trim().isEmpty) return null;
  if (_idShape.hasMatch(source)) return l10n.fbSourceSaved;
  return switch (source) {
    'chat' || 'chat_selection' => l10n.fbSourceChat,
    'share' => l10n.fbSourceShare,
    'note' => l10n.fbSourceNote,
    'import' => l10n.fbSourceImport,
    'statement' => l10n.fbSourceStatement,
    _ => source,
  };
}

String kindWords(AppLocalizations l10n, ThingKind kind) => switch (kind) {
  ThingKind.person => l10n.fbKindPerson,
  ThingKind.document => l10n.fbKindDocument,
  ThingKind.subscription => l10n.fbKindSubscription,
  ThingKind.warranty => l10n.fbKindWarranty,
  ThingKind.bill => l10n.fbKindBill,
  ThingKind.invoice => l10n.fbKindInvoice,
  ThingKind.card => l10n.fbKindCard,
  ThingKind.account => l10n.fbKindAccount,
  ThingKind.organisation => l10n.fbKindOrganization,
  ThingKind.place => l10n.fbKindPlace,
  ThingKind.project => l10n.fbKindProject,
  ThingKind.topic => l10n.fbKindTopic,
  ThingKind.event => l10n.fbKindEvent,
  ThingKind.health => l10n.fbKindHealth,
  ThingKind.other => l10n.fbKindOther,
};

String areaWords(AppLocalizations l10n, String area) => switch (area) {
  'money' => l10n.fbAreaMoney,
  'health' => l10n.fbAreaHealth,
  'family' => l10n.fbAreaFamily,
  'work' => l10n.fbAreaWork,
  _ => l10n.fbAreaOther(area),
};

/// An area's own name, for its row.
String areaName(AppLocalizations l10n, String area) => switch (area) {
  'money' => l10n.fbAreaNameMoney,
  'health' => l10n.fbAreaNameHealth,
  'family' => l10n.fbAreaNameFamily,
  'work' => l10n.fbAreaNameWork,
  'general' => l10n.fbAreaNameGeneral,
  'home' => l10n.fbAreaNameHome,
  'travel' => l10n.fbAreaNameTravel,
  'unsorted' => l10n.fbAreaNameUnsorted,
  'id' => l10n.fbAreaNameId,
  _ => area,
};

/// Why a capture is kept, in plain words. [canUnlock] is false while the
/// node cannot open the locked folder yet: then "unlock it" is no way out.
String reasonWords(
  AppLocalizations l10n,
  CouldNotSaveEntry entry, {
  bool canUnlock = true,
}) => switch (entry.reason) {
  CouldNotSaveReason.nodeUnreachable => l10n.fbReasonUnreachable,
  CouldNotSaveReason.storageFull => l10n.fbReasonStorageFull,
  CouldNotSaveReason.cloudQuota => l10n.fbReasonCloudQuota,
  CouldNotSaveReason.keyLocked =>
    canUnlock ? l10n.fbReasonKeyLocked : l10n.fbReasonKeyLockedNotYet,
  CouldNotSaveReason.validationRejected => l10n.fbReasonRejected,
  CouldNotSaveReason.classificationFailed => l10n.fbReasonClassification,
  CouldNotSaveReason.parserError => l10n.fbReasonParserError,
  CouldNotSaveReason.outboxFull => l10n.fbReasonOutboxFull,
};

String classWords(AppLocalizations l10n, ReviewClass value) => switch (value) {
  ReviewClass.factAdd => l10n.fbCareClassFactAdd,
  ReviewClass.factUpdate => l10n.fbCareClassFactUpdate,
  ReviewClass.factSupersede => l10n.fbCareClassFactSupersede,
  ReviewClass.merge => l10n.fbCareClassMerge,
  ReviewClass.link => l10n.fbCareClassLink,
  ReviewClass.archive => l10n.fbCareClassArchive,
  ReviewClass.forget => l10n.fbCareClassForget,
  ReviewClass.watch => l10n.fbCareClassWatch,
  ReviewClass.reminder => l10n.fbCareClassReminder,
  ReviewClass.importCandidate => l10n.fbCareClassImport,
  ReviewClass.promotion => l10n.fbCareClassPromotion,
};

String riskWords(AppLocalizations l10n, String risk) => switch (risk) {
  'money' => l10n.fbCareRiskMoney,
  'health' => l10n.fbCareRiskHealth,
  'id' => l10n.fbCareRiskId,
  'contradiction' => l10n.fbCareRiskContradiction,
  'low_confidence' => l10n.fbCareRiskLowConfidence,
  _ => risk,
};

/// What went wrong, as a sentence with a way forward. Never the node's own
/// text and never an exception.
String failureWords(AppLocalizations l10n, Object? failure) {
  if (failure is FactsBookException) {
    switch (failure.code) {
      case 'locked_no_key' || 'sensitive_locked':
        return l10n.fbErrorLocked;
      case 'not_found':
        return l10n.fbErrorNotFound;
      case 'node_unreachable' || 'not_working_device':
        return l10n.fbErrorUnreachable;
      case 'starting':
        return l10n.fbErrorStarting;
      case 'busy':
        return l10n.fbErrorBusy;
      case 'unauthorized':
        return l10n.fbErrorUnauthorized;
      case 'not_enabled' || 'not_qualified':
        return l10n.fbErrorNotEnabled;
      case 'stale_approval' || 'precondition_failed' || 'conflict':
        return l10n.fbErrorStale;
      case 'owner_required':
        return l10n.fbErrorOwner;
      case 'forbidden_scope' || 'not_approved':
        return l10n.fbErrorForbidden;
      case 'slow_down':
        final wait = failure.retryAfterSeconds;
        return wait == null ? l10n.fbErrorSlow : l10n.fbErrorSlowAfter(wait);
      case 'address_not_allowed':
        return l10n.fbErrorAddress;
      case 'bad_response':
        return l10n.fbErrorBadResponse;
      case 'bad_request':
        return l10n.fbErrorBadRequest;
      case 'outbox_full':
        return l10n.fbErrorNodeFull;
      case 'index_rebuilding':
        return l10n.fbErrorIndexRebuilding;
      case 'device_auth_unavailable':
        return l10n.fbErrorAuthUnavailable;
      case 'device_auth_cancelled':
        return l10n.fbErrorAuthCancelled;
      case 'device_auth_locked':
        return l10n.fbErrorAuthLocked;
      case 'device_auth_failed':
        return l10n.fbErrorAuthFailed;
    }
  }
  return l10n.fbErrorGeneric;
}

/// The technical line for Details: the node's request id and code.
String? failureDetails(AppLocalizations l10n, Object? failure) {
  if (failure is! FactsBookException) return null;
  final id = failure.requestId;
  return id == null
      ? l10n.fbErrorCode(failure.code)
      : '${l10n.fbErrorCode(failure.code)}\n${l10n.fbErrorRequest(id)}';
}

/// A name or title from the data, isolated for mixed text only where the
/// layout runs right to left (so tests and left-to-right text read as
/// written, and Arabic text keeps a Latin name in one piece).
String bidiName(BuildContext context, String value) =>
    Directionality.of(context) == TextDirection.rtl
    ? KitBidi.auto(value)
    : value;

/// The mark at the start of a thing's row.
IconData kindIcon(ThingKind kind) => switch (kind) {
  ThingKind.person => AppIconography.person,
  ThingKind.document => AppIconography.fileText,
  ThingKind.subscription => AppIconography.sync,
  ThingKind.warranty => AppIconography.shield,
  ThingKind.bill || ThingKind.invoice => AppIconography.article,
  ThingKind.card => AppIconography.category,
  ThingKind.account => AppIconography.account,
  ThingKind.organisation => AppIconography.folders,
  ThingKind.place => AppIconography.globe,
  ThingKind.project => AppIconography.projects,
  ThingKind.topic => AppIconography.note,
  ThingKind.event => AppIconography.calendar,
  ThingKind.health => AppIconography.shieldFilled,
  ThingKind.other => AppIconography.idea,
};

/// The word for a module's canonical state (G34).
String moduleStateWords(AppLocalizations l10n, ModuleState state) =>
    switch (state) {
      ModuleState.ok => l10n.fbStateReady,
      ModuleState.waiting => l10n.fbStateWaiting,
      ModuleState.stale => l10n.fbStateStale,
      ModuleState.failed => l10n.fbStateFailed,
      ModuleState.disabled => l10n.fbStateOff,
      ModuleState.absent => l10n.fbStateNotSetUp,
    };

/// Why a module is in its state, from the node's reason code, in the app's
/// words; an unknown code is not shown.
String? moduleReasonWords(AppLocalizations l10n, String? code) =>
    switch (code) {
      'not_configured' => l10n.fbReasonModuleNotConfigured,
      'not_enabled' => l10n.fbReasonModuleNotEnabled,
      _ => null,
    };

/// A reminder's timing in words: "Oct 21, 10:00 AM", "Every day at 08:00",
/// "Every week on Mon, Wed at 08:00" ...
String timingWords(
  BuildContext context,
  AppLocalizations l10n,
  ReminderTiming timing,
) {
  final locale = Localizations.localeOf(context).toString();
  final time = KitBidi.ltr(
    '${timing.at.hour.toString().padLeft(2, '0')}:'
    '${timing.at.minute.toString().padLeft(2, '0')}',
  );
  switch (timing.repeat) {
    case ReminderRepeat.never:
      return '${KitFactRow.dateOf(context, timing.at)}, '
          '${KitTime.clock(context, timing.at)}';
    case ReminderRepeat.daily:
      return l10n.fbWhenDaily(time);
    case ReminderRepeat.weekly:
      final days = [
        for (final d in (timing.weekdays.toList()..sort()))
          // 2024-01-01 was a Monday.
          DateFormat.E(locale).format(DateTime(2024, 1, d)),
      ].join(', ');
      return l10n.fbWhenWeeklyOn(days, time);
    case ReminderRepeat.monthly:
      return timing.lastDay
          ? l10n.fbWhenMonthLast(time)
          : l10n.fbWhenMonthlyOn(timing.dayOfMonth, time);
    case ReminderRepeat.yearly:
      return l10n.fbWhenYearlyOn(
        DateFormat.MMMd(locale).format(timing.at),
        time,
      );
  }
}

String repeatWords(AppLocalizations l10n, ReminderRepeat repeat) =>
    switch (repeat) {
      ReminderRepeat.never => l10n.fbRepeatNever,
      ReminderRepeat.daily => l10n.fbRepeatDaily,
      ReminderRepeat.weekly => l10n.fbRepeatWeekly,
      ReminderRepeat.monthly => l10n.fbRepeatMonthly,
      ReminderRepeat.yearly => l10n.fbRepeatYearly,
    };

/// What an action calls the memory it acts on: "this phone's memory" for the
/// one running here, the address for any other.
String nodeName(AppLocalizations l10n, FactsBookLink? link) {
  final url = link?.baseUrl;
  if (url == null || url.host.isEmpty) return l10n.fbNodeNameDefault;
  final here = url.host == '127.0.0.1' || url.host == 'localhost';
  return here ? l10n.fbNodeNameThisPhone : url.authority;
}
