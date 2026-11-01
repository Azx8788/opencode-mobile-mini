part of '../library_screen.dart';

/// "References" (map `references`, proposal fix), built from kit parts
/// (screen-library-4): one line that says what a reference is, then one
/// panel of [KitRow]s with the readable name and what it holds; the path
/// moves under the row's details. A tap opens the reference (its
/// description, how to use it, and its path folded under Details) with
/// "Copy @name" as the one action; from a conversation's picker a tap adds
/// it to the prompt instead. Copying goes through [KitCopy] (no snackbar).
///
/// A reference is a folder the server hands to the agent (OpenCode adds it
/// to a prompt as a directory part), so "preview the file" became this
/// details sheet; browsing the folder's files waits for Files to accept a
/// start folder (docs/qa/revamp-screen-library-4/README.md).
class ReferencesScreen extends StatefulWidget {
  final ConnectionController controller;
  final ValueChanged<ReferenceInfo>? onSelected;

  /// Embedded mode renders the body only, for the Commands & tools tabs.
  final bool embedded;

  const ReferencesScreen({
    super.key,
    required this.controller,
    this.onSelected,
    this.embedded = false,
  });

  @override
  State<ReferencesScreen> createState() => _ReferencesScreenState();
}

class _ReferencesScreenState extends State<ReferencesScreen> {
  List<ReferenceInfo>? _references;
  String? _error;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    if (_references == null) setState(() => _error = null);
    try {
      final repository = await widget.controller.prepareActionRepository();
      if (!mounted || generation != _loadGeneration) return;
      if (repository == null) {
        throw ProductException(
          _libraryCopy(context).e7LibraryOpenCodeIsReconnecting,
        );
      }
      final references = await repository.listReferences();
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _references = references;
        _error = null;
      });
    } catch (error) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = productErrorText(error));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _libraryCopy(context);
    return KitScreen(
      width: KitScreenWidth.list,
      topBar: widget.embedded
          ? null
          : KitTopBar(title: l10n.e7LibraryReferences),
      loading: _references == null && _error == null,
      loadingLabel: l10n.referencesScreenLoading,
      body: KitRefresh(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsetsDirectional.only(
            bottom: KitScreen.endPadding(context),
          ),
          children: _content(context),
        ),
      ),
    );
  }

  List<Widget> _content(BuildContext context) {
    final l10n = _libraryCopy(context);
    final tokens = KitTokens.of(context);
    Widget railed(Widget child) => Padding(
      padding: EdgeInsetsDirectional.only(
        start: tokens.gutter,
        end: tokens.gutter,
        bottom: tokens.space3,
      ),
      child: child,
    );
    final references = _references;
    final error = _error;
    if (references == null) {
      if (error == null) {
        return const [KitSkeletonRows(key: ValueKey('references-loading'))];
      }
      return [
        railed(
          KitStateView.error(
            key: const ValueKey('references-load-failed'),
            title: l10n.referencesScreenLoadFailed,
            body: error,
            reportSource: 'references',
            size: KitStateSize.inline,
            retry: KitAction(label: l10n.commonRetry, onPressed: _load),
          ),
        ),
      ];
    }
    if (references.isEmpty) {
      return [
        if (error != null) railed(_refreshFailed(context, error)),
        railed(
          KitStateView(
            key: const ValueKey('references-empty'),
            size: KitStateSize.inline,
            icon: AppIconography.bookmarks,
            title: l10n.e7LibraryNoReferencesConfigured,
            body: l10n.referencesScreenEmptyBody,
          ),
        ),
      ];
    }
    return [
      if (error != null) railed(_refreshFailed(context, error)),
      railed(
        KitText(
          l10n.referencesScreenIntro,
          key: const ValueKey('references-intro'),
          role: KitTextRole.secondary,
          tone: KitTextTone.secondary,
        ),
      ),
      KitRowGroup(
        children: [
          for (final reference in references) _referenceRow(context, reference),
        ],
      ),
    ];
  }

  Widget _refreshFailed(BuildContext context, String error) {
    final l10n = _libraryCopy(context);
    return KitNotice.error(
      key: const ValueKey('product-refresh-failed'),
      title: l10n.refreshFailed,
      message: error,
      retry: KitAction(label: l10n.refreshRetry, onPressed: _load),
    );
  }

  Widget _referenceRow(BuildContext context, ReferenceInfo reference) {
    final l10n = _libraryCopy(context);
    final mention = KitBidi.ltr('@${reference.name}');
    final description = reference.description?.trim();
    final picking = widget.onSelected != null;
    return KitRow(
      key: ValueKey('reference-${reference.name}'),
      leading: const KitRowIcon(AppIconography.bookmark),
      title: reference.name,
      supporting: TextSpan(
        text: description?.isNotEmpty == true
            ? description
            : KitBidi.ltr(reference.path),
      ),
      supportingMaxLines: 2,
      trailing: picking ? null : const KitChevron(),
      onTap: () => picking ? _add(reference) : _showReference(reference),
      menuLabel: l10n.referencesScreenMenuLabel,
      menu: [
        if (picking)
          KitMenuItem(
            label: l10n.referencesScreenAdd(mention),
            icon: AppIconography.add,
            onSelected: () => _add(reference),
          ),
        if (picking)
          KitMenuItem(
            label: l10n.referencesScreenShowDetails(
              KitBidi.auto(reference.name),
            ),
            icon: AppIconography.info,
            onSelected: () => _showReference(reference),
          ),
        KitMenuItem.copy(
          label: l10n.referencesScreenCopyMention(mention),
          text: () => '@${reference.name}',
        ),
        KitMenuItem.copy(
          label: l10n.referencesScreenCopyPath,
          text: () => reference.path,
        ),
      ],
    );
  }

  void _add(ReferenceInfo reference) {
    final onSelected = widget.onSelected;
    if (onSelected == null) return;
    onSelected(reference);
    Navigator.of(context).pop();
  }

  Future<void> _showReference(ReferenceInfo reference) async {
    final l10n = _libraryCopy(context);
    final mention = KitBidi.ltr('@${reference.name}');
    final description = reference.description?.trim();
    final picking = widget.onSelected != null;
    final added = await showKitSheet<bool>(
      context,
      sheetKey: const ValueKey('reference-sheet'),
      title: reference.name,
      icon: AppIconography.bookmark,
      primary: picking
          ? KitAction(
              key: const ValueKey('reference-add'),
              label: l10n.referencesScreenAdd(mention),
              icon: AppIconography.add,
              onPressed: () => Navigator.of(context).pop(true),
            )
          : KitAction.copy(
              key: const ValueKey('reference-copy'),
              label: l10n.referencesScreenCopyMention(mention),
              text: () => '@${reference.name}',
            ),
      body: (sheetContext) {
        final tokens = KitTokens.of(sheetContext);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KitText(
              description?.isNotEmpty == true
                  ? description!
                  : l10n.e7LibraryNoDescription,
              tone: description?.isNotEmpty == true
                  ? null
                  : KitTextTone.secondary,
            ),
            SizedBox(height: tokens.space2),
            KitText(
              l10n.referencesScreenSheetBody(mention),
              role: KitTextRole.secondary,
              tone: KitTextTone.secondary,
            ),
            SizedBox(height: tokens.space3),
            KitDetailsFold(
              values: [
                KitTechnicalValue(
                  l10n.referencesScreenPathLabel,
                  reference.path,
                  key: const ValueKey('reference-path'),
                ),
              ],
            ),
          ],
        );
      },
    );
    if (added == true && mounted) _add(reference);
  }
}
