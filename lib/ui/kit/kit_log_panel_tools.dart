part of 'kit_log_panel.dart';

/// The search field, Previous and Next match, and the Pause follow toggle
/// of a searchable [KitLogPanel]. Library-private: the panel owns the state.
class _LogTools extends StatelessWidget {
  const _LogTools({
    required this.paused,
    required this.query,
    required this.matchCount,
    required this.onSearch,
    required this.onStep,
    required this.onPause,
  });

  final bool paused;
  final String query;
  final int matchCount;
  final ValueChanged<String> onSearch;
  final ValueChanged<int> onStep;
  final VoidCallback onPause;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final tokens = KitTokens.of(context);
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        tokens.space3,
        tokens.space2,
        tokens.space2,
        tokens.space1,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: KitSearchField(
              fieldKey: const ValueKey('kit-log-search'),
              label: l10n.kitLogSearch,
              onChanged: onSearch,
              resultCount: query.isEmpty ? null : matchCount,
            ),
          ),
          if (matchCount > 1) ...[
            KitIconButton(
              key: const ValueKey('kit-log-prev'),
              icon: AppIconography.chevronUp,
              tooltip: l10n.kitLogPreviousMatch,
              onPressed: () => onStep(-1),
            ),
            KitIconButton(
              key: const ValueKey('kit-log-next'),
              icon: AppIconography.chevronDown,
              tooltip: l10n.kitLogNextMatch,
              onPressed: () => onStep(1),
            ),
          ],
          KitIconButton(
            key: const ValueKey('kit-log-pause'),
            icon: paused ? AppIconography.play : AppIconography.pause,
            tooltip: paused ? l10n.kitLogFollow : l10n.kitLogPause,
            selected: paused,
            onPressed: onPause,
          ),
        ],
      ),
    );
  }
}
