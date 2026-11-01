part of '../library_screen.dart';

/// "Skills" (map `skills`, proposal keep), built from kit parts
/// (screen-library-4): a plain panel of [KitRow]s that says what each skill
/// does, with the loading skeleton, an empty page that says what skills
/// are, and a failed load that explains itself. A tap opens the one skill
/// sheet ([_showSkillSheet]): from a conversation it adds the skill, from
/// Skills alone it previews it.
class SkillsScreen extends StatefulWidget {
  final ConnectionController controller;

  /// Embedded mode renders the body only, for the Commands & tools tabs.
  final bool embedded;
  final String? sessionID;
  const SkillsScreen({
    super.key,
    required this.controller,
    this.embedded = false,
    this.sessionID,
  });

  @override
  State<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<SkillsScreen> {
  List<SkillInfo>? _skills;
  String? _error;
  int _loadGeneration = 0;
  late int _location;
  late final int _chatLocation;

  @override
  void initState() {
    super.initState();
    _location = widget.controller.locationRevision;
    _chatLocation = _location;
    widget.controller.addListener(_connectionChanged);
    _load();
  }

  void _connectionChanged() {
    if (_location == widget.controller.locationRevision) return;
    _location = widget.controller.locationRevision;
    _loadGeneration++;
    setState(() {
      _skills = null;
      _error = null;
    });
    // A chat-scoped catalog must not become a catalog for another location.
    if (widget.sessionID == null) {
      _load();
    } else {
      setState(() => _error = _libraryCopy(context).skillLocationChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_connectionChanged);
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.sessionID != null && _location != _chatLocation) {
      setState(() => _error = _libraryCopy(context).skillLocationChanged);
      return;
    }
    final generation = ++_loadGeneration;
    if (_skills == null) setState(() => _error = null);
    try {
      final repository = await widget.controller.prepareActionRepository();
      if (!mounted || generation != _loadGeneration) return;
      if (repository == null) {
        throw ProductException(
          _libraryCopy(context).e7LibraryOpenCodeIsReconnecting,
        );
      }
      final skills = await repository.listSkills();
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _skills = skills;
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
      topBar: widget.embedded ? null : KitTopBar(title: l10n.e7LibrarySkills),
      loading: _skills == null && _error == null,
      loadingLabel: l10n.skillsScreenLoading,
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
    final skills = _skills;
    final error = _error;
    if (skills == null) {
      if (error == null) {
        return const [KitSkeletonRows(key: ValueKey('skills-loading'))];
      }
      return [
        railed(
          KitStateView.error(
            key: const ValueKey('skills-load-failed'),
            title: l10n.skillsScreenLoadFailed,
            body: error,
            reportSource: 'skills',
            size: KitStateSize.inline,
            retry: KitAction(label: l10n.commonRetry, onPressed: _load),
          ),
        ),
      ];
    }
    return [
      if (error != null)
        railed(
          KitNotice.error(
            key: const ValueKey('product-refresh-failed'),
            title: l10n.refreshFailed,
            message: error,
            retry: KitAction(label: l10n.refreshRetry, onPressed: _load),
          ),
        ),
      if (skills.isEmpty)
        railed(
          KitStateView(
            key: const ValueKey('skills-empty'),
            size: KitStateSize.inline,
            icon: AppIconography.extensions,
            title: l10n.e7LibraryNoSkillsAvailable,
            body: l10n.emptyTeachSkillsMessage,
          ),
        )
      else
        KitRowGroup(
          children: [
            for (final skill in skills)
              KitRow(
                key: ValueKey('skill-${skill.name}'),
                leading: const KitRowIcon(AppIconography.extensions),
                title: skill.name,
                supporting: TextSpan(
                  text: skill.description?.trim().isNotEmpty == true
                      ? skill.description
                      : KitBidi.ltr(skill.location),
                ),
                supportingMaxLines: 2,
                trailing: const KitChevron(),
                onTap: () => _showSkill(skill),
              ),
          ],
        ),
    ];
  }

  Future<void> _showSkill(SkillInfo skill) async {
    final used = await _showSkillSheet(
      context,
      controller: widget.controller,
      skill: skill,
      location: _location,
      sessionID: widget.sessionID,
    );
    if (mounted && used == true) Navigator.of(context).pop(true);
  }
}
