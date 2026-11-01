import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:opencode_mobile/ui/kit/kit_row.dart';
import 'package:opencode_mobile/ui/kit/kit_row_parts.dart';
import 'package:opencode_mobile/ui/kit/kit_text.dart';
import 'package:opencode_mobile/ui/kit/kit_tokens.dart';

import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import '../app_iconography.dart';

AppLocalizations _chatL10n(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

/// The two transcript display switches, "Reasoning" and "Timestamps &
/// usage", as [KitSwitchRow]s on one panel. The supporting line says what
/// "on" does and stays the same whichever way the switch sits (the switch
/// already says on or off), and a line under the panel says they apply to
/// every conversation, not only the open one.
///
/// Each flip writes the preference straight to the connection and updates
/// in place, so the sheet that hosts them stays open and a reader can set
/// both without reopening it.
class TranscriptDisplayToggles extends StatefulWidget {
  const TranscriptDisplayToggles({
    super.key,
    required this.reasoningExpanded,
    required this.timestampsVisible,
    this.dense = false,
    this.connection,
  });

  /// The connection to write to when the host already holds one (the Settings
  /// hub); otherwise it is read from the provider scope.
  final ConnectionController? connection;

  final bool reasoningExpanded;
  final bool timestampsVisible;

  /// Retired by shared-chat-1: the kit rows have one density. Kept so
  /// existing callers compile; it no longer changes anything.
  final bool dense;

  @override
  State<TranscriptDisplayToggles> createState() =>
      _TranscriptDisplayTogglesState();
}

class _TranscriptDisplayTogglesState extends State<TranscriptDisplayToggles> {
  late bool _reasoning = widget.reasoningExpanded;
  late bool _timestamps = widget.timestampsVisible;

  /// The connection the transcript preferences live on; null only in hosts
  /// without a provider scope (isolated widget tests), where the switch still
  /// flips locally.
  ConnectionController? _connection() {
    if (widget.connection != null) return widget.connection;
    try {
      return ProviderScope.containerOf(
        context,
        listen: false,
      ).read(connProvider);
    } catch (_) {
      return null;
    }
  }

  Future<void> _setReasoning(bool value) async {
    setState(() => _reasoning = value);
    await _connection()?.setTranscriptReasoningExpanded(value);
  }

  Future<void> _setTimestamps(bool value) async {
    setState(() => _timestamps = value);
    await _connection()?.setTranscriptTimestampsVisible(value);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _chatL10n(context);
    final tokens = KitTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KitRowGroup(
          margin: EdgeInsets.zero,
          children: [
            KitSwitchRow(
              key: const ValueKey('session-view-thinking'),
              leading: KitRow.icon(context, AppIconography.model),
              title: l10n.transcriptFindReasoning,
              supporting: l10n.transcriptTogglesReasoningOn,
              value: _reasoning,
              onChanged: (value) => unawaited(_setReasoning(value)),
            ),
            KitSwitchRow(
              key: const ValueKey('session-view-timestamps'),
              leading: KitRow.icon(context, AppIconography.clock),
              title: l10n.chatUiTimestampsUsage,
              supporting: l10n.transcriptTogglesUsageOn,
              value: _timestamps,
              onChanged: (value) => unawaited(_setTimestamps(value)),
            ),
          ],
        ),
        Padding(
          padding: EdgeInsetsDirectional.only(
            start: tokens.space1,
            end: tokens.space1,
            top: tokens.labelGap,
          ),
          child: KitText(
            l10n.transcriptTogglesScope,
            key: const ValueKey('transcript-toggles-scope'),
            role: KitTextRole.secondary,
            tone: KitTextTone.secondary,
          ),
        ),
      ],
    );
  }
}
