import 'dart:async';

import 'package:flutter/material.dart';

import '../../builtin/builtin_linux.dart';
import '../../builtin/builtin_provider_store.dart';
import '../../builtin/builtin_provider_templates.dart';
import '../../builtin/builtin_server.dart' show looksLikeInAppServer;
import '../../domain/custom_provider.dart' show ProviderProtocol;
import '../../domain/custom_provider_record.dart';
import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import '../app_iconography.dart';
import '../app_theme.dart' show AppStatusTone;
import '../kit/kit.dart';
import 'custom_provider_screen.dart';
import 'provider_models_screen.dart';
import 'provider_probe_screen.dart';

AppLocalizations _l10nOf(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

/// The providers written into the server's own config.
///
/// The form could add one but never show it again, so a typo in the base URL
/// or a key that expired could only be fixed by editing the file on the
/// server. This page is the missing half: it lists what the config holds,
/// opens the same form filled in, tests a saved provider with its own key,
/// and removes one with a backup left behind.
class CustomProvidersScreen extends StatefulWidget {
  const CustomProvidersScreen({
    super.key,
    required this.controller,
    this.linux,
    this.embedded = false,
    this.initialProviderID,
  });

  final ConnectionController controller;

  /// The in-app server bridge. Null means "make one" — instances are cheap.
  final BuiltinLinux? linux;

  /// Body only, for a host that already has a top bar of its own.
  final bool embedded;

  /// A provider some other screen asked for ("this model's provider"): its
  /// form opens once, as soon as the list is read. Null opens nothing.
  final String? initialProviderID;

  @override
  State<CustomProvidersScreen> createState() => _CustomProvidersScreenState();
}

class _CustomProvidersScreenState extends State<CustomProvidersScreen> {
  late final BuiltinLinux _linux = widget.linux ?? BuiltinLinux();
  late final BuiltinProviderStore _store = BuiltinProviderStore(linux: _linux);

  CustomProviderCatalogue? _catalogue;
  ResolvedProviderConfig? _resolved;
  Object? _error;
  bool _loading = true;
  bool _busy = false;
  bool _initialOpened = false;

  /// True when this profile is the server the app itself runs, whose files
  /// this app may write.
  bool get _writable => looksLikeInAppServer(widget.controller.profile);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (!_writable) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final resolved = await _store.resolve();
      final catalogue = await _store.readRecords(resolved: resolved);
      if (!mounted) return;
      setState(() {
        _resolved = resolved;
        _catalogue = catalogue;
        _loading = false;
      });
      _openInitialOnce();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  /// Opens the provider some other screen asked for, once.
  ///
  /// "Configure this model's provider" used to land on the server's own
  /// provider list. That list is hidden now, so the same tap lands here and
  /// opens the entry whose id the caller named.
  void _openInitialOnce() {
    if (_initialOpened || !mounted) return;
    final id = widget.initialProviderID?.trim().toLowerCase();
    if (id == null || id.isEmpty) return;
    final catalogue = _catalogue;
    if (catalogue == null) return;
    ProviderListEntry? entry;
    for (final candidate in providerListEntries(catalogue)) {
      if (candidate.id.toLowerCase() == id) {
        entry = candidate;
        break;
      }
    }
    if (entry == null || entry.blocked) return;
    _initialOpened = true;
    final target = entry;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        _openForm(
          target.record,
          template: target.record == null ? target.template : null,
        ),
      );
    });
  }

  Future<void> _openForm(
    CustomProviderRecord? record, {
    BuiltinProviderTemplate? template,
  }) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CustomProviderScreen(
          controller: widget.controller,
          linux: widget.linux,
          editing: record,
          template: template,
        ),
      ),
    );
    if (saved == true && mounted) await _load();
  }

  Future<void> _test(CustomProviderRecord record) async {
    final l10n = _l10nOf(context);
    if (record.models.isEmpty) {
      _say(l10n.providerManageNoModel);
      return;
    }
    var key = record.apiKey;
    final secretPath = record.secretPath;
    if ((key == null || key.isEmpty) && secretPath != null) {
      key = await _store.readSecret(secretPath);
    }
    if (!mounted) return;
    final resolvedKey = key;
    if (resolvedKey == null || resolvedKey.isEmpty) {
      _say(l10n.providerManageNoKey);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProviderProbeScreen(
          providerName: record.name,
          model: record.models.first.id,
          baseUrl: record.baseUrl,
          protocol: record.protocol,
          apiKey: resolvedKey,
          autoRun: true,
        ),
      ),
    );
  }

  Future<void> _delete(CustomProviderRecord record) async {
    final l10n = _l10nOf(context);
    final agreed = await showKitConfirm(
      context,
      title: l10n.providerManageDeleteTitle(record.name),
      body: l10n.providerManageDeleteBody,
      confirmLabel: l10n.providerManageDelete,
      kind: KitConfirmKind.destructive,
      icon: AppIconography.delete,
      confirmKey: const ValueKey('provider-delete-confirm'),
    );
    if (!agreed || !mounted) return;
    setState(() => _busy = true);
    try {
      await _store.remove(record.id, resolved: _resolved);
      if (!mounted) return;
      setState(() => _busy = false);
      _say(l10n.providerManageDeleted(record.name));
      await _load();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  void _say(String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10nOf(context);
    return KitScreen(
      width: KitScreenWidth.list,
      topBar: widget.embedded
          ? null
          : KitTopBar(
              title: l10n.providerManageTitle,
              subtitle: widget.controller.profile?.name,
              actions: [
                KitAction(
                  key: const ValueKey('providers-add-top'),
                  label: l10n.providerAddTitle,
                  icon: AppIconography.add,
                  onPressed: _loading ? null : () => _openForm(null),
                ),
                KitAction(
                  key: const ValueKey('providers-refresh'),
                  label: l10n.providerManageRefresh,
                  icon: AppIconography.retry,
                  onPressed: _loading ? null : _load,
                ),
              ],
            ),
      status: _busy
          ? KitStatus(
              kind: KitStatusKind.work,
              icon: AppIconography.waiting,
              message: l10n.providerManageWorking,
              tone: AppStatusTone.progress,
            )
          : null,
      body: ListView(
        key: const ValueKey('custom-providers-list'),
        padding: KitScreen.padding(context),
        children: [
          if (!_writable)
            KitNotice(
              key: const ValueKey('providers-copy-only'),
              tone: AppStatusTone.attention,
              icon: AppIconography.warning,
              message: l10n.providerAddCopyOnly,
            )
          else
            KitNotice(
              key: const ValueKey('providers-intro'),
              icon: AppIconography.info,
              message: l10n.providerManageIntro,
            ),
          ..._body(context, l10n),
        ],
      ),
    );
  }

  List<Widget> _body(BuildContext context, AppLocalizations l10n) {
    final tokens = KitTokens.of(context);
    final gap = SizedBox(height: tokens.space3);
    if (_error != null) {
      return [
        gap,
        KitStateView.error(
          key: const ValueKey('providers-load-failed'),
          size: KitStateSize.inline,
          title: l10n.providerManageLoadFailed,
          body: '$_error',
          error: _error,
          retry: KitAction(label: l10n.commonRetry, onPressed: _load),
        ),
      ];
    }
    final catalogue = _catalogue;
    if (_loading && catalogue == null) {
      return [gap, const KitSkeletonRows(count: 4)];
    }
    if (!_writable) {
      // A remote server's files are out of reach; the form still earns its
      // keep as a snippet generator, so the door is not closed.
      return [
        gap,
        KitStateView(
          key: const ValueKey('providers-copy-only-state'),
          size: KitStateSize.inline,
          icon: AppIconography.model,
          title: l10n.providerManageTitle,
          body: l10n.providerAddCopyOnly,
          primary: KitAction(
            label: l10n.providerAddTitle,
            icon: AppIconography.add,
            onPressed: () => _openForm(null),
          ),
        ),
      ];
    }
    if (catalogue == null) return const [];
    final entries = providerListEntries(catalogue);
    // Two sources, two sections: a shipped template is a provider whose
    // models come from the server's own catalogue, and a custom one is a
    // channel the person declared. They behave differently on save (one is
    // merged onto a catalogue, the other *is* the catalogue), so a single
    // "configured / available" split hid the difference that matters.
    final builtin = [
      for (final entry in entries)
        if (entry.template != null) entry,
    ];
    final custom = [
      for (final entry in entries)
        if (entry.template == null) entry,
    ];
    List<ProviderListEntry> ordered(List<ProviderListEntry> list) => [
      for (final entry in list)
        if (entry.configured) entry,
      for (final entry in list)
        if (!entry.configured) entry,
    ];
    final configuredCount = entries.where((entry) => entry.configured).length;
    return [
      gap,
      if (builtin.isNotEmpty) ...[
        KitRowGroup(
          margin: EdgeInsets.zero,
          label: l10n.providerGroupBuiltin,
          children: [
            for (final entry in ordered(builtin)) _row(context, l10n, entry),
          ],
        ),
        SizedBox(height: tokens.space2),
        KitText(
          l10n.providerGroupBuiltinHint,
          key: const ValueKey('providers-builtin-hint'),
          role: KitTextRole.caption,
          tone: KitTextTone.secondary,
        ),
      ],
      if (custom.isNotEmpty) ...[
        SizedBox(height: tokens.space4),
        KitRowGroup(
          margin: EdgeInsets.zero,
          label: l10n.providerGroupCustom,
          children: [
            for (final entry in ordered(custom)) _row(context, l10n, entry),
          ],
        ),
        SizedBox(height: tokens.space2),
        KitText(
          l10n.providerGroupCustomHint,
          key: const ValueKey('providers-custom-hint'),
          role: KitTextRole.caption,
          tone: KitTextTone.secondary,
        ),
      ],
      if (configuredCount == 0) ...[
        SizedBox(height: tokens.space3),
        KitText(
          l10n.providerGroupAvailable,
          key: const ValueKey('providers-available-hint'),
          role: KitTextRole.caption,
          tone: KitTextTone.secondary,
        ),
      ],
      if (catalogue.unreadable > 0) ...[
        SizedBox(height: tokens.space3),
        KitRowGroup(
          margin: EdgeInsets.zero,
          children: [
            KitRow(
              key: const ValueKey('providers-unreadable'),
              title: l10n.providerManageUnreadable(catalogue.unreadable),
              supporting: TextSpan(text: l10n.providerManageUnreadableBody),
              supportingMaxLines: 3,
              enabled: false,
              disabledReason: l10n.providerManageUnreadableBody,
            ),
          ],
        ),
      ],
      // The catalogue view keeps its door: it is where every model of every
      // provider sits on one page, with a switch and a test each.
      SizedBox(height: tokens.space4),
      KitRowGroup(
        margin: EdgeInsets.zero,
        children: [
          KitRow(
            key: const ValueKey('providers-open-models'),
            title: l10n.providerModelsTitle,
            supporting: TextSpan(text: l10n.providerModelsHint),
            supportingMaxLines: 2,
            trailing: const KitChevron(),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    ProviderModelsScreen(controller: widget.controller),
              ),
            ),
          ),
        ],
      ),
    ];
  }

  Widget _row(
    BuildContext context,
    AppLocalizations l10n,
    ProviderListEntry entry,
  ) {
    final tokens = KitTokens.of(context);
    final record = entry.record;
    final protocol = switch (entry.protocol) {
      ProviderProtocol.chatCompletions => l10n.providerAddProtocolChat,
      ProviderProtocol.responses => l10n.providerAddProtocolResponses,
      ProviderProtocol.anthropic => l10n.providerAddProtocolAnthropic,
      ProviderProtocol.google => 'Google',
    };
    return KitRow(
      key: ValueKey('provider-row-${entry.id}'),
      title: entry.name,
      supporting: TextSpan(
        text: [
          entry.id,
          protocol,
          if (record == null)
            entry.blocked
                ? l10n.providerManageUnreadableBody
                : l10n.providerNotConfigured
          else
            l10n.providerManageModels(record.models.length),
        ].join(' · '),
      ),
      supportingMaxLines: 3,
      enabled: !entry.blocked,
      disabledReason: entry.blocked ? l10n.providerManageUnreadableBody : null,
      trailing: const KitChevron(),
      onTap: entry.blocked
          ? null
          : () => _openForm(
              record,
              template: record == null ? entry.template : null,
            ),
      menuLabel: l10n.providerManageMenu(entry.name),
      menu: [
        if (record == null)
          KitMenuItem(
            key: ValueKey('provider-setup-${entry.id}'),
            label: l10n.providerManageSetup,
            icon: AppIconography.edit,
            onSelected: () => _openForm(null, template: entry.template),
          )
        else ...[
          KitMenuItem(
            key: ValueKey('provider-edit-${entry.id}'),
            label: l10n.providerManageEdit,
            icon: AppIconography.edit,
            onSelected: () => _openForm(record),
          ),
          KitMenuItem(
            key: ValueKey('provider-test-${entry.id}'),
            label: l10n.providerManageTest,
            icon: AppIconography.play,
            onSelected: () => _test(record),
          ),
          KitMenuItem(
            key: ValueKey('provider-delete-${entry.id}'),
            label: l10n.providerManageDelete,
            icon: AppIconography.delete,
            destructive: true,
            onSelected: () => _delete(record),
          ),
        ],
      ],
      below: Padding(
        padding: EdgeInsetsDirectional.only(top: tokens.space1),
        child: Text(
          entry.baseUrl,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: KitText.styleOf(context, KitTextRole.caption),
        ),
      ),
    );
  }
}
