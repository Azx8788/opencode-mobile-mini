import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../state/reader_preferences.dart';
import '../app_iconography.dart';
import '../kit/kit_icon_button.dart';
import '../kit/kit_layout.dart';
import 'product_states.dart' show showProductError;

/// Place above the Navigator so every reader, including a pushed snapshot,
/// shares the current profile's display preferences.
class ReaderPreferencesScope extends StatefulWidget {
  const ReaderPreferencesScope({
    super.key,
    required this.profileId,
    required this.prefs,
    required this.child,
  });

  final String? profileId;
  final SharedPreferences prefs;
  final Widget child;

  static ReaderPreferencesStore? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_ReaderPreferencesInherited>()
      ?.notifier;

  @override
  State<ReaderPreferencesScope> createState() => _ReaderPreferencesScopeState();
}

class _ReaderPreferencesScopeState extends State<ReaderPreferencesScope> {
  late ReaderPreferencesStore _store = _create();

  ReaderPreferencesStore _create() =>
      ReaderPreferencesStore(prefs: widget.prefs, profileId: widget.profileId);

  @override
  void didUpdateWidget(ReaderPreferencesScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.profileId != oldWidget.profileId ||
        widget.prefs != oldWidget.prefs) {
      final previous = _store;
      _store = _create();
      previous.dispose();
    }
  }

  @override
  void dispose() {
    _store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _ReaderPreferencesInherited(notifier: _store, child: widget.child);
}

class _ReaderPreferencesInherited
    extends InheritedNotifier<ReaderPreferencesStore> {
  const _ReaderPreferencesInherited({
    required super.notifier,
    required super.child,
  });
}

Future<void> saveReaderPreferences(
  BuildContext context, {
  bool? sourceFirst,
  bool? wrapCode,
}) async {
  final store = ReaderPreferencesScope.maybeOf(context);
  if (store == null) return;
  final saved = await store.update(
    sourceFirst: sourceFirst,
    wrapCode: wrapCode,
  );
  if (saved ||
      !context.mounted ||
      !identical(ReaderPreferencesScope.maybeOf(context), store)) {
    return;
  }
  final strings = lookupAppLocalizations(Localizations.localeOf(context));
  // The app's one mutation-failure outlet (product_states.dart); a host
  // without a messenger (an isolated preview) has nowhere to say it.
  if (ScaffoldMessenger.maybeOf(context) == null) return;
  showProductError(context, strings.readerUiSaveFailed);
}

/// Reuse the existing reader action area instead of adding a settings bar.
/// Kit only (shared-shell-1): a [KitIconButton] toggle.
class ReaderWrapButton extends StatelessWidget {
  const ReaderWrapButton({super.key, this.fallbackWrap});

  final bool? fallbackWrap;

  @override
  Widget build(BuildContext context) {
    final store = ReaderPreferencesScope.maybeOf(context);
    if (store == null) return const SizedBox.shrink();
    final strings = lookupAppLocalizations(Localizations.localeOf(context));
    // Wrapping is the default on a compact window (KitLayout, LAY-2).
    final wrap =
        store.value.wrapCode ??
        fallbackWrap ??
        KitLayout.windowOf(context) == KitWindow.compact;
    // A toggle: the kit's icon button carries the toggled semantics and the
    // 48 dp target (KIT-22).
    return KitIconButton(
      icon: AppIconography.wrapText,
      tooltip: wrap ? strings.markdownScrollCode : strings.markdownWrapCode,
      selected: wrap,
      onPressed: () => saveReaderPreferences(context, wrapCode: !wrap),
    );
  }
}
