import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/server_gateway.dart';
import '../../l10n/app_localizations.dart';

import '../../domain/web_source_selection.dart';
import '../../state/connection.dart';
import '../../state/web_sources_overview.dart';
import '../widgets/external_link.dart';
import '../app_theme.dart';
import '../kit/kit.dart';

export '../../domain/web_source_selection.dart';

/// Returns `List<WebSourceSelection>` on explicit review confirmation, or null
/// on cancellation. Does not send a prompt, attach a remote file or fetch URLs.
///
/// Map page web-sources: search (when the server has a provider) or paste a
/// link. A result toggles in place ("Added" with a check; tap again to
/// remove it); only pasted links, which have no result row, are listed
/// under "Links you added". The pinned primary says what it does: "Add 2
/// sources to prompt" (Close with none).
class WebSourcesScreen extends StatefulWidget {
  const WebSourcesScreen({super.key, required this.controller});

  final ConnectionController controller;

  @override
  State<WebSourcesScreen> createState() => _WebSourcesScreenState();
}

class _WebSourcesScreenState extends State<WebSourcesScreen> {
  final _query = TextEditingController();
  final _url = TextEditingController();
  final _title = TextEditingController();
  final _excerpt = TextEditingController();
  late WebSourcesOverview _overview;

  /// Why the pasted link was not added; under the address field.
  String? _error;

  /// Why a search result was not added; over the results.
  String? _resultError;

  @override
  void initState() {
    super.initState();
    _overview = WebSourcesOverview(controller: widget.controller);
    _overview.addListener(_changed);
    unawaited(_overview.discoverProviders());
  }

  void _changed() {
    if (!mounted) return;
    if (_overview.scopeChanged) {
      _query.clear();
      _url.clear();
      _title.clear();
      _excerpt.clear();
      _error = null;
      _resultError = null;
    }
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant WebSourcesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    _overview.removeListener(_changed);
    _overview.dispose();
    _overview = WebSourcesOverview(controller: widget.controller);
    _overview.addListener(_changed);
    unawaited(_overview.discoverProviders());
    _query.clear();
    _url.clear();
    _title.clear();
    _excerpt.clear();
    _error = null;
    _resultError = null;
  }

  AppLocalizations get _l10n =>
      lookupAppLocalizations(Localizations.localeOf(context));

  void _add() {
    if (_overview.scopeChanged) return;
    final uri = safeExternalLinkUri(_url.text);
    if (uri == null) {
      setState(() => _error = _l10n.webSourcesInvalidUrl);
      return;
    }
    try {
      final source = WebSourceSelection(
        title: _title.text,
        url: uri.toString(),
        excerpt: _excerpt.text,
      );
      final error = _overview.add(source);
      setState(() => _error = error);
      if (error != null) return;
      _url.clear();
      _title.clear();
      _excerpt.clear();
      FocusScope.of(context).unfocus();
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  void _addResult(WebSourceSelection result) =>
      setState(() => _resultError = _overview.add(result));

  /// A result already added is taken out again by tapping it.
  void _removeResult(WebSourceSelection result) {
    for (final source in _overview.sources) {
      if (source.url == result.url) {
        _overview.remove(source);
        break;
      }
    }
    setState(() => _resultError = null);
  }

  void _open(String url) {
    if (_overview.reviewedSelection() == null) return;
    openExternalLink(context, url);
  }

  void _search() {
    if (_query.text.trim().isEmpty) return;
    setState(() => _resultError = null);
    unawaited(_overview.search(_query.text));
  }

  void _close() => Navigator.of(context).pop<List<WebSourceSelection>>();

  void _confirm() {
    final sources = _overview.reviewedSelection();
    if (sources == null || sources.isEmpty) return;
    Navigator.of(context).pop<List<WebSourceSelection>>(sources);
  }

  @override
  void dispose() {
    _overview.removeListener(_changed);
    _overview.dispose();
    _query.dispose();
    _url.dispose();
    _title.dispose();
    _excerpt.dispose();
    super.dispose();
  }

  bool _added(WebSourceSelection source) =>
      _overview.sources.any((item) => item.url == source.url);

  String _host(String url) => Uri.tryParse(url)?.host ?? url;

  List<Widget> _searchPanel(BuildContext context, AppLocalizations l10n) {
    final tokens = KitTokens.of(context);
    final busy = _overview.discovering || _overview.searching;
    final failure = _overview.searchFailure;
    final noProvider = !_overview.discovering && _overview.providers.isEmpty;
    final gutter = EdgeInsetsDirectional.symmetric(
      horizontal: tokens.gutter,
      vertical: tokens.space2,
    );
    final results = _overview.results;
    return [
      KitReveal(
        child: failure != null
            ? Padding(
                padding: gutter,
                child: KitNotice(
                  key: const ValueKey('web-search-failure'),
                  tone: AppStatusTone.failure,
                  title: l10n.webSearchFailedTitle,
                  message: switch (failure) {
                    WebSearchFailureKind.unavailable =>
                      l10n.webSearchUnavailable,
                    WebSearchFailureKind.authentication =>
                      l10n.webSearchAuthentication,
                    WebSearchFailureKind.invalidResponse =>
                      l10n.webSearchInvalidResponse,
                    WebSearchFailureKind.failed => l10n.webSearchFailed,
                  },
                  actions: [
                    if (failure == WebSearchFailureKind.unavailable ||
                        failure == WebSearchFailureKind.invalidResponse)
                      KitAction(
                        label: l10n.webSearchRefresh,
                        onPressed: busy ? null : _overview.discoverProviders,
                      )
                    else
                      KitAction(
                        label: l10n.webSearchTryAgain,
                        onPressed: busy || _query.text.trim().isEmpty
                            ? null
                            : _search,
                      ),
                  ],
                ),
              )
            : noProvider
            ? Padding(
                padding: gutter,
                child: KitNotice(
                  key: const ValueKey('web-search-no-provider'),
                  message: l10n.webSearchUnavailable,
                  actions: [
                    KitAction(
                      label: l10n.webSearchRefresh,
                      onPressed: busy ? null : _overview.discoverProviders,
                    ),
                  ],
                ),
              )
            : null,
      ),
      if (_overview.providers.isNotEmpty)
        KitRowGroup(
          leadingIcons: false,
          children: [
            KitPickerRow<String>(
              key: ValueKey(
                'web-provider-${_overview.providers.map((p) => p.id).join(',')}',
              ),
              title: l10n.webSearchProvider,
              choices: [
                for (final provider in _overview.providers)
                  KitChoice(value: provider.id, title: provider.name),
              ],
              selected: _overview.providerID,
              onSelected: busy ? null : _overview.chooseProvider,
              disabledReason: busy ? l10n.webSearchBusy : null,
            ),
          ],
        ),
      Padding(
        padding: gutter,
        child: KitField(
          fieldKey: const ValueKey('web-search-query'),
          label: l10n.webSearchQuery,
          controller: _query,
          hint: l10n.webSearchQueryHint,
          maxLength: 1000,
          textInputAction: TextInputAction.search,
          enabled: !busy && _overview.providers.isNotEmpty,
          disabledReason: busy
              ? l10n.webSearchBusy
              : l10n.webSearchNeedsProvider,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _search(),
          action: KitAction(
            key: const ValueKey('web-search-submit'),
            label: l10n.webSearchSubmit,
            icon: AppIconography.search,
            onPressed:
                busy ||
                    _overview.providerID == null ||
                    _query.text.trim().isEmpty
                ? null
                : _search,
          ),
        ),
      ),
      KitReveal(
        child: _resultError == null
            ? null
            : Padding(
                padding: gutter,
                child: KitNotice(
                  key: const ValueKey('web-result-error'),
                  message: _resultError!,
                ),
              ),
      ),
      if (_overview.searched && results.isEmpty)
        KitStateView(
          key: const ValueKey('web-search-empty'),
          icon: AppIconography.search,
          title: l10n.webSearchEmpty,
          body: l10n.webSearchEmptyDetail,
          size: KitStateSize.inline,
        ),
      if (results.isNotEmpty)
        KitRowGroup(
          label: l10n.webSearchResults(results.length),
          leadingIcons: false,
          children: [for (final result in results) _resultRow(l10n, result)],
        ),
      if (_overview.omittedResults > 0)
        Padding(
          padding: gutter,
          child: KitText(
            l10n.webSearchOmitted,
            role: KitTextRole.caption,
            tone: KitTextTone.secondary,
          ),
        ),
    ];
  }

  Widget _resultRow(AppLocalizations l10n, WebSourceSelection result) {
    final added = _added(result);
    final host = _host(result.url);
    return KitRow(
      key: ValueKey('web-result-${result.url}'),
      title: result.title,
      titleMaxLines: 2,
      supporting: TextSpan(
        text: [
          KitBidi.ltr(host),
          if (result.excerpt case final excerpt? when excerpt.isNotEmpty)
            excerpt,
        ].join(' · '),
      ),
      supportingMaxLines: 3,
      // A toggle: "Added" with a check, and tapping the row again removes
      // it (its menu names it: "Remove … from prompt").
      trailing: added
          ? KitStatusMark(
              state: KitMarkState.done,
              label: l10n.webSourcesAdded,
              showLabel: true,
            )
          : KitIconButton(
              icon: AppIconography.add,
              tooltip: l10n.webSourcesAddNamed(result.title),
              onPressed: () => _addResult(result),
            ),
      onTap: added ? () => _removeResult(result) : () => _addResult(result),
      menuLabel: l10n.webSourcesRowMenu(result.title),
      menu: [
        if (added)
          KitMenuItem(
            label: l10n.webSourcesRemoveNamed(result.title),
            icon: AppIconography.close,
            onSelected: () => _removeResult(result),
          )
        else
          KitMenuItem(
            label: l10n.webSourcesAddNamed(result.title),
            icon: AppIconography.add,
            onSelected: () => _addResult(result),
          ),
        KitMenuItem(
          label: l10n.webSourcesOpenHost(host),
          icon: AppIconography.externalLink,
          onSelected: () => _open(result.url),
        ),
      ],
    );
  }

  List<Widget> _manualFields(BuildContext context, AppLocalizations l10n) {
    final tokens = KitTokens.of(context);
    final gap = SizedBox(height: tokens.space3);
    return [
      KitField(
        fieldKey: const ValueKey('web-source-url'),
        label: l10n.webSourcesUrl,
        controller: _url,
        kind: KitFieldKind.url,
        maxLength: WebSourceSelection.maxUrlLength,
        error: _error,
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
      ),
      gap,
      KitField(
        fieldKey: const ValueKey('web-source-title'),
        label: l10n.webSourcesLabel,
        controller: _title,
        maxLength: WebSourceSelection.maxTitleLength,
      ),
      gap,
      KitField(
        fieldKey: const ValueKey('web-source-excerpt'),
        label: l10n.webSourcesExcerpt,
        controller: _excerpt,
        kind: KitFieldKind.multiline,
        maxLength: WebSourceSelection.maxExcerptLength,
        helper: l10n.webSourcesExcerptHint,
      ),
      gap,
      KitActionBlock(
        secondary: KitAction(
          key: const ValueKey('web-source-add'),
          label: l10n.webSourcesAddLink,
          icon: AppIconography.add,
          onPressed: _add,
        ),
      ),
    ];
  }

  Widget _manualEntry(BuildContext context, AppLocalizations l10n) {
    final tokens = KitTokens.of(context);
    final fields = Padding(
      padding: EdgeInsetsDirectional.symmetric(
        horizontal: tokens.gutter,
        vertical: tokens.space2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _manualFields(context, l10n),
      ),
    );
    if (!_overview.supportsSearch) return fields;
    return KitRowGroup(
      leadingIcons: false,
      children: [
        KitExpandRow(
          headerKey: const ValueKey('web-source-paste'),
          title: l10n.webSearchManual,
          supporting: TextSpan(text: l10n.webSourcesPasteDetail),
          maintainState: true,
          children: [fields],
        ),
      ],
    );
  }

  /// Added sources that have no result row above: the pasted links. A
  /// result that was added is marked on its own row, not listed twice.
  List<(int, WebSourceSelection)> get _pasted {
    final resultUrls = {for (final result in _overview.results) result.url};
    final sources = _overview.sources;
    return [
      for (var index = 0; index < sources.length; index++)
        if (!resultUrls.contains(sources[index].url)) (index, sources[index]),
    ];
  }

  Widget _addedList(
    AppLocalizations l10n,
    List<(int, WebSourceSelection)> pasted,
  ) => KitRowGroup(
    key: const ValueKey('web-sources-added'),
    label: l10n.webSourcesPastedLinks,
    leadingIcons: false,
    children: [
      for (final (index, source) in pasted) _addedRow(l10n, source, index),
    ],
  );

  Widget _addedRow(AppLocalizations l10n, WebSourceSelection source, int i) {
    final host = _host(source.url);
    return KitRow(
      key: ValueKey('web-source-row-$i'),
      title: source.title,
      supporting: TextSpan(
        text: [
          KitBidi.ltr(host),
          if (source.excerpt case final excerpt? when excerpt.isNotEmpty)
            excerpt,
        ].join(' · '),
      ),
      supportingMaxLines: 2,
      trailing: KitIconButton(
        key: ValueKey('web-source-remove-$i'),
        icon: AppIconography.close,
        tooltip: l10n.webSourcesRemoveNamed(source.title),
        onPressed: () => _overview.remove(source),
      ),
      onTap: () => _open(source.url),
      menuLabel: l10n.webSourcesRowMenu(source.title),
      menu: [
        KitMenuItem(
          key: ValueKey('web-source-open-$i'),
          label: l10n.webSourcesOpenHost(host),
          icon: AppIconography.externalLink,
          onSelected: () => _open(source.url),
        ),
        KitMenuItem(
          label: l10n.webSourcesRemoveNamed(source.title),
          icon: AppIconography.close,
          onSelected: () => _overview.remove(source),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final blocked = _overview.scopeChanged;
    final count = _overview.selectedCount;
    final tokens = KitTokens.of(context);
    final pasted = _pasted;
    return KitScreen(
      topBar: KitTopBar(title: l10n.webSourcesTitle),
      width: KitScreenWidth.list,
      loading: !blocked && (_overview.discovering || _overview.searching),
      loadingLabel: _overview.searching
          ? l10n.webSearchSearching
          : l10n.webSearchFindingProviders,
      bottom: blocked
          ? null
          : count == 0
          ? KitActionBlock(
              secondary: KitAction(
                key: const ValueKey('web-sources-close'),
                label: l10n.webSourcesClose,
                onPressed: _close,
              ),
            )
          : KitActionBlock(
              primary: KitAction(
                key: const ValueKey('web-sources-confirm'),
                label: l10n.webSourcesDone(count),
                icon: AppIconography.check,
                onPressed: _confirm,
              ),
            ),
      body: blocked
          ? KitStateView(
              key: const ValueKey('web-sources-blocked'),
              icon: AppIconography.info,
              title: l10n.webSourcesScopeChangedTitle,
              body: l10n.webSourcesScopeChanged,
            )
          : ListView(
              padding: EdgeInsetsDirectional.only(
                top: tokens.space2,
                bottom: KitScreen.endPadding(context),
              ),
              children: [
                Padding(
                  padding: EdgeInsetsDirectional.symmetric(
                    horizontal: tokens.gutter,
                    vertical: tokens.space2,
                  ),
                  child: KitText(
                    _overview.supportsSearch
                        ? l10n.webSearchDisclosure
                        : l10n.webSourcesDisclosure,
                    role: KitTextRole.secondary,
                    tone: KitTextTone.secondary,
                  ),
                ),
                if (_overview.supportsSearch) ..._searchPanel(context, l10n),
                SizedBox(height: tokens.space3),
                _manualEntry(context, l10n),
                if (pasted.isNotEmpty) ...[
                  SizedBox(height: tokens.sectionGap),
                  _addedList(l10n, pasted),
                ],
              ],
            ),
    );
  }
}
