import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/factsbook/factsbook_capabilities.dart';
import '../../../domain/factsbook/factsbook_types.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/factsbook/factsbook_controller.dart';
import '../../app_iconography.dart';
import '../../kit/kit.dart';
import 'factsbook_routes.dart';
import 'factsbook_text.dart';

/// About you, the full place (spec 60 screen 8): a search field, the places
/// FactsBook offers as visible rows (Needs you, Reminders, When something new
/// comes in, Areas), then every thing by kind, and Add something. Status and
/// Settings sit in a small footer group. No view is shown until it exists.
class FactsBookAboutYouScreen extends ConsumerStatefulWidget {
  const FactsBookAboutYouScreen({super.key});

  @override
  ConsumerState<FactsBookAboutYouScreen> createState() =>
      _FactsBookAboutYouScreenState();
}

class _FactsBookAboutYouScreenState
    extends ConsumerState<FactsBookAboutYouScreen> {
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(factsBookControllerProvider).refresh());
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Only when the node cannot be reached: the page shows what it last
  /// had. "Last saved 14 min ago" said nothing the person could act on.
  String? _status(AppLocalizations l10n, FactsBookController controller) {
    final status = controller.status;
    if (status == null) return null;
    final stale =
        (status.staleSeconds ?? 0) > 0 || controller.error?.unreachable == true;
    return stale ? l10n.fbStatusStale : null;
  }

  Widget _places(
    BuildContext context,
    AppLocalizations l10n,
    FactsBookController controller,
  ) {
    final caps = controller.session.capabilities;
    final waiting = controller.needsYouCount;
    return KitRowGroup(
      key: const ValueKey('factsbook-about-places'),
      children: [
        KitRow(
          key: const ValueKey('factsbook-about-needs-you'),
          // The title already says "Needs you": no needs-you mark or span
          // here, or a screen reader says it three times.
          leading: KitRow.icon(context, AppIconography.review),
          title: l10n.fbNeedsYouTitle,
          supporting: TextSpan(
            text: waiting > 0
                ? l10n.fbNeedsYouWaiting(waiting)
                : l10n.fbNeedsYouNone,
          ),
          trailing: const KitChevron(),
          onTap: () => unawaited(openFactsBookNeedsYou(context)),
        ),
        if (caps.supports(FactsBookCapabilities.reminders))
          KitRow(
            key: const ValueKey('factsbook-about-reminders'),
            leading: KitRow.icon(context, AppIconography.clock),
            title: l10n.fbRemindersTitle,
            trailing: const KitChevron(),
            onTap: () => unawaited(openFactsBookReminders(context)),
          ),
        if (caps.supports(FactsBookCapabilities.triggers))
          KitRow(
            key: const ValueKey('factsbook-about-triggers'),
            leading: KitRow.icon(context, AppIconography.sparkle),
            title: l10n.fbTriggersTitle,
            trailing: const KitChevron(),
            onTap: () => unawaited(openFactsBookTriggers(context)),
          ),
        KitRow(
          key: const ValueKey('factsbook-about-areas'),
          leading: KitRow.icon(context, AppIconography.privacy),
          title: l10n.fbAreasTitle,
          trailing: const KitChevron(),
          onTap: () => unawaited(openFactsBookAreas(context)),
        ),
      ],
    );
  }

  Widget _footer(BuildContext context, AppLocalizations l10n) => KitRowGroup(
    key: const ValueKey('factsbook-about-footer'),
    gapBefore: KitTokens.of(context).space4,
    leadingIcons: false,
    children: [
      KitRow(
        key: const ValueKey('factsbook-about-status'),
        title: l10n.fbStatusTitle,
        trailing: const KitChevron(),
        onTap: () => unawaited(openFactsBookStatus(context)),
      ),
      KitRow(
        key: const ValueKey('factsbook-about-settings'),
        title: l10n.fbSettingsTitle,
        trailing: const KitChevron(),
        onTap: () => unawaited(openFactsBookSettings(context)),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(factsBookControllerProvider);
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return KitScreen(
          topBar: KitTopBar(
            title: l10n.fbAboutYouTitle,
            subtitle: _status(l10n, controller),
          ),
          width: KitScreenWidth.reading,
          loading: controller.load == FactsBookLoad.loading,
          loadingLabel: l10n.fbAboutYouTitle,
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
                controller: _search,
                fieldKey: const ValueKey('factsbook-search-field'),
                onChanged: (_) {},
                onSubmitted: (query) {
                  if (query.trim().isNotEmpty) {
                    unawaited(openFactsBookSearch(context, query.trim()));
                  }
                },
              ),
            ),
          ],
          body: _ListTab(
            places: _places(context, l10n, controller),
            footer: _footer(context, l10n),
          ),
          bottom: KitActionBlock(
            primary: KitAction(
              key: const ValueKey('factsbook-about-add'),
              label: l10n.fbMemoryAddSomething,
              icon: AppIconography.add,
              onPressed: () => unawaited(openFactsBookCapture(context)),
            ),
          ),
        );
      },
    );
  }
}

/// List: browse every thing by kind, each row with its source and date.
class _ListTab extends ConsumerStatefulWidget {
  const _ListTab({required this.places, required this.footer});

  /// The rows to the other places, above the list.
  final Widget places;

  /// Status and Settings, under the list.
  final Widget footer;

  @override
  ConsumerState<_ListTab> createState() => _ListTabState();
}

class _ListTabState extends ConsumerState<_ListTab> {
  ThingKind? _kind;
  List<Thing>? _things;
  Object? _failure;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _failure = null);
    try {
      final things = await ref
          .read(factsBookControllerProvider)
          .things(kind: _kind);
      if (mounted) setState(() => _things = things);
    } on FactsBookException catch (failure) {
      if (mounted) setState(() => _failure = failure);
    }
  }

  void _pick(ThingKind? kind) {
    if (_kind == kind) return;
    setState(() {
      _kind = kind;
      _things = null;
    });
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final things = _things;
    final Widget content;
    if (_failure != null) {
      content = KitStateView.error(
        key: const ValueKey('factsbook-list-error'),
        title: l10n.fbErrorTitle,
        body: failureWords(l10n, _failure),
        details: failureDetails(l10n, _failure),
        size: KitStateSize.inline,
        retry: KitAction(
          label: l10n.commonRetry,
          onPressed: () => unawaited(_load()),
        ),
      );
    } else if (things == null) {
      content = const KitSkeletonRows();
    } else if (things.isEmpty) {
      content = KitStateView(
        key: const ValueKey('factsbook-list-empty'),
        icon: AppIconography.database,
        title: l10n.fbEmptyTitle,
        body: l10n.fbEmptyBody,
        size: KitStateSize.inline,
      );
    } else {
      content = KitRowGroup(
        key: const ValueKey('factsbook-list'),
        leadingIcons: true,
        children: [for (final thing in things) _row(context, l10n, thing)],
      );
    }
    return KitRefresh(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsetsDirectional.only(
          top: tokens.space1,
          bottom: KitScreen.endPadding(context),
        ),
        children: [
          widget.places,
          KitFilterChips(
            chips: [
              KitFilterChip(
                key: const ValueKey('factsbook-filter-all'),
                label: l10n.fbListAll,
                selected: _kind == null,
                onPressed: () => _pick(null),
              ),
              KitFilterChip(
                key: const ValueKey('factsbook-filter-cards'),
                label: l10n.fbListCards,
                selected: _kind == ThingKind.card,
                onPressed: () => _pick(ThingKind.card),
              ),
              KitFilterChip(
                key: const ValueKey('factsbook-filter-people'),
                label: l10n.fbListPeople,
                selected: _kind == ThingKind.person,
                onPressed: () => _pick(ThingKind.person),
              ),
              KitFilterChip(
                key: const ValueKey('factsbook-filter-documents'),
                label: l10n.fbListDocuments,
                selected: _kind == ThingKind.document,
                onPressed: () => _pick(ThingKind.document),
              ),
            ],
          ),
          KitGroupNote(
            message:
                ref
                    .read(factsBookControllerProvider)
                    .session
                    .capabilities
                    .isDisabled(FactsBookCapabilities.sensitiveUnlock)
                ? l10n.fbListLockedNoteNotYet
                : l10n.fbListLockedNote,
          ),
          content,
          widget.footer,
        ],
      ),
    );
  }

  Widget _row(BuildContext context, AppLocalizations l10n, Thing thing) {
    final kind = kindWords(l10n, thing.kind);
    final fact = thing.newestFact;
    final head = fact == null ? kind : l10n.fbKindLine(kind, fact.text);
    final line = fact == null
        ? null
        : KitFactRow.lineOf(
            context,
            provenance: kitProvenanceOf(fact.provenance),
            observedAt: fact.observedAt,
            source: sourceWords(l10n, fact.source),
            waitingForOk: fact.waitingForOk,
          );
    return KitRow(
      key: ValueKey('factsbook-thing-${thing.id}'),
      leading: KitRow.icon(context, kindIcon(thing.kind)),
      title: bidiName(context, thing.title),
      supporting: TextSpan(text: line == null ? head : '$head\n$line'),
      supportingMaxLines: 4,
      trailing: const KitChevron(),
      onTap: () => unawaited(openFactsBookThing(context, thing.id)),
    );
  }
}
