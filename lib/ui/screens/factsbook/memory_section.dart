import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/factsbook/factsbook_types.dart';
import '../../../domain/relative_age.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/factsbook/factsbook_controller.dart';
import '../../../state/factsbook/factsbook_phone_node.dart';
import '../../app_iconography.dart';
import '../../kit/kit.dart';
import 'factsbook_routes.dart';
import 'factsbook_text.dart';

/// The Inbox's Memory section (decision G1/D32): FactsBook's needs-you items
/// as rows, the newest two or three things, and the two ways in (Open About
/// you, Add something). Shown only while the developer flag is on. Before
/// pairing it is one row, "Set up FactsBook".
///
/// The count in the heading is the same number the needs-you rows add up to,
/// counted once.
class FactsBookMemorySection extends ConsumerStatefulWidget {
  const FactsBookMemorySection({
    super.key,
    this.readRetryDelay = const Duration(seconds: 5),
    this.readRetryAttempts = 12,
  });

  /// While the memory on this phone is still starting, a read that cannot
  /// reach it is tried again this often, this many times (about a minute),
  /// before the section says it did not answer.
  final Duration readRetryDelay;
  final int readRetryAttempts;

  @override
  ConsumerState<FactsBookMemorySection> createState() =>
      _FactsBookMemorySectionState();
}

class _FactsBookMemorySectionState
    extends ConsumerState<FactsBookMemorySection> {
  /// The node on this phone was looked at once this time the section showed.
  bool _nodeChecked = false;

  Timer? _retryTimer;
  var _readRetries = 0;

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  /// The last read could not reach the memory on this phone, which is paired
  /// here and not stopped by the person: it is most likely still coming up
  /// (always just after an update), and the section waits instead of
  /// showing an error. A real answer, such as unauthorized or locked, is
  /// not waited for.
  bool _comingUp(FactsBookController controller, FactsBookPhoneNode node) {
    if (!node.host.supported ||
        !node.pairedHere ||
        node.personStopped ||
        node.state == PhoneNodeState.stopped) {
      return false;
    }
    if (controller.error?.unreachable != true) return false;
    return _readRetries < widget.readRetryAttempts;
  }

  void _scheduleRetry(FactsBookController controller, FactsBookPhoneNode node) {
    if (_retryTimer != null || !_comingUp(controller, node)) return;
    if (controller.load == FactsBookLoad.loading) return;
    _retryTimer = Timer(widget.readRetryDelay, () {
      _retryTimer = null;
      if (!mounted) return;
      _readRetries++;
      unawaited(controller.refresh());
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = ref.read(factsBookControllerProvider);
      if (controller.load == FactsBookLoad.idle && controller.paired) {
        unawaited(controller.refresh());
      }
    });
  }

  /// When the app opens with a memory on this phone that is set up, paired and
  /// stopped, it starts it unless the person stopped it. Then the section
  /// reads again.
  void _checkNode(FactsBookController controller) {
    if (_nodeChecked || !controller.session.loaded || !controller.paired) {
      return;
    }
    _nodeChecked = true;
    final node = ref.read(factsBookPhoneNodeProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await node.ensureRunning();
      if (mounted && node.state == PhoneNodeState.running) {
        unawaited(controller.refresh());
      }
    });
  }

  PhoneNodeState? _seenNodeState;

  /// The memory on this phone stopped (the person pressed Stop, or it
  /// ended) while this section shows what it last read: read again, so the
  /// row says it is stopped instead of showing old numbers.
  void _watchStop(FactsBookController controller, FactsBookPhoneNode node) {
    final now = node.state;
    final before = _seenNodeState;
    _seenNodeState = now;
    if (before != null &&
        before != PhoneNodeState.stopped &&
        now == PhoneNodeState.stopped &&
        node.pairedHere) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(controller.refresh());
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(factsBookControllerProvider);
    final node = ref.watch(factsBookPhoneNodeProvider);
    return ListenableBuilder(
      listenable: Listenable.merge([controller, controller.session, node]),
      builder: (context, _) {
        // Here, not above: the session usually finishes loading after the
        // first frame, and only this builder runs again when it does.
        _checkNode(controller);
        _watchStop(controller, node);
        if (controller.error == null) _readRetries = 0;
        _scheduleRetry(controller, node);
        return _content(context, controller, node);
      },
    );
  }

  /// The memory on this phone is paired with this app and not running: the
  /// section says so in words and offers Start, instead of "did not answer".
  Widget? _stoppedRow(
    BuildContext context,
    FactsBookController controller,
    FactsBookPhoneNode node,
  ) {
    if (!node.host.supported || !node.pairedHere) return null;
    final l10n = AppLocalizations.of(context);
    final starting =
        node.busy ||
        _comingUp(controller, node) ||
        node.state == PhoneNodeState.installing ||
        node.state == PhoneNodeState.starting;
    if (!starting && node.state != PhoneNodeState.stopped) return null;
    return KitRowGroup(
      key: const ValueKey('factsbook-memory'),
      label: l10n.fbMemoryTitle,
      children: [
        KitRow(
          key: const ValueKey('factsbook-memory-stopped'),
          leading: KitRow.icon(context, AppIconography.pause),
          title: starting ? l10n.fbMemoryStarting : l10n.fbMemoryStopped,
          supporting: TextSpan(
            text: starting
                ? l10n.fbNodeStepStarting
                : l10n.fbMemoryStoppedDetail,
          ),
          supportingMaxLines: 2,
          action: starting
              ? null
              : KitAction(
                  key: const ValueKey('factsbook-memory-start'),
                  label: l10n.fbMemoryStart,
                  semanticsLabel: l10n.fbNodeStart,
                  onPressed: () => unawaited(() async {
                    await node.start();
                    if (mounted && node.state == PhoneNodeState.running) {
                      await controller.refresh();
                    }
                  }()),
                ),
        ),
      ],
    );
  }

  Widget _content(
    BuildContext context,
    FactsBookController controller,
    FactsBookPhoneNode node,
  ) {
    final l10n = AppLocalizations.of(context);
    final tokens = KitTokens.of(context);
    // Not read yet: nothing to say. Not paired: one row to set it up.
    if (!controller.session.loaded) return const SizedBox.shrink();
    if (!controller.paired) {
      return KitRowGroup(
        key: const ValueKey('factsbook-memory'),
        label: l10n.fbMemoryTitle,
        children: [
          KitRow(
            key: const ValueKey('factsbook-memory-setup'),
            leading: KitRow.badge(context, AppIconography.database),
            title: l10n.fbConnectRow,
            supporting: TextSpan(text: l10n.fbConnectRowDetail),
            trailing: const KitChevron(),
            onTap: () => unawaited(
              node.host.supported
                  ? openFactsBookPhoneNode(context)
                  : openFactsBookConnect(context),
            ),
          ),
        ],
      );
    }
    // Stopped or starting on this phone: said in words, with Start.
    final unanswered =
        controller.load == FactsBookLoad.failed || controller.error != null;
    if (unanswered || node.busy) {
      final stopped = _stoppedRow(context, controller, node);
      if (stopped != null) return stopped;
    }
    final count = controller.needsYouCount;
    final heading = KitText(
      count > 0
          ? l10n.fbMemoryFromFactsBook(count)
          : l10n.fbMemoryFromFactsBookNone,
      role: KitTextRole.caption,
      tone: KitTextTone.secondary,
    );

    final Widget needs;
    if (controller.load == FactsBookLoad.loading) {
      needs = const KitSkeletonRows(count: 2);
    } else {
      final failed = controller.load == FactsBookLoad.failed;
      needs = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (failed)
            Padding(
              padding: EdgeInsetsDirectional.symmetric(
                horizontal: tokens.gutter,
              ),
              child: KitNotice.error(
                key: const ValueKey('factsbook-memory-error'),
                title: l10n.fbErrorTitle,
                message: failureWords(l10n, controller.error),
                retry: KitAction(
                  label: l10n.commonRetry,
                  // The memory on this phone may simply not be running:
                  // start it first, then read again.
                  onPressed: () => unawaited(() async {
                    if (node.host.supported && node.pairedHere) {
                      await node.ensureRunning();
                    }
                    await controller.refresh();
                  }()),
                ),
              ),
            ),
          // Notes held on this phone show even when the node is away.
          if (!failed || controller.needsYou.isNotEmpty)
            KitRowGroup(
              key: const ValueKey('factsbook-memory-needs'),
              label: l10n.fbMemoryTitle,
              labelTrailing: heading,
              children: [
                for (final item in controller.needsYou)
                  _needsRow(context, item),
              ],
            ),
        ],
      );
    }

    return Column(
      key: const ValueKey('factsbook-memory'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (controller.load == FactsBookLoad.loading ||
            (controller.load == FactsBookLoad.failed &&
                controller.needsYou.isEmpty))
          Padding(
            padding: EdgeInsetsDirectional.only(
              start: tokens.gutter,
              end: tokens.gutter,
              top: tokens.sectionGap,
              bottom: tokens.labelGap,
            ),
            child: KitText(
              l10n.fbMemoryTitle,
              role: KitTextRole.label,
              tone: KitTextTone.secondary,
            ),
          ),
        // Nothing waiting: the header's "All clear" says it; a second line
        // saying the same only pushed the ways in down.
        needs,
        if (controller.recent.isNotEmpty)
          KitRowGroup(
            key: const ValueKey('factsbook-memory-recent'),
            label: l10n.fbMemoryRecent,
            children: [
              for (final thing in controller.recent) _recentRow(context, thing),
            ],
          ),
        KitRowGroup(
          key: const ValueKey('factsbook-memory-ways-in'),
          children: [
            KitRow(
              key: const ValueKey('factsbook-open-about-you'),
              leading: KitRow.badge(context, AppIconography.database),
              title: l10n.fbMemoryOpenAboutYou,
              supporting: TextSpan(text: l10n.fbMemoryOpenAboutYouDetail),
              trailing: const KitChevron(),
              onTap: () => unawaited(openFactsBookAboutYou(context)),
            ),
            KitRow(
              key: const ValueKey('factsbook-add-something'),
              leading: KitRow.badge(context, AppIconography.add, accent: true),
              title: l10n.fbMemoryAddSomething,
              titleAccent: true,
              supporting: TextSpan(text: l10n.fbMemoryAddSomethingDetail),
              trailing: const KitChevron(),
              onTap: () => unawaited(openFactsBookCapture(context)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _needsRow(BuildContext context, NeedsYouItem item) {
    final l10n = AppLocalizations.of(context);
    final since = item.since;
    final age = since == null
        ? null
        : relativeAgeLabel(
            clock.now().difference(since),
            at: since,
            l10n: l10n,
          );
    final (
      String title,
      String detail,
      VoidCallback open,
    ) = switch (item.kind) {
      NeedsYouKind.review => (
        l10n.fbMemoryReview(item.count),
        l10n.fbMemoryReviewDetail,
        () => unawaited(openFactsBookNeedsYou(context)),
      ),
      NeedsYouKind.notSaved => (
        l10n.fbMemoryNotSaved(item.count),
        l10n.fbMemoryNotSavedDetail,
        () => unawaited(openFactsBookNotSaved(context)),
      ),
      NeedsYouKind.offer => (
        l10n.fbNeedsYouOffers(item.count),
        l10n.fbOfferTitle,
        () => unawaited(openFactsBookNeedsYou(context)),
      ),
    };
    return KitRow(
      key: ValueKey('factsbook-needs-${item.kind.name}'),
      leading: KitNeedsYou.mark(),
      title: title,
      titleMaxLines: 2,
      supporting: TextSpan(
        children: [
          KitNeedsYou.span(context),
          TextSpan(text: age == null ? detail : '$detail · $age'),
        ],
      ),
      supportingMaxLines: 2,
      trailing: const KitChevron(),
      onTap: open,
    );
  }

  Widget _recentRow(BuildContext context, Thing thing) {
    final l10n = AppLocalizations.of(context);
    final fact = thing.newestFact!;
    final line = KitFactRow.lineOf(
      context,
      provenance: kitProvenanceOf(fact.provenance),
      observedAt: fact.observedAt,
      source: sourceWords(l10n, fact.source),
    );
    return KitRow(
      key: ValueKey('factsbook-recent-${thing.id}'),
      leading: KitRow.icon(context, kindIcon(thing.kind)),
      title: bidiName(context, thing.title),
      titleMaxLines: 2,
      supporting: TextSpan(text: line),
      supportingMaxLines: 2,
      trailing: const KitChevron(),
      onTap: () => unawaited(openFactsBookThing(context, thing.id)),
    );
  }
}
