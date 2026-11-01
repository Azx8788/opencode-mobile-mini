part of '../chat_screen.dart';

typedef _AttachmentChooser =
    Future<PromptAttachment?> Function(List<PromptAttachment> current);

class _PromptEditorResult {
  const _PromptEditorResult({required this.value, required this.attachments});

  final TextEditingValue value;
  final List<PromptAttachment> attachments;
}

/// The full-screen prompt editor: a calm page with the prompt's
/// attachments on top, one tall field, and Done pinned above the keyboard.
/// Done hands the text and attachments back to the composer; Close with
/// changes asks once whether to discard them, and the composer's own draft
/// is never touched until Done.
class _PromptEditorScreen extends StatefulWidget {
  const _PromptEditorScreen({
    required this.initialValue,
    required this.initialAttachments,
    required this.chooseAttachment,
  });

  final TextEditingValue initialValue;
  final List<PromptAttachment> initialAttachments;
  final _AttachmentChooser? chooseAttachment;

  @override
  State<_PromptEditorScreen> createState() => _PromptEditorScreenState();
}

class _PromptEditorScreenState extends State<_PromptEditorScreen> {
  late final TextEditingController _controller;
  late final List<PromptAttachment> _attachments;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController.fromValue(widget.initialValue);
    _attachments = List<PromptAttachment>.from(widget.initialAttachments);
  }

  bool get _dirty =>
      _controller.text != widget.initialValue.text ||
      !_sameAttachments(_attachments, widget.initialAttachments);

  bool _sameAttachments(
    List<PromptAttachment> left,
    List<PromptAttachment> right,
  ) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      final a = left[index];
      final b = right[index];
      if (a.mime != b.mime || a.filename != b.filename || a.url != b.url) {
        return false;
      }
    }
    return true;
  }

  Future<void> _addAttachment() async {
    final chooseAttachment = widget.chooseAttachment;
    if (chooseAttachment == null) return;
    try {
      final attachment = await chooseAttachment(_attachments);
      if (!mounted || attachment == null) return;
      setState(() => _attachments.add(attachment));
    } catch (error) {
      if (!mounted) return;
      showProductError(context, error);
    }
  }

  void _save() {
    Navigator.pop(
      context,
      _PromptEditorResult(
        value: _controller.value,
        attachments: List.unmodifiable(_attachments),
      ),
    );
  }

  Future<void> _cancel() async {
    if (_closing) return;
    if (!_dirty) {
      Navigator.pop(context);
      return;
    }
    _closing = true;
    final l10n = _chatL10n(context);
    final discard = await showKitConfirm(
      context,
      kind: KitConfirmKind.destructive,
      icon: AppIconography.clearAll,
      title: l10n.chatUiDiscardPromptChanges,
      body: l10n.chatUiYourOriginalComposerDraftAndAttachmentsWill,
      confirmLabel: l10n.promptEditorDiscardChanges,
      cancelLabel: l10n.draftKeepEditing,
    );
    _closing = false;
    if (discard && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _chatL10n(context);
    final tokens = KitTokens.of(context);
    final full = _attachments.length >= _maxAttachmentCount;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_cancel());
      },
      child: KitScreen(
        key: const Key('prompt-editor-screen'),
        // A page of prose: centred at the reading width on wide windows.
        width: KitScreenWidth.reading,
        topBar: KitTopBar(
          title: l10n.chatUiPromptEditor,
          exit: KitTopBarExit.close,
          onExit: () => unawaited(_cancel()),
          actions: [
            if (widget.chooseAttachment != null)
              KitAction(
                key: const Key('prompt-editor-attach'),
                icon: AppIconography.attach,
                label: l10n.chatUiAttachFile,
                disabledReason: full ? l10n.chatUiAttachmentLimitReached : null,
                onPressed: full ? null : () => unawaited(_addAttachment()),
              ),
          ],
        ),
        bottom: KitActionBlock(
          primary: KitAction(
            key: const Key('prompt-editor-done'),
            icon: AppIconography.check,
            label: l10n.promptEditorDone,
            onPressed: _save,
          ),
        ),
        body: ListView(
          padding: EdgeInsetsDirectional.fromSTEB(
            tokens.gutter,
            tokens.space2,
            tokens.gutter,
            tokens.space4,
          ),
          children: [
            // Attachments sit above the field, so the keyboard never
            // covers them.
            if (_attachments.isNotEmpty)
              Padding(
                padding: EdgeInsetsDirectional.only(bottom: tokens.space3),
                child: KitComposerChips.attachments(
                  stripKey: const Key('prompt-editor-attachments'),
                  items: [
                    for (final attachment in _attachments)
                      KitAttachment(
                        id: attachment,
                        label: attachment.isDirectoryReference
                            ? '@${attachment.filename}'
                            : attachment.filename,
                        kind: attachment.isDirectoryReference
                            ? KitAttachmentKind.folder
                            : attachment.mime.startsWith('image/')
                            ? KitAttachmentKind.image
                            : KitAttachmentKind.file,
                        thumbnail: switch (_thumbnailBytes(attachment)) {
                          final bytes? => KitImageSource.memory(bytes),
                          null => null,
                        },
                      ),
                  ],
                  onRemove: (item) =>
                      setState(() => _attachments.remove(item.id)),
                ),
              ),
            KitField(
              label: l10n.promptEditorFieldLabel,
              controller: _controller,
              kind: KitFieldKind.multiline,
              hint: l10n.chatUiWriteYourOpenCodePrompt,
              maxLines: KitLayout.isShort(context) ? 6 : 18,
              autofocus: true,
              fieldKey: const Key('prompt-editor-field'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
