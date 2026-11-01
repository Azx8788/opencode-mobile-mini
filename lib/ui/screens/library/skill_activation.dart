part of '../library_screen.dart';

/// The one skill sheet (map `skill-activation-sheet`, proposal fix; the
/// `skills-preview-sheet` merges into it), built from kit parts
/// (screen-library-4). Both ways in show the same skill the same way: the
/// skill's name as the sheet title, its instructions formatted (with
/// Rendered / Raw as a [KitSegmented], the check marking the chosen view),
/// the SKILL.md heading that only repeats the name stripped, and where the
/// file lives folded under Details.
///
/// From a conversation ([sessionID] set) the sheet adds the skill: one line
/// on what adding does, "Run agent now" as a [KitSwitchRow], and "Add to
/// conversation" as the pinned primary, which works in place and says why
/// it failed ("add failed", map statesMissing) under the switch. Opened
/// from Skills without a conversation it is a preview whose one way to use
/// the skill is copying its slash command, when it has one.
///
/// Resolves to true once the skill was added to this conversation.
Future<bool?> _showSkillSheet(
  BuildContext context, {
  required ConnectionController controller,
  required SkillInfo skill,
  required int location,
  String? sessionID,
}) async {
  final l10n = _libraryCopy(context);
  final navigator = Navigator.of(context);
  final activation = sessionID == null
      ? null
      : _SkillActivation(
          controller: controller,
          sessionID: sessionID,
          skill: skill,
          location: location,
        );
  var open = true;
  final primary = ValueNotifier<KitAction?>(null);
  void publish() {
    final state = activation;
    if (state == null) return;
    primary.value = KitAction(
      key: const ValueKey('skill-activate'),
      label: l10n.skillUse,
      icon: AppIconography.extensions,
      working: state.sending,
      onPressed: state.locked
          ? null
          : () async {
              if (await state.activate(l10n) && open) navigator.pop(true);
            },
      disabledReason: state.locked ? l10n.skillSheetCheckConversation : null,
    );
  }

  activation?.addListener(publish);
  publish();
  final sessionTitle = sessionID == null
      ? null
      : controller.sessionsById[sessionID]?.title;
  final description = skill.description?.trim();
  final command = skill.id ?? skill.name;
  try {
    return await showKitSheet<bool>(
      context,
      sheetKey: const ValueKey('skill-sheet'),
      title: skill.name,
      subtitle: sessionID != null
          ? (sessionTitle?.isNotEmpty == true
                ? sessionTitle
                : l10n.commandUntitledChat)
          : (description?.isNotEmpty == true ? description : null),
      icon: AppIconography.extensions,
      height: KitSheetHeight.full,
      primaryListenable: activation == null ? null : primary,
      tertiary: [
        if (activation == null && skill.slashCommand)
          KitAction.copy(
            key: const ValueKey('skill-copy-command'),
            label: l10n.skillSheetCopyCommand(KitBidi.ltr('/$command')),
            text: () => '/$command',
          ),
      ],
      body: (_) => _SkillSheetBody(skill: skill, activation: activation),
    );
  } finally {
    open = false;
    activation?.removeListener(publish);
    activation?.dispose();
    primary.dispose();
  }
}

/// What adding a skill is doing now; the sheet's body and its pinned
/// primary both draw from it.
class _SkillActivation extends ChangeNotifier {
  _SkillActivation({
    required this.controller,
    required this.sessionID,
    required this.skill,
    required this.location,
  });

  final ConnectionController controller;
  final String sessionID;
  final SkillInfo skill;
  final int location;

  bool resume = true;
  bool sending = false;
  bool uncertain = false;
  bool appliedElsewhere = false;
  String? error;
  bool _disposed = false;

  /// Nothing more to send from this sheet: the result is unknown, or the
  /// skill went to the conversation of a location left meanwhile.
  bool get locked => uncertain || appliedElsewhere;

  void setResume(bool value) {
    resume = value;
    _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Sends the skill; true when it landed in this conversation and the
  /// sheet may close.
  Future<bool> activate(AppLocalizations l10n) async {
    if (sending || locked) return false;
    sending = true;
    error = null;
    _changed();
    try {
      await controller.activateSessionSkill(
        sessionID,
        skill.id ?? skill.name,
        resume: resume,
        expectedLocation: location,
      );
      if (controller.locationRevision == location) return true;
      appliedElsewhere = true;
      error = l10n.skillAppliedOriginal;
      return false;
    } on SessionSkillException catch (failure) {
      uncertain = failure.failure == SessionSkillFailure.uncertain;
      error = switch (failure.failure) {
        SessionSkillFailure.unsupported => l10n.skillUnsupported,
        SessionSkillFailure.changed => l10n.skillLocationChanged,
        SessionSkillFailure.staged => l10n.skillStaged,
        SessionSkillFailure.busy => l10n.skillBusy,
        SessionSkillFailure.uncertain => l10n.skillUncertain,
      };
      return false;
    } catch (failure) {
      error = productErrorText(failure);
      return false;
    } finally {
      sending = false;
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

enum _SkillView { rendered, raw }

class _SkillSheetBody extends StatefulWidget {
  const _SkillSheetBody({required this.skill, required this.activation});

  final SkillInfo skill;
  final _SkillActivation? activation;

  @override
  State<_SkillSheetBody> createState() => _SkillSheetBodyState();
}

class _SkillSheetBodyState extends State<_SkillSheetBody> {
  _SkillView _view = _SkillView.rendered;

  @override
  Widget build(BuildContext context) {
    final activation = widget.activation;
    if (activation == null) return _body(context, null);
    return ListenableBuilder(
      listenable: activation,
      builder: (context, _) => PopScope(
        // Back waits while the skill is being sent: the answer decides
        // whether the sheet says it failed or closes as added.
        canPop: !activation.sending,
        child: _body(context, activation),
      ),
    );
  }

  Widget _body(BuildContext context, _SkillActivation? activation) {
    final l10n = _libraryCopy(context);
    final tokens = KitTokens.of(context);
    final skill = widget.skill;
    final error = activation?.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (activation != null) ...[
          KitText(
            l10n.skillActivationHelp,
            role: KitTextRole.secondary,
            tone: KitTextTone.secondary,
          ),
          SizedBox(height: tokens.space2),
          KitRowGroup(
            margin: EdgeInsets.zero,
            leadingIcons: false,
            children: [
              KitSwitchRow(
                switchKey: const ValueKey('skill-resume'),
                title: l10n.skillRunNow,
                supporting: l10n.skillRunHelp,
                value: activation.resume,
                onChanged: activation.sending || activation.locked
                    ? null
                    : activation.setResume,
                disabledReason: activation.locked
                    ? l10n.skillSheetCheckConversation
                    : activation.sending
                    ? l10n.skillSheetSending
                    : null,
              ),
            ],
          ),
          if (error != null) ...[
            SizedBox(height: tokens.space3),
            KitNotice(
              key: const ValueKey('skill-activation-error'),
              message: error,
              tone: activation.appliedElsewhere
                  ? AppStatusTone.ok
                  : AppStatusTone.failure,
              icon: activation.appliedElsewhere
                  ? AppIconography.checkCircle
                  : AppIconography.warning,
            ),
          ],
          SizedBox(height: tokens.space4),
        ],
        KitSegmented<_SkillView>(
          key: const ValueKey('skill-view'),
          semanticsLabel: l10n.skillSheetViewLabel,
          selected: _view,
          onChanged: (view) => setState(() => _view = view),
          segments: [
            KitSegment(
              value: _SkillView.rendered,
              label: l10n.readerUiRendered,
            ),
            KitSegment(value: _SkillView.raw, label: l10n.readerUiRaw),
          ],
        ),
        SizedBox(height: tokens.space3),
        KeyedSubtree(
          key: ValueKey(
            activation == null
                ? 'skill-content-preview'
                : 'skill-activation-preview',
          ),
          child: switch (_view) {
            _SkillView.rendered => KitMarkdown(
              _skillProse(skill.content, skill.name),
            ),
            _SkillView.raw => KitCodeBlock(
              text: skill.content,
              language: 'markdown',
              fileName: 'SKILL.md',
              maxLines: KitViewer.maxLines,
            ),
          },
        ),
        SizedBox(height: tokens.space4),
        KitDetailsFold(
          values: [
            KitTechnicalValue(
              l10n.skillSheetLocation,
              skill.location,
              key: const ValueKey('skill-location'),
            ),
          ],
        ),
      ],
    );
  }
}

/// The skill's instructions as prose: without the YAML front matter the
/// server keeps for itself, and without a first heading that only repeats
/// the skill's name (the sheet's title already says it). Raw shows the
/// file as it is.
String _skillProse(String content, String name) {
  var text = content.replaceFirst(
    RegExp(r'^﻿?---\r?\n[\s\S]*?\r?\n---[ \t]*(\r?\n|$)'),
    '',
  );
  final heading = RegExp(r'^\s*#[ \t]+([^\n]+)\n?').firstMatch(text);
  String plain(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  if (heading != null &&
      plain(name).isNotEmpty &&
      plain(heading.group(1)!) == plain(name)) {
    text = text.substring(heading.end);
  }
  return text.trimLeft();
}
