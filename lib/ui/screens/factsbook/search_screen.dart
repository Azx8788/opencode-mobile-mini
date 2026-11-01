import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/factsbook/factsbook_types.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/factsbook/factsbook_controller.dart';
import '../../app_iconography.dart';
import '../../kit/kit.dart';
import 'factsbook_routes.dart';
import 'factsbook_text.dart';

/// Search results (spec 60 screen 11, G31): every hit shows where it came
/// from and when. The page says it matches words, not meaning, and that
/// locked notes are not searched until they are unlocked.
class FactsBookSearchScreen extends ConsumerStatefulWidget {
  const FactsBookSearchScreen({super.key, required this.query});

  final String query;

  @override
  ConsumerState<FactsBookSearchScreen> createState() =>
      _FactsBookSearchScreenState();
}

class _FactsBookSearchScreenState extends ConsumerState<FactsBookSearchScreen> {
  late final _field = TextEditingController(text: widget.query);
  SearchResult? _result;
  Object? _failure;
  bool _loading = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_run(widget.query));
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _run(String query) async {
    final generation = ++_generation;
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final result = await ref
          .read(factsBookControllerProvider)
          .search(trimmed);
      if (mounted && generation == _generation) {
        setState(() => _result = result);
      }
    } on FactsBookException catch (failure) {
      if (mounted && generation == _generation) {
        setState(() => _failure = failure);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final result = _result;
    final Widget body;
    if (_failure != null) {
      body = KitStateView.error(
        key: const ValueKey('factsbook-search-error'),
        title: l10n.fbErrorTitle,
        body: failureWords(l10n, _failure),
        details: failureDetails(l10n, _failure),
        retry: KitAction(
          label: l10n.commonRetry,
          onPressed: () => unawaited(_run(_field.text)),
        ),
      );
    } else if (result == null) {
      body = ListView(
        padding: KitScreen.padding(context),
        children: const [KitSkeletonRows()],
      );
    } else {
      final rails = EdgeInsetsDirectional.symmetric(horizontal: tokens.gutter);
      body = ListView(
        padding: EdgeInsetsDirectional.only(
          top: tokens.space2,
          bottom: KitScreen.endPadding(context),
        ),
        children: [
          Padding(
            padding: rails,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: tokens.space1,
              children: [
                KitText(
                  l10n.fbSearchMatches(
                    result.hits.length,
                    bidiName(context, result.query),
                  ),
                  key: const ValueKey('factsbook-search-count'),
                  role: KitTextRole.label,
                ),
                KitText(
                  l10n.fbSearchWordsOnly,
                  role: KitTextRole.secondary,
                  tone: KitTextTone.secondary,
                ),
              ],
            ),
          ),
          if (result.hits.isEmpty)
            KitStateView(
              key: const ValueKey('factsbook-search-none'),
              icon: AppIconography.search,
              title: l10n.fbSearchNoneTitle,
              body: l10n.fbSearchNoneBody,
              size: KitStateSize.inline,
            ),
          for (final hit in result.hits)
            KitFactRow(
              key: ValueKey(
                'factsbook-hit-${hit.thingId}-${hit.observedAt.microsecondsSinceEpoch}',
              ),
              title: hit.title,
              text: hit.snippet,
              provenance: kitProvenanceOf(hit.provenance),
              source: sourceWords(l10n, hit.source),
              observedAt: hit.observedAt,
              open: () => unawaited(openFactsBookThing(context, hit.thingId)),
            ),
          if (result.lockedNotesSkipped)
            KitGroupNote(message: l10n.fbSearchLocked),
          if (result.hits.isNotEmpty)
            KitGroupNote(message: l10n.fbSearchEachHit),
        ],
      );
    }
    return KitScreen(
      topBar: KitTopBar(title: l10n.fbSearchTitle),
      width: KitScreenWidth.reading,
      loading: _loading,
      loadingLabel: l10n.fbSearchTitle,
      header: [
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            tokens.gutter,
            tokens.space2,
            tokens.gutter,
            tokens.space2,
          ),
          child: KitSearchField(
            label: l10n.fbSearchLabel,
            controller: _field,
            onChanged: (_) {},
            onSubmitted: (query) => unawaited(_run(query)),
          ),
        ),
      ],
      body: body,
    );
  }
}
