import 'package:flutter/material.dart';

import '../../../domain/usage_subscriptions.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/connection.dart';
import '../../../state/usage_subscriptions_controller.dart';
import '../../app_iconography.dart';
import '../../kit/kit.dart';
import 'usage_actions.dart';
import 'usage_text.dart';

/// "Add {provider}": where should it be signed in? The app reads usage from
/// whichever the person picks. Each choice is that connection's own sign-in
/// (a server's Providers page, or this phone's agent sheet). Only reached
/// when there is more than one place; one place skips straight to sign-in
/// ([startUsageAdd]).
class UsageAddScreen extends StatefulWidget {
  const UsageAddScreen({
    super.key,
    required this.controller,
    required this.usage,
    required this.launcher,
    required this.providerId,
  });

  final ConnectionController controller;
  final UsageSubscriptionsController usage;
  final UsageSignInLauncher launcher;
  final String providerId;

  @override
  State<UsageAddScreen> createState() => _UsageAddScreenState();
}

class _UsageAddScreenState extends State<UsageAddScreen> {
  String? _notice;
  String? _working;

  Future<void> _pick(UsageConnection connection) async {
    if (_working != null) return;
    setState(() {
      _working = connection.id;
      _notice = null;
    });
    final outcome = await startUsageSignIn(
      context,
      controller: widget.controller,
      launcher: widget.launcher,
      providerId: widget.providerId,
      connection: connection,
    );
    if (!mounted) return;
    setState(() {
      _working = null;
      _notice = outcome == UsageSignInOutcome.opened
          ? null
          : usageOutcomeWords(usageStrings(context), outcome);
    });
  }

  IconData _icon(UsageConnection c) => switch (c.kind) {
    UsageConnectionKind.phoneAgents => AppIconography.phone,
    UsageConnectionKind.inAppUbuntu => AppIconography.terminal,
    _ => AppIconography.computer,
  };

  String _supporting(AppLocalizations l10n, UsageConnection c, String name) =>
      switch (c.kind) {
        UsageConnectionKind.inAppUbuntu => l10n.usageAddInAppNote,
        UsageConnectionKind.phoneAgents => l10n.usageAddPhoneNote(name),
        _ => l10n.usageAddServerNote,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = usageStrings(context);
    final tokens = KitTokens.of(context);
    final provider = UsageText.provider(l10n, widget.providerId, '');
    return ListenableBuilder(
      listenable: widget.usage,
      builder: (context, _) {
        final choices = usageAddChoices(
          widget.controller,
          widget.usage.snapshot,
          widget.providerId,
        );
        return KitScreen(
          topBar: KitTopBar(title: l10n.usageAddTitle(provider)),
          width: KitScreenWidth.reading,
          body: ListView(
            key: const ValueKey('usage-add'),
            padding: EdgeInsetsDirectional.only(
              top: tokens.space2,
              bottom: KitScreen.endPadding(context),
            ),
            children: [
              if (choices.isEmpty)
                KitStateView(
                  key: const ValueKey('usage-add-none'),
                  icon: AppIconography.login,
                  title: l10n.usageAddNoneTitle(provider),
                  body: l10n.usageAddNoneBody,
                  size: KitStateSize.inline,
                )
              else ...[
                Padding(
                  padding: EdgeInsetsDirectional.symmetric(
                    horizontal: tokens.gutter,
                  ),
                  child: KitText(
                    l10n.usageAddWhere(provider),
                    role: KitTextRole.body,
                  ),
                ),
                SizedBox(height: tokens.space3),
                if (_notice != null)
                  Padding(
                    padding: EdgeInsetsDirectional.only(
                      start: tokens.gutter,
                      end: tokens.gutter,
                      bottom: tokens.space3,
                    ),
                    child: KitNotice(
                      key: const ValueKey('usage-add-notice'),
                      icon: AppIconography.info,
                      message: _notice!,
                    ),
                  ),
                KitRowGroup(
                  children: [
                    for (var i = 0; i < choices.length; i++)
                      KitRow(
                        key: ValueKey('usage-add-choice-${choices[i].id}'),
                        leading: KitRow.icon(context, _icon(choices[i])),
                        title: UsageText.connection(l10n, choices[i]),
                        titleMaxLines: 2,
                        supporting: TextSpan(
                          text: _supporting(l10n, choices[i], provider),
                        ),
                        supportingMaxLines: 3,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (choices[i].kind ==
                                UsageConnectionKind.inAppUbuntu)
                              KitStatusTag(
                                label: l10n.usageBest,
                                tone: KitStatusTagTone.done,
                              ),
                            const KitChevron(),
                          ],
                        ),
                        enabled: _working == null,
                        onTap: () => _pick(choices[i]),
                      ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
