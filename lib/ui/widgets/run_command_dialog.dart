import 'package:flutter/material.dart';

import '../../domain/server_gateway.dart';
import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import '../app_iconography.dart';
import '../kit/kit_buttons.dart';
import '../kit/kit_choice_list.dart';
import '../kit/kit_field.dart';
import '../kit/kit_notice.dart';
import '../kit/kit_row_parts.dart';
import '../kit/kit_sheet.dart';
import '../kit/kit_tokens.dart';
import 'product_states.dart';
import 'older_sessions_pager.dart';
import 'session_title.dart';

/// Opens the review of one slash command (map page run-command-dialog):
/// what it does, its arguments, the conversation it runs in. Nothing runs
/// until the person presses "Run /review" (the command's own name). Returns the conversation the
/// command ran in, or null when the sheet was closed.
///
/// A kit sheet (kit-v2 §1.1) rather than a dialog: it holds a field, a
/// choice and a status, which the two dialog jobs (one text entry, one
/// alert) do not cover. The run is its own primary, which shows it is
/// working while the command starts, and a failed run stays in the sheet
/// as a notice with the typed arguments kept.
Future<String?> showRunCommandDialog(
  BuildContext context, {
  required ConnectionController controller,
  required CommandInfo command,
  Future<bool> Function()? validateCommand,
}) {
  final l10n =
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      lookupAppLocalizations(Localizations.localeOf(context));
  final description = command.description?.trim();
  // Typed arguments are asked about before a swipe or back drops them.
  // Not disposed here: the frame listens until its route is gone, after
  // this future completes; an unlistened notifier holds nothing.
  final dirty = ValueNotifier<bool>(false);
  return showKitSheet<String>(
    context,
    title: l10n.commandRunTitle(command.name),
    subtitle: description == null || description.isEmpty ? null : description,
    icon: AppIconography.terminal,
    dirty: dirty,
    sheetKey: const ValueKey('run-command-sheet'),
    body: (_) => _RunCommandForm(
      controller: controller,
      command: command,
      validateCommand: validateCommand,
      dirty: dirty,
    ),
  );
}

class _RunCommandForm extends StatefulWidget {
  const _RunCommandForm({
    required this.controller,
    required this.command,
    required this.dirty,
    this.validateCommand,
  });

  final ConnectionController controller;
  final CommandInfo command;
  final ValueNotifier<bool> dirty;
  final Future<bool> Function()? validateCommand;

  @override
  State<_RunCommandForm> createState() => _RunCommandFormState();
}

class _RunCommandFormState extends State<_RunCommandForm> {
  final _arguments = TextEditingController();
  late List<Session> _sessions;
  late final int _locationRevision;
  late final String? _profileID;
  late final String? _directory;
  late final String? _workspace;
  late String _destination;
  String? _createdSessionID;
  String? _error;
  bool _sending = false;
  bool _choosing = false;

  @override
  void initState() {
    super.initState();
    final controller = widget.controller;
    _sessions = controller.sortedSessions();
    _locationRevision = controller.locationRevision;
    _profileID = controller.profile?.id;
    _directory = controller.directory;
    _workspace = controller.workspace;
    // The most recent conversation, the one the person most likely means.
    _destination = _sessions.isEmpty ? '' : _sessions.first.id;
    controller.addListener(_sessionsChanged);
    _arguments.addListener(_argumentsChanged);
  }

  void _argumentsChanged() =>
      widget.dirty.value = _arguments.text.trim().isNotEmpty;

  void _sessionsChanged() {
    if (!_sameLocation) return;
    final current = widget.controller.sortedSessions();
    // Keep a selected destination visible while a refreshed page is partial.
    final selected = _sessions.where((session) => session.id == _destination);
    setState(
      () => _sessions = [
        ...current,
        if (!current.any((session) => session.id == _destination)) ...selected,
      ],
    );
  }

  bool get _sameLocation =>
      mounted &&
      widget.controller.locationRevision == _locationRevision &&
      widget.controller.profile?.id == _profileID &&
      widget.controller.directory == _directory &&
      widget.controller.workspace == _workspace;

  AppLocalizations get _l10n =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      lookupAppLocalizations(Localizations.localeOf(context));

  Future<void> _submit() async {
    if (_sending) return;
    final l10n = _l10n;
    final locationError = l10n.commandLocationChanged;
    setState(() {
      _sending = true;
      _choosing = false;
      _error = null;
    });
    try {
      if (!_sameLocation) throw ProductException(locationError);
      final api = await widget.controller.prepareActionTransport();
      if (!_sameLocation) throw ProductException(locationError);
      if (api == null) {
        throw ProductException(l10n.runCommandReconnecting);
      }
      if (widget.validateCommand case final validate?) {
        if (!await validate() || !_sameLocation) {
          throw ProductException(l10n.pluginMappingUnavailable);
        }
      }
      var sessionID = _destination;
      if (sessionID.isEmpty) {
        _createdSessionID ??= (await widget.controller.createSession()).id;
        if (!_sameLocation) throw ProductException(locationError);
        sessionID = _createdSessionID!;
      }
      await widget.controller.waitForSessionSelection(
        sessionID,
        expectedApi: api,
      );
      if (!_sameLocation) throw ProductException(locationError);
      final variant = widget.controller.variantForSession(sessionID);
      if (widget.validateCommand case final validate?) {
        if (!await validate() || !_sameLocation) {
          throw ProductException(l10n.pluginMappingUnavailable);
        }
      }
      await api.slashCommand(
        sessionID,
        widget.command.name,
        _arguments.text.trim(),
        model: widget.controller.modelForSession(sessionID),
        variant: variant.isEmpty ? null : variant,
      );
      if (!_sameLocation) throw ProductException(locationError);
      if (mounted) {
        // The arguments were used: closing is the person's own act.
        widget.dirty.value = false;
        KitSheet.close(context, sessionID);
      }
    } catch (error) {
      if (mounted) setState(() => _error = productErrorText(error, l10n: l10n));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sessionsChanged);
    _arguments.removeListener(_argumentsChanged);
    _arguments.dispose();
    super.dispose();
  }

  String _titleOf(Session session, AppLocalizations l10n) =>
      presentedSessionTitle(
        session,
        fallback: l10n.commandUntitledChat,
        l10n: l10n,
      );

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final tokens = KitTokens.of(context);
    final name = widget.command.name;
    final chosen = _sessions.where((session) => session.id == _destination);
    final destination = _destination.isEmpty || chosen.isEmpty
        ? l10n.commandNewChat
        : _titleOf(chosen.first, l10n);
    final error = _error;
    return PopScope(
      // An in-flight run cannot be abandoned half way: back, Esc, a swipe
      // and the close button wait for it.
      canPop: !_sending,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KitField(
            label: l10n.commandArguments,
            controller: _arguments,
            helper: l10n.runCommandArgumentsHelper(name),
            enabled: !_sending,
            disabledReason: _sending ? l10n.commandRunning : null,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            fieldKey: const ValueKey('command-arguments'),
          ),
          SizedBox(height: tokens.space4),
          KitExpandRow(
            headerKey: const ValueKey('command-destination'),
            leading: const KitRowIcon(AppIconography.chat),
            title: l10n.runCommandRunsIn,
            supporting: TextSpan(text: destination),
            expanded: _choosing,
            onExpansionChanged: (open) {
              if (!_sending) setState(() => _choosing = open);
            },
            children: [
              KitChoiceList<String>.single(
                semanticsLabel: l10n.commandDestination,
                actsOnTap: false,
                selected: _destination,
                choices: [
                  KitChoice(
                    value: '',
                    title: l10n.commandNewChat,
                    leading: const KitRowIcon(AppIconography.add),
                  ),
                  for (final session in _sessions)
                    KitChoice(
                      value: session.id,
                      title: _titleOf(session, l10n),
                    ),
                ],
                onSelected: (value) {
                  if (_sending) return;
                  setState(() {
                    _destination = value;
                    _choosing = false;
                  });
                },
              ),
              // The choices page themselves (target-ia §1.4).
              if (_sameLocation &&
                  OlderSessionsPager.showsFor(widget.controller))
                OlderSessionsPager(controller: widget.controller, inset: false),
            ],
          ),
          if (error != null) ...[
            SizedBox(height: tokens.space4),
            KitNotice.error(
              key: const ValueKey('command-error'),
              title: l10n.runCommandFailedTitle(name),
              message: error,
            ),
          ],
          SizedBox(height: tokens.space4),
          KitActionBlock(
            primary: KitAction(
              key: const ValueKey('command-submit'),
              label: l10n.commandRunTitle(name),
              icon: AppIconography.play,
              working: _sending,
              onPressed: _submit,
            ),
          ),
        ],
      ),
    );
  }
}
