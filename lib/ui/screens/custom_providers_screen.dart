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
  });

  final ConnectionController controller;

  /// The in-app server bridge. Null means "make one" — instances are cheap.
  final BuiltinLinux? linux;

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
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
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

  /// The way in: pick what kind of provider this is, then fill it in on the
  /// detail page. The template only prefills the address and protocol; it
  /// writes nothing.
  Future<void> _pickTemplate() async {
    final l10n = _l10nOf(context);
    final template = await showKitSheet<BuiltinProviderTemplate>(
      context,
      title: l10n.providerTemplateTitle,
      subtitle: l10n.providerTemplateSubtitle,
      itemCount: builtinProviderTemplates.length,
      itemBuilder: (sheetContext, index) {
        final template = builtinProviderTemplates[index];
        final custom = template.kind == ProviderTemplateKind.custom;
        return KitRow(
          key: ValueKey('provider-template-${template.id}'),
          title: custom ? l10n.providerTemplateCustomName : template.name,
          supporting: TextSpan(
            text: custom
                ? l10n.providerTemplateCustom
                : '${template.baseUrl} · ${_kindLabel(l10n, template.kind)}',
          ),
          supportingMaxLines: 2,
          trailing: const KitChevron(),
          onTap: () => Navigator.of(sheetContext).pop(template),
        );
      },
    );
    if (template == null || !mounted) return;
    await _openForm(null, template: template);
  }

  String _kindLabel(AppLocalizations l10n, ProviderTemplateKind kind) =>
      switch (kind) {
        ProviderTemplateKind.official => l10n.providerTemplateOfficial,
        ProviderTemplateKind.gateway => l10n.providerTemplateGateway,
        ProviderTemplateKind.china => l10n.providerTemplateChina,
        ProviderTemplateKind.custom => l10n.providerTemplateCustom,
      };

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
      topBar: KitTopBar(
        title: l10n.providerManageTitle,
        subtitle: widget.controller.profile?.name,
        actions: [
          KitAction(
            key: const ValueKey('providers-add-top'),
            label: l10n.providerAddTitle,
            icon: AppIconography.add,
            onPressed: _loading ? null : _pickTemplate,
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
    if (catalogue.isEmpty) {
      return [
        gap,
        KitStateView(
          key: const ValueKey('providers-empty'),
          size: KitStateSize.inline,
          icon: AppIconography.model,
          title: l10n.providerManageEmpty,
          body: l10n.providerManageEmptyBody,
          primary: KitAction(
            key: const ValueKey('providers-add-empty'),
            label: l10n.providerAddTitle,
            icon: AppIconography.add,
            onPressed: () => _openForm(null),
          ),
        ),
      ];
    }
    return [
      gap,
      KitRowGroup(
        margin: EdgeInsets.zero,
        children: [
          for (final record in catalogue.records) _row(context, l10n, record),
          if (catalogue.unreadable > 0)
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
    ];
  }

  Widget _row(
    BuildContext context,
    AppLocalizations l10n,
    CustomProviderRecord record,
  ) {
    final tokens = KitTokens.of(context);
    final protocol = switch (record.protocol) {
      ProviderProtocol.chatCompletions => l10n.providerAddProtocolChat,
      ProviderProtocol.responses => l10n.providerAddProtocolResponses,
      ProviderProtocol.anthropic => l10n.providerAddProtocolAnthropic,
      ProviderProtocol.google => 'Google',
    };
    return KitRow(
      key: ValueKey('provider-row-${record.id}'),
      title: record.name,
      supporting: TextSpan(
        text: [
          record.id,
          protocol,
          l10n.providerManageModels(record.models.length),
        ].join(' · '),
      ),
      supportingMaxLines: 2,
      trailing: const KitChevron(),
      onTap: () => _openForm(record),
      menuLabel: l10n.providerManageMenu(record.name),
      menu: [
        KitMenuItem(
          key: ValueKey('provider-edit-${record.id}'),
          label: l10n.providerManageEdit,
          icon: AppIconography.edit,
          onSelected: () => _openForm(record),
        ),
        KitMenuItem(
          key: ValueKey('provider-test-${record.id}'),
          label: l10n.providerManageTest,
          icon: AppIconography.play,
          onSelected: () => _test(record),
        ),
        KitMenuItem(
          key: ValueKey('provider-delete-${record.id}'),
          label: l10n.providerManageDelete,
          icon: AppIconography.delete,
          destructive: true,
          onSelected: () => _delete(record),
        ),
      ],
      below: Padding(
        padding: EdgeInsetsDirectional.only(top: tokens.space1),
        child: Text(
          record.baseUrl,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: KitText.styleOf(context, KitTextRole.caption),
        ),
      ),
    );
  }
}
