part of '../chat_screen.dart';

// A worker's conversation when its OpenCode session cannot be read (a team
// on a computer whose store the connected server cannot list, a worker
// still starting): the watching page drawn from the team's live output
// (map team-agent-output, owner Rethink: "merge into chat", slice-P3.6).
//
// It is the chat's watching mode in every part but the transcript's
// source: the same status line (who, and its state from its session), the
// same composer addressed to the worker through the team with its
// receipt, the worker's own page as the top bar's action. The transcript
// is the live output drawn with the chat's own parts
// ([TeamAgentTranscript]: its words as the reply's prose, its tool calls
// folded into the chat's work lines). The title is the task it works on.
//
// Follow-latest works as in the chat: on by default, every new capture
// scrolls to the end; a drag up stops following so the person can read;
// "Jump to latest" resumes. Once the host stops serving the session (404)
// the status line says so and what was cached stays on screen.
//
// Never an endless "Connecting…" (design standard §4, the 8 s rule): an
// agent that is not running says so at once, with the one action that
// helps; one that runs but has written nothing after 8 s says it is
// starting (on a phone, with how long it has been: an agent's first words
// took four minutes on the owner's phone, 2026-09-25).

/// The watching page of the agent the team calls [agentId], drawn from the
/// team's live output.
class TeamWatchLiveScreen extends StatefulWidget {
  const TeamWatchLiveScreen({
    super.key,
    required this.team,
    required this.agentId,
    this.note,
    this.details = true,
  });

  final OrchestrationController team;
  final String agentId;

  /// Why the live output and not the agent's own conversation; shown under
  /// the status line.
  final String? note;

  /// Offers the worker's own page; false when it was opened from there.
  final bool details;

  /// How long a live agent may stay silent before the line says so.
  static const quietAfter = Duration(seconds: 8);

  @override
  State<TeamWatchLiveScreen> createState() => _TeamWatchLiveScreenState();
}

class _TeamWatchLiveScreenState extends State<TeamWatchLiveScreen> {
  /// A drag that leaves less than this above the end still counts as
  /// "at the end" (a nudge does not stop following).
  static const _endSlack = 24.0;

  late final AgentOutputTail _tail;
  final _scroll = ScrollController();
  bool _follow = true;
  late final DateTime _openedAt = DateTime.now();
  bool _quiet = false;
  Timer? _clock;
  ChatWatch? _watch;

  OrchestrationController get _team => widget.team;

  @override
  void initState() {
    super.initState();
    _tail = _team.watchAgentOutput(widget.agentId)..addListener(_changed);
    _scroll.addListener(_onScroll);
    _team.addListener(_teamChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToEnd());
    // After 8 s without a first word, then once a minute for the "so far".
    _clock = Timer(TeamWatchLiveScreen.quietAfter, () {
      if (!mounted) return;
      setState(() => _quiet = true);
      _clock = Timer.periodic(const Duration(minutes: 1), (_) {
        if (mounted && !_tail.received) setState(() {});
      });
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _watch ??= _teamWatch(
      context,
      agentId: widget.agentId,
      agent: _agent,
      team: _team,
      details: widget.details,
    );
  }

  @override
  void dispose() {
    _clock?.cancel();
    _team.removeListener(_teamChanged);
    _tail.removeListener(_changed);
    _team.unwatchAgentOutput(widget.agentId);
    _scroll.dispose();
    super.dispose();
  }

  void _teamChanged() {
    if (mounted) setState(() {});
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (_follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToEnd());
    }
  }

  void _jumpToEnd() {
    if (!mounted || !_scroll.hasClients) return;
    final end = _scroll.position.maxScrollExtent;
    if (_scroll.offset != end) _scroll.jumpTo(end);
  }

  void _setFollow(bool value) {
    setState(() => _follow = value);
    if (value) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToEnd());
    }
  }

  /// A drag up, away from the end, stops following; a jump to the end
  /// (the app's own) never does.
  void _onScroll() {
    if (!_follow || !_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.userScrollDirection == ScrollDirection.idle) return;
    if (position.pixels < position.maxScrollExtent - _endSlack) {
      setState(() => _follow = false);
    }
  }

  OrchestrationAgent? get _agent => _teamAgentById(_team, widget.agentId);

  /// The task the agent works on: the page's title.
  WorkItem? _workOf(OrchestrationAgent? agent) {
    final id = agent?.currentWorkId;
    if (id == null) return null;
    for (final item in _team.snapshot.work) {
      if (item.id == id) return item;
    }
    return null;
  }

  /// The status line while nothing has arrived: honest after 8 s.
  (String, AppStatusTone, KitAction?) _waiting(
    AppLocalizations l10n,
    OrchestrationAgent? agent,
  ) {
    if (agent != null && !teamAgentIsLive(agent)) {
      return (
        l10n.teamOutputNotRunning(teamAgentShortName(agent) ?? agent.name),
        // Degraded, not a question for the person (LOOK-4): the action
        // says what helps.
        AppStatusTone.neutral,
        teamUnstickAction(
          context,
          _team,
          keyPrefix: 'chat-watching-live',
          wake: [agent],
          wakeLabel: l10n.teamAgentStartIt,
        ),
      );
    }
    if (!_quiet) {
      return (l10n.teamUiAgentOutputConnecting, AppStatusTone.neutral, null);
    }
    final hostMode = _team.host?.hostMode ?? _team.config.hostMode;
    if (hostMode == OrchestrationHostMode.phone) {
      final since = agent?.sessionStartedAt ?? _openedAt;
      final age = DateTime.now().difference(since);
      return (
        l10n.teamOutputStartingPhone(
          teamElapsedLabel(l10n, age.isNegative ? Duration.zero : age),
        ),
        AppStatusTone.progress,
        null,
      );
    }
    return (l10n.teamOutputSilent, AppStatusTone.progress, null);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _chatL10n(context);
    final tokens = KitTokens.of(context);
    final watch = _watch!;
    final tail = _tail;
    final text = tail.text;
    final agent = _agent;
    final work = _workOf(agent);
    final (status, tone, action) = tail.ended
        ? (l10n.teamUiAgentOutputEnded, AppStatusTone.neutral, null)
        : !tail.available
        ? (l10n.teamUiAgentOutputUnavailable, AppStatusTone.neutral, null)
        : tail.received
        ? (() {
            final (banner, bannerTone) = watch.banner();
            return (banner, bannerTone, null);
          })()
        : _waiting(l10n, agent);
    final canFollow = !tail.ended && tail.available;
    final details = watch.onDetails;
    // Ended before a word arrived: nothing will fill in. The page says so
    // once, in place (not also on the status line), with the ways on.
    final endedEmpty = tail.ended && text.isEmpty;
    return KitScreen(
      key: const ValueKey('chat-watching-live'),
      topBar: KitTopBar(
        // Which task this output belongs to; the worker is on the status
        // line.
        title: work?.title ?? l10n.teamUiAgentOutputTitle,
        titleKey: const ValueKey('chat-watching-live-title'),
        actions: [
          if (text.isNotEmpty)
            KitAction.copy(
              key: const ValueKey('chat-watching-live-copy'),
              label: l10n.teamUiAgentOutputCopy,
              text: () => text,
            ),
          if (details != null && watch.detailsLabel != null)
            KitAction(
              key: const ValueKey('chat-watching-details'),
              icon: AppIconography.info,
              label: watch.detailsLabel!,
              onPressed: () => details(context),
            ),
        ],
      ),
      // The one status line (design standard §5): who, live, connecting,
      // unavailable or ended. In the window's one slot, so a connection or
      // app line outranks it instead of stacking above it (P4.4).
      status: endedEmpty
          ? null
          : KitStatus(
              kind: KitStatusKind.work,
              id: 'chat:watching-live',
              key: const ValueKey('chat-watching-banner'),
              icon: tail.ended
                  ? AppIconography.cloudOff
                  : !tail.available
                  ? AppIconography.warning
                  : AppIconography.agent,
              tone: tone,
              message: status,
              action: action,
            ),
      body: _watchLayer(
        watch: watch,
        body: KitJumpPillLayer(
          pill: KitJumpPill(
            pillKey: const ValueKey('chat-watching-live-jump'),
            label: l10n.teamUiAgentOutputJump,
            visible: !_follow && canFollow && text.isNotEmpty,
            onPressed: () => _setFollow(true),
          ),
          // The end padding is read under the composer layer, which adds its
          // height to the bottom inset.
          child: Builder(
            builder: (context) => ListView(
              key: const ValueKey('chat-watching-live-list'),
              controller: _scroll,
              padding: EdgeInsetsDirectional.fromSTEB(
                tokens.space2,
                tokens.space3,
                tokens.space2,
                KitScreen.endPadding(context),
              ),
              children: [
                // Why the live output and not its conversation: the
                // transcript's first line, so it scrolls away and never
                // squeezes the composer on a small window.
                if (widget.note case final note?)
                  Padding(
                    padding: EdgeInsetsDirectional.only(
                      start: tokens.gutter - tokens.space2,
                      end: tokens.gutter - tokens.space2,
                      bottom: tokens.space3,
                    ),
                    child: KitNotice(
                      key: const ValueKey('chat-watching-live-note'),
                      icon: AppIconography.info,
                      message: note,
                      liveRegion: false,
                    ),
                  ),
                if (endedEmpty)
                  KitStateView(
                    key: const ValueKey('chat-watching-ended'),
                    size: KitStateSize.inline,
                    icon: AppIconography.cloudOff,
                    title: l10n.chatWatchEndedTitle,
                    body: l10n.chatWatchEndedBody,
                    primary: KitAction(
                      key: const ValueKey('chat-watching-ended-back'),
                      label: widget.details
                          ? l10n.chatWatchBackToTask
                          : l10n.chatWatchBackToWorker,
                      onPressed: () => unawaited(Navigator.maybePop(context)),
                    ),
                    secondary: details == null || watch.detailsLabel == null
                        ? null
                        : KitAction(
                            key: const ValueKey('chat-watching-ended-about'),
                            label: watch.detailsLabel!,
                            onPressed: () => details(context),
                          ),
                  )
                else if (text.isEmpty)
                  // Nothing said yet; the status line says why.
                  Padding(
                    padding: EdgeInsetsDirectional.symmetric(
                      horizontal: tokens.gutter - tokens.space2,
                    ),
                    child: KitText(
                      l10n.chatWatchEmptyBody,
                      key: const ValueKey('chat-watching-empty'),
                      role: KitTextRole.secondary,
                      tone: KitTextTone.secondary,
                    ),
                  )
                else
                  // What it said and did, drawn as the chat draws a
                  // reply: prose, and its calls folded into lines.
                  TeamAgentTranscript(
                    key: const ValueKey('chat-watching-live-text'),
                    text: text,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
