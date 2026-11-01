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

/// Areas and sharing (spec 60 screen 17, D26): each built-in area with
/// whether other apps and agents may read it. Health and Money (locked
/// folder areas) start with sharing off and ask before it is turned on.
/// Changing sharing is signed by this phone's owner key. The node has no
/// call to make a new area, so none is offered.
class FactsBookAreasScreen extends ConsumerStatefulWidget {
  const FactsBookAreasScreen({super.key});

  @override
  ConsumerState<FactsBookAreasScreen> createState() =>
      _FactsBookAreasScreenState();
}

class _FactsBookAreasScreenState extends ConsumerState<FactsBookAreasScreen> {
  List<Area>? _areas;
  Object? _failure;
  bool _loading = true;
  final _working = <String>{};
  String? _notice;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  FactsBookController get _controller => ref.read(factsBookControllerProvider);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final areas = await _controller.areas();
      if (mounted) setState(() => _areas = areas);
    } on FactsBookException catch (failure) {
      if (mounted) setState(() => _failure = failure);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggle(Area area, bool on) async {
    final l10n = AppLocalizations.of(context);
    if (on && area.sensitiveStorage) {
      final yes = await showKitConfirm(
        context,
        title: l10n.fbAreasShareConfirmTitle(areaName(l10n, area.slug)),
        body: l10n.fbAreasShareConfirmBody,
        confirmLabel: l10n.fbAreasShareConfirm,
        kind: KitConfirmKind.destructive,
        confirmKey: ValueKey('factsbook-area-confirm-${area.slug}'),
      );
      if (!yes || !mounted) return;
    }
    setState(() => _working.add(area.slug));
    try {
      await _controller.setAreaShare(
        area,
        AreaShare(
          readByDefault: on,
          allow: area.share.allow,
          deny: area.share.deny,
        ),
      );
      await _load();
      if (mounted) setState(() => _notice = null);
    } on FactsBookException catch (failure) {
      if (mounted) setState(() => _notice = failureWords(l10n, failure));
    } finally {
      if (mounted) setState(() => _working.remove(area.slug));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    final controller = ref.watch(factsBookControllerProvider);
    controller.session.approvalReason = l10n.fbAuthReason;
    final areas = _areas;
    final Widget body;
    if (areas == null && _failure == null) {
      body = ListView(
        padding: KitScreen.padding(context),
        children: const [KitSkeletonRows()],
      );
    } else if (areas == null) {
      body = KitStateView.error(
        key: const ValueKey('factsbook-areas-error'),
        title: l10n.fbErrorTitle,
        body: failureWords(l10n, _failure),
        details: failureDetails(l10n, _failure),
        retry: KitAction(
          label: l10n.commonRetry,
          onPressed: () => unawaited(_load()),
        ),
      );
    } else {
      final rails = EdgeInsetsDirectional.symmetric(horizontal: tokens.gutter);
      final reason = controller.session.canApprove
          ? null
          : l10n.fbCareNeedsOwnerShort;
      body = KitRefresh(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsetsDirectional.only(
            top: tokens.space2,
            bottom: KitScreen.endPadding(context),
          ),
          children: [
            Padding(
              padding: rails,
              child: KitText(
                l10n.fbAreasIntro,
                role: KitTextRole.secondary,
                tone: KitTextTone.secondary,
              ),
            ),
            if (reason != null)
              Padding(
                padding: rails.add(
                  EdgeInsetsDirectional.only(top: tokens.space3),
                ),
                child: KitNotice(
                  key: const ValueKey('factsbook-areas-needs-owner'),
                  icon: AppIconography.info,
                  message: l10n.fbCareNeedsOwner,
                  actions: [
                    KitAction(
                      label: l10n.fbCareSetupApproval,
                      onPressed: () => unawaited(openFactsBookConnect(context)),
                    ),
                  ],
                ),
              ),
            if (_notice != null)
              Padding(
                padding: rails.add(
                  EdgeInsetsDirectional.only(top: tokens.space3),
                ),
                child: KitNotice(
                  key: const ValueKey('factsbook-areas-notice'),
                  message: _notice!,
                  onDismiss: () => setState(() => _notice = null),
                  dismissLabel: l10n.fbDismiss,
                ),
              ),
            for (final area in areas)
              KitRowGroup(
                key: ValueKey('factsbook-area-${area.slug}'),
                label: areaName(l10n, area.slug),
                children: [
                  KitSwitchRow(
                    switchKey: ValueKey('factsbook-area-share-${area.slug}'),
                    title: l10n.fbAreasOthersRead,
                    supporting: l10n.fbAreasOthersReadDetail,
                    value: area.share.readByDefault,
                    onChanged: reason != null || _working.contains(area.slug)
                        ? null
                        : (on) => unawaited(_toggle(area, on)),
                    disabledReason: reason,
                  ),
                  KitRow(
                    leading: KitRow.icon(
                      context,
                      area.sensitiveStorage
                          ? AppIconography.locked
                          : AppIconography.folders,
                    ),
                    title: area.sensitiveStorage
                        ? l10n.fbAreasLockedFolder
                        : l10n.fbAreasNormalStorage,
                    supporting: TextSpan(
                      text: area.reviewFirst
                          ? l10n.fbAreasReviewFirst
                          : l10n.fbAreasReviewAuto,
                    ),
                    supportingMaxLines: 2,
                  ),
                ],
              ),
            KitGroupNote(message: l10n.fbAreasFixed),
          ],
        ),
      );
    }
    return KitScreen(
      topBar: KitTopBar(title: l10n.fbAreasTitle),
      width: KitScreenWidth.reading,
      loading: _loading && areas != null,
      loadingLabel: l10n.fbAreasTitle,
      body: body,
    );
  }
}
