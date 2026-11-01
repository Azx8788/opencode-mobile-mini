import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import '../kit/kit.dart';
import '../widgets/local_agent_onboarding.dart';
import 'agents/agents_section.dart';
import 'chats/chats_host.dart';
import 'phone_setup/phone_setup_termux_screen.dart' show openPhoneSetupTermux;

/// Claude Code on this phone, on its own page
/// (docs/design/phone-server-screens-cleanup-2026-09-24.md §2): the phone
/// server's details show it as one optional row, and everything about it
/// (the offer, installing, signing in, the project folder, start and stop)
/// lives here.
///
/// Built from kit parts only (screen-phone-1): a [KitScreen] page with its
/// [KitTopBar], the onboarding block on the screen's gutters. The page's
/// new structure (install into the in-app Ubuntu, resume, per-project
/// agent choice) waits for its slice.
// revamp: redesign (slice-P1.6b)
class LocalAgentScreen extends ConsumerWidget {
  const LocalAgentScreen({super.key, required this.onConnected});

  /// Called once the app is connected through Claude Code.
  final VoidCallback onConnected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final tokens = KitTokens.of(context);
    // Where the agents run in the app's own Ubuntu (the connected server is
    // the built-in one), what is installed there is read from that host, the
    // same rows Settings > Agents shows. The Termux set-up below is only for
    // a phone that has no built-in host, so it never offers a first-time
    // install (or talks about Termux) for an agent that is already here.
    final host = ref.watch(chatsHostProvider);
    if (host.agents?.phoneAgentsAvailable ?? false) {
      return KitScreen(
        topBar: KitTopBar(title: l10n.agentsSectionTitle),
        width: KitScreenWidth.reading,
        body: ListView(
          key: const ValueKey('local-agent-managed'),
          padding: EdgeInsetsDirectional.only(
            top: tokens.space2,
            bottom: KitScreen.endPadding(context),
          ),
          children: const [AgentsSection()],
        ),
      );
    }
    return KitScreen(
      topBar: KitTopBar(title: l10n.localAgentPageTitle),
      width: KitScreenWidth.reading,
      // One box in a sliver, not a lazy list of children: the block is
      // empty while it checks the phone, and a lazy list could drop an
      // empty child (and with it the check) before it had anything to show.
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: EdgeInsetsDirectional.fromSTEB(
              tokens.gutter,
              tokens.space4,
              tokens.gutter,
              KitScreen.endPadding(context),
            ),
            sliver: SliverToBoxAdapter(
              child: LocalAgentOnboardingBlock(
                key: const ValueKey('local-agent-block'),
                connection: ref.read(connProvider),
                onConnected: onConnected,
                // Claude Code only runs through the Termux-hosted Ubuntu
                // today (P1.6 adds the in-app Claude Code component): this
                // is the only door that actually unblocks it, whether
                // nothing is set up yet or the in-app Linux already is.
                onOpenPhoneSetup: () =>
                    unawaited(openPhoneSetupTermux(context)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
