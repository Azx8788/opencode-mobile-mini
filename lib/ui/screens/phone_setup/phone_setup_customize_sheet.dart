import 'dart:async';

import 'package:flutter/material.dart';

import '../../../builtin/builtin_linux.dart';
import '../../../builtin/setup/components.dart' show SetupComponentIds;
import '../../../builtin/setup/preflight.dart';
import '../../../builtin/setup/setup_contract.dart';
import '../../../l10n/app_localizations.dart';
import '../../../voice/device.dart';
import '../../app_theme.dart';
import '../../kit/kit.dart';
import 'phone_setup_selection.dart';

/// The Customize sheet of screen A, and "Add tools" from the phone's card.
///
/// First setup ([addMode] false): every component, the required ones first
/// and locked on, then the optional ones as switches. It returns the whole
/// selection (required ids included) so the caller can hand it straight to
/// `SetupEngine.run`.
///
/// Add mode: only optional components. Those already on the phone are shown
/// as installed and cannot be toggled; it returns only the ids to add.
///
/// An app-side component (voice typing, [SetupComponent.app]) shows only
/// once it says this phone can have it, with its real size; installed, it
/// is shown as installed in both modes, with its removal beside it.
///
/// Totals update as switches change and always count what the engine will
/// really install, dependencies included.
Future<Set<String>?> showSetupCustomizeSheet(
  BuildContext context, {
  required SetupEngine engine,
  bool addMode = false,
  Set<String>? selected,
}) {
  final l10n = lookupAppLocalizations(Localizations.localeOf(context));
  return showKitSheet<Set<String>>(
    context,
    title: addMode
        ? l10n.phoneSetupStartAddTitle
        : l10n.phoneSetupStartCustomizeTitle,
    icon: AppIconography.download,
    body: (_) => SetupCustomizeSheet(
      registry: installableComponents(engine.registry),
      addMode: addMode,
      selected: selected,
      loadInstalledOptional: addMode ? engine.installedOptional : null,
      framed: true,
    ),
  );
}

class SetupCustomizeSheet extends StatefulWidget {
  const SetupCustomizeSheet({
    super.key,
    required this.registry,
    this.addMode = false,
    this.selected,
    this.installedOptional,
    this.loadInstalledOptional,
    this.deviceProbe,
    this.linux,
    this.framed = false,
  });

  final List<SetupComponent> registry;

  /// Drawn inside a [KitSheet] ([showSetupCustomizeSheet]), which already
  /// shows the title and scrolls. False (the default, for a caller that
  /// hosts the sheet itself) draws the title and its own scroll view.
  final bool framed;
  final bool addMode;

  /// The current selection to start from; the registry defaults when null.
  final Set<String>? selected;

  /// Add mode only: which optional components are already installed. The
  /// check can take a moment (it asks inside Linux), so the sheet opens at
  /// once and locks its switches until the answer is in.
  final Future<Set<String>>? installedOptional;

  /// Production inventory reader. Read again when setup changes the tools;
  /// [installedOptional] remains available for callers with a fixed snapshot.
  final Future<Set<String>> Function()? loadInstalledOptional;

  /// The device info the pre-flight check reads (P0.8): CPU ABI, free space
  /// and total RAM. Defaults to [voiceDevicePlatform.getDeviceInfo], already
  /// collected for voice; tests stand in for the `oc/voice` channel.
  final Future<VoiceDeviceInfo> Function()? deviceProbe;

  /// Opens Android's Storage settings for the low-space state. Defaults to
  /// a plain [BuiltinLinux] (instances are cheap and hold no state).
  final BuiltinLinux? linux;

  @override
  State<SetupCustomizeSheet> createState() => _SetupCustomizeSheetState();
}

class _SetupCustomizeSheetState extends State<SetupCustomizeSheet> {
  late Set<String> _chosen;
  Set<String>? _installed;
  int _inventoryRead = 0;
  bool _inventoryFailed = false;
  VoiceDeviceInfo? _device;

  /// What each app-side component offers this phone, once it has answered;
  /// until then (and when it offers nothing) it has no row.
  final _offers = <String, SetupAppOffer>{};
  String? _removing;

  /// The registry as this phone sees it: app-side components only when
  /// offered, at their real size.
  List<SetupComponent> get _registry => [
    for (final component in widget.registry)
      if (component.app == null)
        component
      else if (_offers[component.id] case final offer?)
        component.withDownloadBytes(offer.downloadBytes),
  ];

  List<SetupComponent> get _optional => [
    for (final component in _registry)
      if (!component.required) component,
  ];

  @override
  void initState() {
    super.initState();
    unawaited(_probeDevice());
    for (final component in widget.registry) {
      if (component.app case final app?) unawaited(_ask(component.id, app));
    }
    if (widget.addMode) {
      _chosen = {...?widget.selected};
      if (widget.loadInstalledOptional != null) {
        setupToolsChanged.addListener(_readInstalled);
        unawaited(_readInstalled());
      } else if (widget.installedOptional != null) {
        unawaited(_readInstalled());
      } else {
        _installed = const {};
      }
    } else {
      _chosen = {
        for (final component in widget.registry)
          if (!component.required &&
              (widget.selected?.contains(component.id) ?? component.defaultOn))
            component.id,
      };
    }
  }

  Future<void> _readInstalled() async {
    final read = ++_inventoryRead;
    if (_inventoryFailed) setState(() => _inventoryFailed = false);
    try {
      final installed =
          await (widget.loadInstalledOptional?.call() ??
              widget.installedOptional!);
      if (!mounted || read != _inventoryRead) return;
      setState(() {
        _installed = Set.of(installed);
        _chosen.removeAll(installed);
      });
    } catch (_) {
      if (!mounted || read != _inventoryRead) return;
      setState(() => _inventoryFailed = true);
    }
  }

  @override
  void dispose() {
    setupToolsChanged.removeListener(_readInstalled);
    super.dispose();
  }

  bool _isInstalled(String id) {
    if (widget.addMode && widget.loadInstalledOptional != null) {
      // The engine includes app-side tools. A stale offer must not undo a
      // refreshed inventory after removal.
      return _installed?.contains(id) ?? false;
    }
    // Fixed-snapshot fixtures may supply app-side installation through the
    // offer independently, as first setup also does.
    return (_installed?.contains(id) ?? false) ||
        (_offers[id]?.installed ?? false);
  }

  Future<void> _ask(String id, SetupAppComponent app) async {
    SetupAppOffer? offer;
    try {
      offer = await app.offer();
    } catch (_) {
      offer = null;
    }
    if (!mounted) return;
    setState(() {
      if (offer == null) {
        _offers.remove(id);
        _chosen.remove(id);
      } else {
        _offers[id] = offer;
        if (offer.installed) _chosen.remove(id);
      }
    });
  }

  /// Removes an installed app-side component after a question that says
  /// what goes and how much space comes back; a failure stays in the
  /// question with Try again.
  Future<void> _remove(AppLocalizations l10n, SetupComponent component) async {
    final app = component.app;
    final offer = _offers[component.id];
    if (app == null || offer == null || _removing != null) return;
    setState(() => _removing = component.id);
    try {
      final removed = await showKitConfirm(
        context,
        title: l10n.voiceComponentRemoveTitle,
        body: l10n.voiceComponentRemoveBody(
          setupSizeText(l10n, offer.downloadBytes),
        ),
        confirmLabel: l10n.voiceComponentRemove,
        kind: KitConfirmKind.destructive,
        icon: AppIconography.delete,
        confirmKey: ValueKey(
          'phone-setup-customize-remove-${component.id}-confirm',
        ),
        action: () async {
          try {
            await app.remove();
          } finally {
            // Even a failed removal may have changed files. Every inventory
            // consumer must ask the engine again after the attempt ends.
            setupToolsChanged.value++;
          }
        },
      );
      if (removed && mounted) await _ask(component.id, app);
    } finally {
      if (mounted) setState(() => _removing = null);
    }
  }

  /// P0.8: the CPU ABI, free space and total RAM the pre-flight check reads,
  /// before "Done"/"Add" starts a download.
  Future<void> _probeDevice() async {
    VoiceDeviceInfo device;
    try {
      device =
          await (widget.deviceProbe ?? voiceDevicePlatform.getDeviceInfo)();
    } catch (_) {
      device = const VoiceDeviceInfo.unknown();
    }
    if (mounted) setState(() => _device = device);
  }

  /// Null while the device has not answered yet, or nothing is wrong.
  SetupPreflightResult? _preflightFor(List<SetupComponent> install) {
    final device = _device;
    if (device == null || install.isEmpty) return null;
    final result = checkSetupPreflight(
      device,
      downloadBytes: setupTotals(install).bytes,
    );
    return result.supported ? null : result;
  }

  Future<void> _openStorageSettings() async {
    try {
      await (widget.linux ?? BuiltinLinux()).openStorageSettings();
    } catch (_) {
      // No native answer (an old build, a test): nothing else to try.
    }
    if (mounted) unawaited(_probeDevice());
  }

  /// Turning a tool on turns on the optional tools it needs; turning one off
  /// turns off the optional tools that need it. The switches never show a
  /// state the engine would silently override.
  void _toggle(SetupComponent component, bool on) {
    final registry = _registry;
    final byId = {for (final c in registry) c.id: c};
    final next = {..._chosen};
    void enable(String id) {
      final target = byId[id];
      if (target == null || target.required || _isInstalled(id)) return;
      if (!next.add(id)) return;
      target.dependsOn.forEach(enable);
    }

    void disable(String id) {
      if (!next.remove(id)) return;
      for (final other in registry) {
        if (other.dependsOn.contains(id)) disable(other.id);
      }
    }

    if (on) {
      enable(component.id);
    } else {
      disable(component.id);
    }
    setState(() => _chosen = next);
  }

  /// What the engine will actually run for the current switches.
  List<SetupComponent> get _willInstall {
    final registry = _registry;
    if (!widget.addMode) {
      return [
        for (final component in expandSetupSelection(registry, _chosen))
          if (component.app == null || !_isInstalled(component.id)) component,
      ];
    }
    // Adding tools to a phone that is already set up: the required base is
    // there, and so is every optional tool the check found.
    return [
      for (final component in expandSetupSelection(
        registry,
        _chosen,
        includeRequired: false,
      ))
        if (!component.required && !_isInstalled(component.id)) component,
    ];
  }

  Set<String> get _result => {
    for (final component in _willInstall) component.id,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final tokens = KitTokens.of(context);
    final rows = widget.addMode ? _optional : _registry;
    final checking = widget.addMode && _installed == null;
    final install = _willInstall;
    final totals = setupTotals(install);
    // P0.8: told why before "Done"/"Add" starts a download, never after a
    // failed one.
    final preflight = checking ? null : _preflightFor(install);
    // Add mode with every optional tool already on the phone (map
    // statesMissing "everything optional installed"): nothing to choose.
    final everythingInstalled =
        widget.addMode &&
        !checking &&
        rows.isNotEmpty &&
        rows.every((component) => _isInstalled(component.id));
    final String totalsText;
    if (checking) {
      totalsText = l10n.phoneSetupStartChecking;
    } else if (everythingInstalled) {
      totalsText = l10n.phoneSetupCustomizeAllInstalled;
    } else if (install.isEmpty) {
      totalsText = l10n.phoneSetupStartNothingChosen;
    } else if (preflight != null) {
      totalsText = setupPreflightBody(l10n, preflight);
    } else {
      totalsText = l10n.phoneSetupStartTotals(
        setupDurationText(l10n, totals.seconds),
        setupSizeText(l10n, totals.bytes),
      );
    }
    final showsCost = !checking && !everythingInstalled && install.isNotEmpty;
    final disabled =
        checking || preflight != null || (widget.addMode && install.isEmpty);
    final children = <Widget>[
      if (!widget.framed)
        Padding(
          padding: EdgeInsetsDirectional.only(
            start: tokens.gutter,
            end: tokens.gutter,
            bottom: tokens.space2,
          ),
          child: Semantics(
            header: true,
            child: KitText(
              widget.addMode
                  ? l10n.phoneSetupStartAddTitle
                  : l10n.phoneSetupStartCustomizeTitle,
              role: KitTextRole.title,
            ),
          ),
        ),
      if (_inventoryFailed)
        KitNotice(
          message: l10n.e7SetupCheckInstallFailed,
          icon: AppIconography.warning,
          actions: [
            if (widget.loadInstalledOptional != null)
              KitAction(label: l10n.commonRetry, onPressed: _readInstalled),
          ],
        ),
      // What is always installed first, then what the person chooses: the
      // locks say "Required" once per row and nothing else repeats it.
      for (final group in [
        [
          for (final component in rows)
            if (component.required) component,
        ],
        [
          for (final component in rows)
            if (!component.required) component,
        ],
      ])
        if (group.isNotEmpty) ...[
          KitRowGroup(
            margin: EdgeInsetsDirectional.zero,
            leadingIcons: false,
            children: [
              for (final component in group)
                _row(context, l10n, component, checking: checking),
            ],
          ),
          SizedBox(height: tokens.space4),
        ],
      // What the switches add up to, said once as they change. A problem
      // the phone has (P0.8) is a notice with its fix beside it.
      // A real install is priced with the kit's cost line (KIT-37, P1.5:
      // before every install); checking and nothing-to-add stay words.
      if (preflight == null && showsCost)
        Semantics(
          liveRegion: true,
          child: KitNotice.cost(
            [
              setupDurationText(l10n, totals.seconds),
              l10n.phoneSetupStartApproxSize(setupSizeText(l10n, totals.bytes)),
            ],
            key: const ValueKey('phone-setup-customize-cost'),
            messageKey: const ValueKey('phone-setup-customize-totals'),
          ),
        )
      else if (preflight == null)
        Semantics(
          liveRegion: true,
          child: KitText(
            totalsText,
            key: const ValueKey('phone-setup-customize-totals'),
            role: KitTextRole.secondary,
            tone: KitTextTone.secondary,
          ),
        )
      else
        KitNotice(
          key: const ValueKey('phone-setup-customize-preflight'),
          messageKey: const ValueKey('phone-setup-customize-totals'),
          icon: AppIconography.warning,
          title: setupPreflightHeadline(l10n, preflight.issue!),
          message: totalsText,
          actions: [
            if (preflight.issue == SetupPreflightIssue.lowSpace)
              KitAction(
                key: const ValueKey('phone-setup-customize-open-storage'),
                label: l10n.phoneSetupPreflightOpenStorage,
                onPressed: _openStorageSettings,
              ),
          ],
        ),
      SizedBox(height: tokens.space4),
      // The line right above is the reason when it is off ("Nothing chosen
      // yet", "Checking…", everything installed, a pre-flight problem): the
      // visible reason next to the button (STATE-8), said once.
      KitActionBlock(
        primary: KitAction(
          key: const ValueKey('phone-setup-customize-done'),
          label: widget.addMode
              ? l10n.phoneSetupStartAdd
              : l10n.phoneSetupStartDone,
          onPressed: disabled ? null : () => Navigator.of(context).pop(_result),
        ),
      ),
    ];
    final column = Column(
      key: widget.framed ? const ValueKey('phone-setup-customize-sheet') : null,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
    if (widget.framed) return column;
    // Hosted on its own: one scroll for the whole sheet, since at large
    // text a pinned footer would leave no room for the rows it totals.
    return ListView(
      key: const ValueKey('phone-setup-customize-sheet'),
      shrinkWrap: true,
      padding: EdgeInsetsDirectional.only(
        start: tokens.gutter,
        end: tokens.gutter,
        bottom: tokens.space4,
      ),
      children: [column],
    );
  }

  Widget _row(
    BuildContext context,
    AppLocalizations l10n,
    SetupComponent component, {
    required bool checking,
  }) {
    final key = ValueKey('phone-setup-customize-${component.id}');
    if (component.required) {
      // Shown so nothing is installed behind the person's back, but locked
      // on (KIT-30: an always-on setting is locked, not a disabled switch):
      // switching it off would leave no working agent. Only a reason of its
      // own is said; "Required" already says why it cannot be switched off.
      return KitSwitchRow(
        key: key,
        title: component.title,
        value: true,
        onChanged: null,
        supporting: component.why,
        locked: l10n.phoneSetupCustomizeIncluded,
      );
    }
    final app = component.app != null;
    if ((widget.addMode || app) && _isInstalled(component.id)) {
      // Installed. One the app installed itself can be removed right here,
      // where it was added; what it does stays said, its size moves to the
      // question.
      return KitSwitchRow(
        key: key,
        title: component.title,
        value: true,
        onChanged: null,
        supporting: app ? component.summary : null,
        locked: l10n.phoneSetupStartInstalled,
        below: app && component.id == SetupComponentIds.voice
            ? KitInset(
                child: KitButton.tertiary(
                  key: ValueKey('phone-setup-customize-remove-${component.id}'),
                  label: l10n.voiceComponentRemove,
                  icon: AppIconography.delete,
                  destructive: true,
                  onPressed: _removing != null
                      ? null
                      : () => unawaited(_remove(l10n, component)),
                ),
              )
            : null,
      );
    }
    final bytes = component.downloadBytes;
    final supporting = [
      ?component.summary,
      // Kept on one line when the row wraps ("~160" and "MB" together).
      if (bytes != null && bytes > 0)
        l10n
            .phoneSetupStartApproxSize(setupSizeText(l10n, bytes))
            .replaceAll(' ', '\u00A0'),
    ];
    return KitSwitchRow(
      key: key,
      title: component.title,
      value: _chosen.contains(component.id),
      onChanged: checking ? null : (on) => _toggle(component, on),
      disabledReason: checking ? l10n.phoneSetupStartChecking : null,
      supporting: supporting.isEmpty ? null : supporting.join(' · '),
    );
  }
}
