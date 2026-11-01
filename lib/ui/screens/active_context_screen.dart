import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/product_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import '../app_theme.dart';
import '../kit/kit.dart';
import '../widgets/product_states.dart' show productErrorText;

/// What the model reads on its next turn (map pages active-context and
/// active-context-message): the messages the server keeps for this
/// conversation after its latest compaction, searchable and filtered by
/// kind, each opening its parts.
class ActiveContextScreen extends StatefulWidget {
  const ActiveContextScreen({
    super.key,
    required this.controller,
    required this.sessionID,
  });
  final ConnectionController controller;
  final String sessionID;
  @override
  State<ActiveContextScreen> createState() => _ActiveContextScreenState();
}

class _ActiveContextScreenState extends State<ActiveContextScreen> {
  List<ActiveContextMessage>? _messages;
  Object? _error;
  bool _loading = false;
  DateTime? _loadStartedAt;
  int _generation = 0;
  late final int _location;
  late int _history;
  late int _refresh;
  late bool _busy;
  String _query = '';
  final _search = TextEditingController();
  String? _type;
  bool get _sameLocation => widget.controller.locationRevision == _location;
  AppLocalizations get _l10n =>
      lookupAppLocalizations(Localizations.localeOf(context));

  @override
  void initState() {
    super.initState();
    _location = widget.controller.locationRevision;
    _history = widget.controller.sessionHistoryRevision(widget.sessionID);
    _refresh = widget.controller.dataRefreshRevision;
    _busy = widget.controller.busySessions.contains(widget.sessionID);
    widget.controller.addListener(_changed);
    _load();
  }

  void _changed() {
    if (!_sameLocation) {
      _generation++;
      setState(() {
        _messages = null;
        _loading = false;
        _error = const ActiveContextException(ActiveContextFailure.changed);
      });
      return;
    }
    final c = widget.controller;
    final history = c.sessionHistoryRevision(widget.sessionID);
    final busy = c.busySessions.contains(widget.sessionID);
    final changed =
        history != _history ||
        c.dataRefreshRevision != _refresh ||
        (_busy && !busy);
    if (history != _history) _messages = null;
    _history = history;
    _refresh = c.dataRefreshRevision;
    _busy = busy;
    if (changed) _load();
  }

  Future<void> _load() async {
    if (!_sameLocation) return;
    final generation = ++_generation;
    final history = widget.controller.sessionHistoryRevision(widget.sessionID);
    setState(() {
      _loading = true;
      _loadStartedAt = DateTime.now();
      _error = null;
    });
    try {
      final repository = await widget.controller.prepareActionRepository();
      if (!mounted || generation != _generation || !_sameLocation) return;
      if (repository is! ActiveContextGateway ||
          !(repository as ActiveContextGateway).activeContextSupported) {
        throw const ActiveContextException(ActiveContextFailure.unsupported);
      }
      final messages = await (repository as ActiveContextGateway)
          .loadActiveContext(widget.sessionID);
      if (!mounted || generation != _generation || !_sameLocation) return;
      if (!identical(repository, widget.controller.repository) ||
          history !=
              widget.controller.sessionHistoryRevision(widget.sessionID)) {
        throw const ActiveContextException(ActiveContextFailure.changed);
      }
      final boundary = widget
          .controller
          .sessionsById[widget.sessionID]
          ?.stagedRevert
          ?.messageID;
      setState(() {
        _messages = boundary == null
            ? messages
            : messages
                  .where((message) => message.id.compareTo(boundary) < 0)
                  .toList();
        if (_type != null &&
            !_messages!.any((message) => message.type == _type)) {
          _type = null;
        }
      });
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error);
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    _search.dispose();
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  String _errorText(Object error) => error is ActiveContextException
      ? switch (error.failure) {
          ActiveContextFailure.unsupported => _l10n.activeContextUnsupported,
          ActiveContextFailure.changed => _l10n.activeContextChanged,
          ActiveContextFailure.invalidResponse => _l10n.activeContextInvalid,
        }
      : productErrorText(error);

  void _clearSearch() {
    _search.clear();
    setState(() {
      _query = '';
      _type = null;
    });
  }

  void _open(ActiveContextMessage message) => unawaited(
    pushKitPage<void>(
      context,
      (_) => _ContextMessageScreen(
        controller: widget.controller,
        location: _location,
        sessionID: widget.sessionID,
        history: _history,
        message: message,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final messages = _messages;
    final counts = <String, int>{};
    for (final message in messages ?? const <ActiveContextMessage>[]) {
      counts.update(message.type, (value) => value + 1, ifAbsent: () => 1);
    }
    final visible =
        messages
            ?.where(
              (message) =>
                  (_type == null || message.type == _type) &&
                  message.matches(_query),
            )
            .toList() ??
        const <ActiveContextMessage>[];
    final listed = _sameLocation && messages != null && messages.isNotEmpty;
    return KitScreen(
      topBar: KitTopBar(
        title: l10n.activeContextTitle,
        actions: [
          KitAction(
            label: l10n.activeContextRefresh,
            icon: AppIconography.retry,
            onPressed: _loading || !_sameLocation ? null : _load,
          ),
        ],
      ),
      width: KitScreenWidth.list,
      loading: _loading && messages != null,
      loadingLabel: l10n.activeContextLoading,
      search: listed
          ? KitSearchField(
              label: l10n.activeContextSearch,
              controller: _search,
              fieldKey: const ValueKey('active-context-search'),
              resultCount: visible.length,
              onChanged: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
              filters: [
                KitMenuItem(
                  label: l10n.activeContextAllCount(messages.length),
                  checked: _type == null,
                  onSelected: () => setState(() => _type = null),
                ),
                for (final entry in counts.entries)
                  KitMenuItem(
                    key: ValueKey('active-context-filter-${entry.key}'),
                    label: l10n.activeContextTypeCount(
                      contextTypeLabel(l10n, entry.key),
                      entry.value,
                    ),
                    checked: _type == entry.key,
                    onSelected: () => setState(() => _type = entry.key),
                  ),
              ],
              activeFilter: _type == null
                  ? null
                  : contextTypeLabel(l10n, _type!),
              onClearFilter: () => setState(() => _type = null),
            )
          : null,
      body: _body(context, l10n, messages, visible),
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    List<ActiveContextMessage>? messages,
    List<ActiveContextMessage> visible,
  ) {
    if (!_sameLocation) {
      return KitStateView(
        key: const ValueKey('active-context-changed'),
        icon: AppIconography.info,
        title: l10n.activeContextChangedTitle,
        body: l10n.activeContextChanged,
      );
    }
    if (messages == null) {
      final error = _error;
      if (error != null) {
        return KitStateView.error(
          key: const ValueKey('active-context-failed'),
          title: l10n.activeContextFailedTitle,
          body: _errorText(error),
          error: error,
          retry: KitAction(label: l10n.commonRetry, onPressed: _load),
        );
      }
      return KitStateView(
        key: const ValueKey('active-context-loading'),
        icon: AppIconography.layers,
        title: l10n.activeContextLoading,
        progress: const KitProgress.waiting(),
        since: _loadStartedAt,
        onSlow: [KitAction(label: l10n.commonRetry, onPressed: _load)],
      );
    }
    final tokens = KitTokens.of(context);
    final error = _error;
    return KitRefresh(
      onRefresh: _load,
      child: ListView(
        key: const ValueKey('active-context-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsetsDirectional.only(
          top: tokens.space2,
          bottom: KitScreen.endPadding(context),
        ),
        children: [
          // A failed refresh keeps the rows and says they are the last
          // snapshot (STATE-2).
          KitReveal(
            child: error == null
                ? null
                : Padding(
                    padding: EdgeInsetsDirectional.symmetric(
                      horizontal: tokens.gutter,
                      vertical: tokens.space2,
                    ),
                    child: KitNotice(
                      key: const ValueKey('active-context-notice'),
                      tone: AppStatusTone.failure,
                      message: l10n.activeContextRefreshFailed(
                        _errorText(error),
                      ),
                      actions: [
                        KitAction(label: l10n.commonRetry, onPressed: _load),
                      ],
                    ),
                  ),
          ),
          Padding(
            padding: EdgeInsetsDirectional.symmetric(
              horizontal: tokens.gutter,
              vertical: tokens.space2,
            ),
            child: KitText(
              l10n.activeContextIntro,
              role: KitTextRole.secondary,
              tone: KitTextTone.secondary,
            ),
          ),
          if (messages.isEmpty)
            KitStateView(
              key: const ValueKey('active-context-empty'),
              icon: AppIconography.layers,
              title: l10n.activeContextEmpty,
              body: l10n.activeContextEmptyDetail,
              size: KitStateSize.inline,
            )
          else if (visible.isEmpty)
            KitSearchNoMatch(
              key: const ValueKey('active-context-no-match'),
              query: _query.isEmpty
                  ? contextTypeLabel(l10n, _type ?? '')
                  : _search.text.trim(),
              what: l10n.activeContextWhat,
              onClear: _clearSearch,
            )
          else ...[
            // No count line: the search field already says how many match.
            KitRowGroup(
              leadingIcons: false,
              children: [for (final message in visible) _row(l10n, message)],
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(AppLocalizations l10n, ActiveContextMessage message) {
    final preview = message.previewFor(_query);
    final title = contextTypeLabel(l10n, message.type);
    return KitRow(
      key: ValueKey('active-context-${message.id}'),
      title: title,
      supporting: TextSpan(
        text: preview.isEmpty ? l10n.activeContextNoText : preview,
      ),
      supportingMaxLines: 3,
      trailing: const KitChevron(),
      onTap: () => _open(message),
      menuLabel: l10n.activeContextRowMenu(title),
      menu: [
        KitMenuItem(
          label: l10n.activeContextOpenMessage(title),
          icon: AppIconography.layers,
          onSelected: () => _open(message),
        ),
        if (preview.isNotEmpty)
          KitMenuItem.copy(
            label: l10n.activeContextCopyMessage(title),
            text: () => [
              for (final part in message.content)
                if (part.text.isNotEmpty) part.text,
            ].join('\n\n'),
          ),
      ],
    );
  }
}

String contextTypeLabel(AppLocalizations l10n, String type) => switch (type) {
  'user' => l10n.activeContextUser,
  'assistant' => l10n.activeContextAssistant,
  'system' => l10n.activeContextSystem,
  'synthetic' => l10n.activeContextSynthetic,
  'skill' => l10n.activeContextSkill,
  'shell' => l10n.activeContextShell,
  'compaction' => l10n.activeContextCompaction,
  'agent-switched' ||
  'model-switched' ||
  'location-switched' => l10n.activeContextChange,
  _ => type,
};

/// The [AppLocalizations.activeContextMessageTitle] selector for a message
/// type: the three switch kinds read as one "Conversation change".
String _roleSelector(String type) => switch (type) {
  'user' ||
  'assistant' ||
  'system' ||
  'synthetic' ||
  'skill' ||
  'shell' ||
  'compaction' => type,
  'agent-switched' || 'model-switched' || 'location-switched' => 'change',
  _ => 'other',
};

String _partKind(AppLocalizations l10n, ContextContentKind kind) =>
    switch (kind) {
      ContextContentKind.text => l10n.activeContextText,
      ContextContentKind.reasoning => l10n.transcriptFindReasoning,
      ContextContentKind.toolInput => l10n.activeContextToolInput,
      ContextContentKind.toolOutput => l10n.activeContextToolOutput,
      ContextContentKind.file => l10n.activeContextFile,
      ContextContentKind.notice => l10n.activeContextNotice,
      ContextContentKind.pruned => l10n.activeContextPruned,
      ContextContentKind.truncated => l10n.activeContextTruncated,
    };

/// One message's parts, in order, under "{Role} message"; the id and the
/// snapshot disclaimer fold under Details at the end (map
/// active-context-message).
class _ContextMessageScreen extends StatelessWidget {
  const _ContextMessageScreen({
    required this.controller,
    required this.location,
    required this.message,
    required this.sessionID,
    required this.history,
  });
  final ConnectionController controller;
  final int location;
  final ActiveContextMessage message;
  final String sessionID;
  final int history;

  @override
  Widget build(BuildContext context) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    return KitScreen(
      topBar: KitTopBar(
        title: l10n.activeContextMessageTitle(_roleSelector(message.type)),
      ),
      width: KitScreenWidth.list,
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          if (controller.locationRevision != location ||
              controller.sessionHistoryRevision(sessionID) != history) {
            return KitStateView(
              key: const ValueKey('active-context-message-changed'),
              icon: AppIconography.info,
              title: l10n.activeContextChangedTitle,
              body: l10n.activeContextChanged,
            );
          }
          final tokens = KitTokens.of(context);
          return ListView(
            padding: KitScreen.padding(
              context,
            ).add(EdgeInsetsDirectional.only(top: tokens.space3)),
            children: [
              for (final part in message.content) ...[
                _Part(part: part),
                SizedBox(height: tokens.sectionGap),
              ],
              // What the snapshot leaves out is a technical note, so it
              // folds under Details with the id (KIT-33).
              KitDetailsFold(
                notes: [l10n.activeContextContentHelp],
                values: [
                  KitTechnicalValue(l10n.activeContextMessageId, message.id),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Part extends StatelessWidget {
  const _Part({required this.part});
  final ContextContent part;

  @override
  Widget build(BuildContext context) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final tokens = KitTokens.of(context);
    final kind = _partKind(l10n, part.kind);
    final heading = part.name?.isNotEmpty == true
        ? l10n.activeContextPartHeading(kind, part.name!)
        : kind;
    final technical =
        part.kind == ContextContentKind.toolInput ||
        part.kind == ContextContentKind.toolOutput;
    final dropped =
        part.kind == ContextContentKind.pruned ||
        part.kind == ContextContentKind.truncated;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: KitText(heading, role: KitTextRole.label)),
            if (part.text.isNotEmpty && !dropped)
              KitIconButton.copy(
                text: () => part.text,
                tooltip: l10n.activeContextCopyPart(heading),
              ),
          ],
        ),
        SizedBox(height: tokens.space2),
        if (!dropped)
          part.text.isEmpty
              ? KitText(
                  l10n.activeContextNoText,
                  role: KitTextRole.secondary,
                  tone: KitTextTone.secondary,
                )
              : technical
              ? KitText.mono(part.text, selectable: true)
              : KitText.selectable(part.text),
      ],
    );
  }
}
