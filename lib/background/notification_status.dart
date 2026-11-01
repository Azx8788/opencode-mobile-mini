import 'package:flutter/foundation.dart';

import '../l10n/app_localizations.dart';

/// The one ongoing status notification, as a pure function of app state.
///
/// docs/design/notifications-2026-10-14.md owns the situation table; this file
/// is its code. Nothing here touches Android: the controller gathers a
/// [NotificationStatusInput], [buildNotificationStatus] answers with what the
/// notification should say, and Android only draws it.
///
/// Highest wins, in this order: needs you, Android's background limit,
/// reconnecting, chats working, the phone is hot, waiting on a provider,
/// paused while idle, setting up, ready. Every state says one thing, and a
/// request is never repeated here: the status counts it, the alert asks it.

/// Which situation the status shows.
enum NotificationStatusKind {
  needsYou('needs_you'),
  working('working'),
  severalWorking('several_working'),
  waiting('waiting'),
  pausedAndroid('paused_android'),
  pausedHot('paused_hot'),
  pausedIdle('paused_idle'),
  reconnecting('reconnecting'),
  idle('idle'),
  setup('setup');

  const NotificationStatusKind(this.wireValue);

  /// Must match `StatusKind` in StatusNotificationModel.kt.
  final String wireValue;
}

/// A button on the status notification. Android owns the label and the
/// intent; only the wire value travels.
enum NotificationStatusAction {
  open('open'),
  stopReply('stop_reply'),
  start('start'),
  newChat('new_chat'),
  stopServer('stop_server');

  const NotificationStatusAction(this.wireValue);

  /// Must match `StatusAction` in StatusNotificationModel.kt.
  final String wireValue;
}

/// Why background work is paused. [none] means nothing is.
enum NotificationPauseReason {
  none,

  /// Android's six-hour-a-day background limit ended the connection.
  androidLimit,

  /// The heat guard paused the work.
  phoneHot,

  /// The phone server stopped itself because nothing was running.
  idle,
}

/// One chat that is actually working (not waiting on a provider, not waiting
/// on the person).
@immutable
class StatusChat {
  const StatusChat({
    required this.id,
    this.title = '',
    this.project = '',
    this.liveLine,
    this.tasksDone,
    this.tasksTotal,
    this.elapsed,
  });

  final String id;

  /// The chat title the person sees in the app; empty when untitled.
  final String title;
  final String project;

  /// What it is doing now: the task in progress, or a generic tool sentence.
  final String? liveLine;
  final int? tasksDone;
  final int? tasksTotal;
  final Duration? elapsed;

  bool get hasTasks => (tasksTotal ?? 0) > 0 && tasksDone != null;

  @override
  bool operator ==(Object other) =>
      other is StatusChat &&
      other.id == id &&
      other.title == title &&
      other.project == project &&
      other.liveLine == liveLine &&
      other.tasksDone == tasksDone &&
      other.tasksTotal == tasksTotal &&
      other.elapsed == elapsed;

  @override
  int get hashCode =>
      Object.hash(id, title, project, liveLine, tasksDone, tasksTotal, elapsed);
}

/// A chat waiting out a provider limit or retry backoff.
@immutable
class StatusRetry {
  const StatusRetry({
    required this.chatId,
    this.chatTitle = '',
    this.provider,
    this.nextTry,
  });

  final String chatId;
  final String chatTitle;

  /// The provider's display name, when known.
  final String? provider;

  /// When the next attempt runs, when the server said.
  final DateTime? nextTry;

  @override
  bool operator ==(Object other) =>
      other is StatusRetry &&
      other.chatId == chatId &&
      other.chatTitle == chatTitle &&
      other.provider == provider &&
      other.nextTry == nextTry;

  @override
  int get hashCode => Object.hash(chatId, chatTitle, provider, nextTry);
}

/// First-time phone setup, shown while it runs.
@immutable
class StatusSetup {
  const StatusSetup({
    required this.step,
    required this.steps,
    this.name = '',
    this.percent,
  });

  final int step;
  final int steps;
  final String name;
  final int? percent;
}

@immutable
class NotificationStatusInput {
  const NotificationStatusInput({
    this.working = const [],
    this.pendingCount = 0,
    this.firstPendingTitle = '',
    this.firstPendingProject = '',
    this.retries = const [],
    this.pause = NotificationPauseReason.none,
    this.reconnecting = false,
    this.reconnectingLastActivity,
    this.phoneServerRunning = false,
    this.setup,
    this.liveServerCount = 1,
    this.serverName = '',
    this.lastReplyAt,
    this.lastReplyTitle = '',
  });

  /// Chats doing work now, most recently active first. A chat waiting on a
  /// request or on a provider is not in this list.
  final List<StatusChat> working;

  /// Requests waiting on the person: permissions, questions, forms.
  final int pendingCount;
  final String firstPendingTitle;
  final String firstPendingProject;

  /// Chats waiting out a retry; the soonest is shown.
  final List<StatusRetry> retries;
  final NotificationPauseReason pause;
  final bool reconnecting;

  /// What it was doing before the connection dropped, when known.
  final String? reconnectingLastActivity;

  /// The in-app server runs on this phone.
  final bool phoneServerRunning;
  final StatusSetup? setup;

  /// How many servers are live. The server's name appears only above one.
  final int liveServerCount;
  final String serverName;
  final DateTime? lastReplyAt;
  final String lastReplyTitle;
}

/// What the status notification says. [toPayload] is the exact map Android
/// reads (`status` inside `updateLiveStatus`).
@immutable
class NotificationStatus {
  const NotificationStatus({
    required this.kind,
    required this.title,
    this.text = '',
    this.lines = const [],
    this.subText = '',
    this.progress,
    this.actions = const [],
    this.sessionId = '',
    required this.publicTitle,
  });

  final NotificationStatusKind kind;
  final String title;
  final String text;

  /// Inbox lines, one per chat, when several are listed. Empty otherwise.
  final List<String> lines;

  /// The small line beside the app name: project, elapsed time, server.
  final String subText;

  /// 0-100 when a real fraction is known; null means no bar (never an
  /// endless spinner).
  final int? progress;
  final List<NotificationStatusAction> actions;

  /// The chat "Stop the reply" stops.
  final String sessionId;

  /// The lock screen's version: counts only, no title, command or chat name.
  final String publicTitle;

  Map<String, Object?> toPayload() => {
    'kind': kind.wireValue,
    'title': title,
    'text': text,
    'lines': lines,
    'subText': subText,
    'progress': progress,
    'actions': [for (final action in actions) action.wireValue],
    'sessionId': sessionId,
    'publicTitle': publicTitle,
  };

  @override
  bool operator ==(Object other) =>
      other is NotificationStatus &&
      other.kind == kind &&
      other.title == title &&
      other.text == text &&
      listEquals(other.lines, lines) &&
      other.subText == subText &&
      other.progress == progress &&
      listEquals(other.actions, actions) &&
      other.sessionId == sessionId &&
      other.publicTitle == publicTitle;

  @override
  int get hashCode => Object.hash(
    kind,
    title,
    text,
    Object.hashAll(lines),
    subText,
    progress,
    Object.hashAll(actions),
    sessionId,
    publicTitle,
  );

  @override
  String toString() => 'NotificationStatus(${kind.wireValue}: $title)';
}

/// How many inbox lines are listed before "+N more".
const notificationStatusMaxLines = 2;

String _join(Iterable<String> parts) =>
    parts.where((part) => part.trim().isNotEmpty).join(' · ');

/// Builds the status for [input] in [l10n]'s language. [formatTime] writes a
/// clock time the way the person's locale does (the retry time).
NotificationStatus buildNotificationStatus(
  NotificationStatusInput input,
  AppLocalizations l10n, {
  required String Function(DateTime time) formatTime,
  DateTime? now,
}) {
  final several = input.liveServerCount > 1;
  final serverLabel = several && input.serverName.trim().isNotEmpty
      ? l10n.notifStatusOnServer(input.serverName.trim())
      : '';
  final clock = now ?? DateTime.now();

  String elapsed(Duration? value) {
    if (value == null || value.inMinutes < 1) return '';
    if (value.inMinutes >= 60) {
      return l10n.notifStatusHours(value.inHours);
    }
    return l10n.notifStatusMinutes(value.inMinutes);
  }

  List<String> chatLines(List<StatusChat> chats) {
    final shown = chats.take(notificationStatusMaxLines).map((chat) {
      final line = chat.liveLine?.trim();
      return _join([
        chat.title,
        if (line != null && line.isNotEmpty) line else l10n.liveToolWorking,
      ]);
    }).toList();
    final more = chats.length - shown.length;
    return [...shown, if (more > 0) l10n.notifStatusMore(more)];
  }

  final working = input.working;

  // 1. Needs you.
  if (input.pendingCount > 0) {
    final count = input.pendingCount;
    final needs = l10n.notifStatusNeedsYou(count);
    // The title only counts; the text names the chat that needs the person
    // and how many others still work. The working chats are the expanded
    // inbox lines.
    final lines = working.isEmpty ? const <String>[] : chatLines(working);
    return NotificationStatus(
      kind: NotificationStatusKind.needsYou,
      title: needs,
      text: _join([
        input.firstPendingTitle,
        input.firstPendingProject,
        if (working.isNotEmpty) l10n.notifStatusStillWorking(working.length),
      ]),
      lines: lines,
      subText: serverLabel,
      actions: const [NotificationStatusAction.open],
      publicTitle: _join(['OpenCode', needs]),
    );
  }

  // 2. Android ended the background connection.
  if (input.pause == NotificationPauseReason.androidLimit) {
    return NotificationStatus(
      kind: NotificationStatusKind.pausedAndroid,
      title: l10n.notifStatusPausedAndroidTitle,
      text: l10n.notifStatusPausedAndroidBody,
      actions: const [NotificationStatusAction.open],
      publicTitle: l10n.notifStatusPublicPaused,
    );
  }

  // 3. The connection dropped: whatever was working may not still be.
  if (input.reconnecting) {
    final server = input.serverName.trim();
    final last = input.reconnectingLastActivity?.trim() ?? '';
    return NotificationStatus(
      kind: NotificationStatusKind.reconnecting,
      title: several && server.isNotEmpty
          ? l10n.notifStatusReconnectingTitle(server)
          : l10n.notifStatusReconnectingGeneric,
      text: last.isNotEmpty ? last : l10n.notifStatusReconnectingBody,
      actions: const [NotificationStatusAction.open],
      publicTitle: l10n.notifStatusPublicReconnecting,
    );
  }

  // 4. Chats working.
  if (working.isNotEmpty) {
    final waiting = input.retries.length;
    final waitingSuffix = waiting > 0
        ? l10n.notifStatusWaitingCount(waiting)
        : '';
    final publicTitle = l10n.notifStatusPublicWorking(working.length);
    if (working.length == 1) {
      final chat = working.single;
      final line = chat.liveLine?.trim() ?? '';
      final tasks = chat.hasTasks
          ? l10n.notifStatusTasksProgress(chat.tasksDone!, chat.tasksTotal!)
          : '';
      return NotificationStatus(
        kind: NotificationStatusKind.working,
        title: line.isNotEmpty ? line : l10n.liveToolWorking,
        text: _join([chat.title, tasks, waitingSuffix]),
        subText: _join([chat.project, elapsed(chat.elapsed), serverLabel]),
        progress: chat.hasTasks
            ? (chat.tasksDone! * 100 ~/ chat.tasksTotal!).clamp(0, 100)
            : null,
        actions: const [
          NotificationStatusAction.open,
          NotificationStatusAction.stopReply,
        ],
        sessionId: chat.id,
        publicTitle: publicTitle,
      );
    }
    final lines = chatLines(working);
    return NotificationStatus(
      kind: NotificationStatusKind.severalWorking,
      title: l10n.notifStatusChatsWorking(working.length),
      text: _join([lines.first, waitingSuffix]),
      lines: lines,
      subText: serverLabel,
      actions: const [NotificationStatusAction.open],
      publicTitle: publicTitle,
    );
  }

  // 5. The phone is hot.
  if (input.pause == NotificationPauseReason.phoneHot) {
    return NotificationStatus(
      kind: NotificationStatusKind.pausedHot,
      title: l10n.notifStatusPausedHotTitle,
      text: l10n.notifStatusPausedHotBody,
      actions: const [NotificationStatusAction.open],
      publicTitle: l10n.notifStatusPublicPaused,
    );
  }

  // 6. Waiting on a provider.
  if (input.retries.isNotEmpty) {
    final sorted = [...input.retries]
      ..sort((a, b) {
        final x = a.nextTry, y = b.nextTry;
        if (x == null && y == null) return 0;
        if (x == null) return 1;
        if (y == null) return -1;
        return x.compareTo(y);
      });
    final retry = sorted.first;
    final provider = retry.provider?.trim() ?? '';
    final next = retry.nextTry;
    final tries = next == null || next.isBefore(clock)
        ? l10n.notifStatusTriesAgainSoon
        : l10n.notifStatusTriesAgainAt(formatTime(next));
    return NotificationStatus(
      kind: NotificationStatusKind.waiting,
      title: provider.isEmpty
          ? l10n.notifStatusWaitingGeneric
          : l10n.notifStatusWaitingProvider(provider),
      text: _join([tries, retry.chatTitle]),
      subText: serverLabel,
      actions: const [
        NotificationStatusAction.open,
        NotificationStatusAction.stopReply,
      ],
      sessionId: retry.chatId,
      publicTitle: l10n.notifStatusPublicWaiting,
    );
  }

  // 7. The phone server stopped itself while idle.
  if (input.pause == NotificationPauseReason.idle) {
    return NotificationStatus(
      kind: NotificationStatusKind.pausedIdle,
      title: l10n.notifStatusPausedIdleTitle,
      text: l10n.notifStatusPausedIdleBody,
      actions: const [NotificationStatusAction.start],
      publicTitle: l10n.notifStatusPublicPaused,
    );
  }

  // 8. First setup.
  final setup = input.setup;
  if (setup != null) {
    return NotificationStatus(
      kind: NotificationStatusKind.setup,
      title: l10n.notifStatusSetupTitle(setup.step, setup.steps),
      text: setup.name,
      progress: setup.percent?.clamp(0, 100),
      actions: const [NotificationStatusAction.open],
      publicTitle: l10n.notifStatusPublicSetup,
    );
  }

  // 9. Ready.
  final at = input.lastReplyAt;
  String text = l10n.notifStatusReadyBody;
  if (at != null) {
    final age = clock.difference(at);
    final ago = age.inMinutes < 1
        ? ''
        : age.inMinutes >= 60
        ? l10n.notifStatusHours(age.inHours)
        : l10n.notifStatusMinutes(age.inMinutes);
    text = _join([
      ago.isEmpty
          ? l10n.notifStatusLastReplyNow
          : l10n.notifStatusLastReply(ago),
      input.lastReplyTitle,
    ]);
  }
  return NotificationStatus(
    kind: NotificationStatusKind.idle,
    title: l10n.notifStatusReadyTitle,
    text: text,
    subText: input.phoneServerRunning
        ? l10n.notifStatusOnThisPhone
        : serverLabel,
    actions: [
      NotificationStatusAction.newChat,
      if (input.phoneServerRunning) NotificationStatusAction.stopServer,
    ],
    publicTitle: l10n.notifStatusPublicReady,
  );
}
