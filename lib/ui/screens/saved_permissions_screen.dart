import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

import '../../domain/product_repository.dart';
import '../../state/connection.dart';
import '../permission_presentation.dart';
import '../widgets/product_states.dart' show productErrorText;
import '../app_theme.dart';
import '../kit/kit.dart';

typedef SavedPermissionRepositoryResolver =
    Future<ServerOperationsGateway?> Function();

/// Settings › Always allowed actions (`saved-permissions`): the actions the
/// agent may run in the current project without asking, each revocable
/// after a destructive confirmation (`saved-permissions-revoke-dialog`).
/// Built from kit parts only: a KitScreen page, one KitRowGroup of KitRows
/// (revoke as the row's one icon action and in its long-press menu), and
/// KitStateView for loading, empty and error.
class SavedPermissionsScreen extends StatefulWidget {
  const SavedPermissionsScreen({
    super.key,
    required this.controller,
    this.repositoryResolver,
  });

  final ConnectionController controller;
  final SavedPermissionRepositoryResolver? repositoryResolver;

  @override
  State<SavedPermissionsScreen> createState() => _SavedPermissionsScreenState();
}

class _SavedPermissionsScreenState extends State<SavedPermissionsScreen> {
  List<SavedPermission>? _permissions;
  final Set<String> _removing = {};
  bool _loading = false;
  String? _error;

  /// The action the last revoke took away, said in place of a snackbar
  /// (KIT-34: a snackbar is only done-with-undo, and the gateway has no way
  /// to put a revoked action back).
  String? _revoked;
  int _generation = 0;
  Object? _scope;

  Object get _currentScope {
    final profile = widget.controller.profile;
    return (
      widget.controller,
      profile?.id,
      profile?.baseUrl,
      profile?.username,
      widget.controller.directory,
      widget.controller.workspace,
      widget.controller.locationRevision,
      widget.controller.connectionRevision,
      widget.controller.repository,
    );
  }

  @override
  void initState() {
    super.initState();
    _scope = _currentScope;
    widget.controller.addListener(_scopeChanged);
    widget.controller.profileDataChanges.addListener(_scopeChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_scopeChanged);
    widget.controller.profileDataChanges.removeListener(_scopeChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SavedPermissionsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    oldWidget.controller.removeListener(_scopeChanged);
    oldWidget.controller.profileDataChanges.removeListener(_scopeChanged);
    widget.controller.addListener(_scopeChanged);
    widget.controller.profileDataChanges.addListener(_scopeChanged);
    _generation++;
    _scope = _currentScope;
    setState(() {
      _permissions = null;
      _loading = false;
      _error = null;
      _removing.clear();
    });
    unawaited(_load());
  }

  void _scopeChanged() {
    if (!mounted) return;
    final scope = _currentScope;
    if (scope == _scope) return;
    _scope = scope;
    _generation++;
    setState(() {
      _permissions = null;
      _loading = false;
      _error = null;
      _removing.clear();
    });
    unawaited(_load());
  }

  Future<ServerOperationsGateway?> _resolveRepository() =>
      widget.repositoryResolver?.call() ??
      widget.controller.prepareActionRepository();

  Future<void> _load() async {
    if (_loading || _removing.isNotEmpty) return;
    if (!mounted) return;
    final generation = ++_generation;
    final scope = _scope;
    setState(() {
      _loading = true;
      _error = null;
      _revoked = null;
    });
    try {
      final repository = await _resolveRepository();
      if (!mounted) return;
      if (repository == null) {
        throw ProductException(
          lookupAppLocalizations(
            Localizations.localeOf(context),
          ).e7LibraryOpenCodeIsReconnectingTryAgain,
        );
      }
      if (!mounted || generation != _generation || scope != _currentScope) {
        return;
      }
      final permissions = List<SavedPermission>.of(
        await repository.listSavedPermissions(),
      );
      if (!mounted || generation != _generation || scope != _currentScope) {
        return;
      }
      permissions.sort((a, b) {
        final action = a.action.compareTo(b.action);
        return action == 0 ? a.resource.compareTo(b.resource) : action;
      });
      setState(() => _permissions = permissions);
    } catch (error) {
      if (mounted && generation == _generation && scope == _currentScope) {
        setState(() => _error = productErrorText(error));
      }
    } finally {
      if (mounted && generation == _generation && scope == _currentScope) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _revoke(SavedPermission permission) async {
    final actionL10n = lookupAppLocalizations(Localizations.localeOf(context));
    if (_removing.contains(permission.id)) return;
    final scope = _scope;
    final resource = permission.resource.trim();
    final confirmed = await showKitConfirm(
      context,
      title: actionL10n.e7LibraryRevokeAlwaysAllowedAction,
      body: actionL10n.savedPermissionsRevokeBody,
      icon: AppIconography.privacy,
      confirmLabel: actionL10n.e7LibraryRevokeAccess,
      kind: KitConfirmKind.destructive,
      details: [
        KitTechnicalValue(
          actionL10n.e7LibraryAction,
          permissionRequestTitle(permission.action),
        ),
        KitTechnicalValue(
          actionL10n.e7LibraryResource,
          resource.isEmpty
              ? actionL10n.savedPermissionsAllResources
              : permission.resource,
        ),
      ],
    );
    if (!confirmed || !mounted || scope != _currentScope) return;

    setState(() {
      _removing.add(permission.id);
      _error = null;
      _revoked = null;
    });
    try {
      final repository = await _resolveRepository();
      if (!mounted) return;
      if (repository == null) {
        throw ProductException(
          actionL10n.e7LibraryOpenCodeIsReconnectingTryAgain,
        );
      }
      if (!mounted || scope != _currentScope) return;
      await repository.removeSavedPermission(permission.id);
      if (!mounted || scope != _currentScope) return;
      setState(() {
        _permissions = (_permissions ?? const [])
            .where((item) => item.id != permission.id)
            .toList();
        _revoked = permissionRequestTitle(permission.action);
      });
    } catch (error) {
      if (!mounted || scope != _currentScope) return;
      // Said once, on the list, next to the action that is still allowed.
      setState(() => _error = productErrorText(error));
    } finally {
      if (mounted && scope == _currentScope) {
        setState(() => _removing.remove(permission.id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = lookupAppLocalizations(Localizations.localeOf(context));
    final permissions = _permissions;
    final error = _error;
    final Widget body;
    if (permissions == null && error == null) {
      body = ListView(
        key: const ValueKey('saved-permissions-loading'),
        padding: KitScreen.padding(context),
        children: const [KitSkeletonRows()],
      );
    } else if (permissions == null || (permissions.isEmpty && error != null)) {
      body = KitStateView.error(
        key: const ValueKey('saved-permissions-error'),
        title: l10n.savedPermissionsLoadFailed,
        body: error,
        retry: KitAction(label: l10n.commonRetry, onPressed: _load),
      );
    } else if (permissions.isEmpty) {
      body = KitRefresh(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: KitScreen.padding(context),
          children: [
            if (_revoked case final revoked?) _revokedNotice(l10n, revoked),
            KitStateView(
              key: const ValueKey('saved-permissions-empty'),
              icon: AppIconography.privacy,
              title: l10n.e7LibraryNoAlwaysAllowedActions,
              body: l10n.emptyTeachAllowedMessage,
              size: KitStateSize.inline,
            ),
          ],
        ),
      );
    } else {
      final tokens = KitTokens.of(context);
      final rails = EdgeInsetsDirectional.symmetric(horizontal: tokens.gutter);
      body = KitRefresh(
        onRefresh: _load,
        child: ListView(
          key: const ValueKey('saved-permissions-list'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsetsDirectional.only(
            top: tokens.space2,
            bottom: KitScreen.endPadding(context),
          ),
          children: [
            // One Column: a short list, and every row laid out for the
            // keyboard and for a link that means one of them.
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // What the page is for, in one line (map infoMissing).
                Padding(
                  padding: rails,
                  child: KitText(
                    l10n.savedPermissionsIntro,
                    role: KitTextRole.secondary,
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: rails.add(
                      EdgeInsetsDirectional.only(top: tokens.space3),
                    ),
                    child: KitNotice.error(
                      key: const ValueKey('saved-permissions-action-error'),
                      title: l10n.e7LibraryTheLastActionFailed,
                      message: error,
                      retry: KitAction(
                        label: l10n.commonRetry,
                        onPressed: _load,
                      ),
                    ),
                  ),
                if (_revoked case final revoked?)
                  Padding(
                    padding: rails.add(
                      EdgeInsetsDirectional.only(top: tokens.space3),
                    ),
                    child: _revokedNotice(l10n, revoked),
                  ),
                // The label keeps the section gap from what is above; each
                // row is one action, so no count is repeated beside it.
                KitRowGroup(
                  key: const ValueKey('saved-permissions-group'),
                  label: l10n.usageCurrentProject,
                  children: [
                    for (final permission in permissions)
                      _permissionRow(l10n, permission),
                  ],
                ),
              ],
            ),
          ],
        ),
      );
    }
    return KitScreen(
      // Pull to refresh reloads the list; Try again lives in the error
      // states, so the top bar carries no refresh of its own.
      topBar: KitTopBar(title: l10n.e7LibraryAlwaysAllowedActions),
      width: KitScreenWidth.reading,
      loading: _loading && permissions != null,
      loadingLabel: l10n.savedPermissionsLoading,
      body: body,
    );
  }

  Widget _revokedNotice(AppLocalizations l10n, String revoked) => KitNotice(
    key: const ValueKey('saved-permissions-revoked'),
    tone: AppStatusTone.ok,
    icon: AppIconography.check,
    title: l10n.e7LibraryAlwaysAllowedActionRevoked,
    message: l10n.savedPermissionsRevokedDetail(revoked),
    onDismiss: () => setState(() => _revoked = null),
    dismissLabel: l10n.savedPermissionsDismiss,
  );

  Widget _permissionRow(AppLocalizations l10n, SavedPermission permission) {
    final title = permissionRequestTitle(permission.action);
    final resource = permission.resource.trim();
    final removing = _removing.contains(permission.id);
    return KitRow(
      key: ValueKey('saved-permission-${permission.id}'),
      leading: KitRow.icon(context, AppIconography.privacy),
      title: title,
      // "All matching resources" is the app's sentence, so it is plain
      // text; a real pattern is a technical value, left to right and mono.
      supporting: resource.isEmpty
          ? TextSpan(text: l10n.savedPermissionsAllResources)
          : null,
      below: resource.isEmpty
          ? null
          : KitText.mono(permission.resource, maxLines: 3, selectable: true),
      trailing: KitIconButton(
        key: ValueKey('revoke-saved-permission-${permission.id}'),
        icon: AppIconography.delete,
        tooltip: l10n.e7LibraryRevokeAccess2(title),
        destructive: true,
        working: removing,
        onPressed: removing ? null : () => _revoke(permission),
      ),
      menu: [
        if (resource.isNotEmpty)
          KitMenuItem.copy(
            label: l10n.savedPermissionsCopyPattern,
            text: () => permission.resource,
          ),
        KitMenuItem(
          label: l10n.e7LibraryRevokeAccess,
          icon: AppIconography.delete,
          destructive: true,
          enabled: !removing,
          disabledReason: removing ? l10n.savedPermissionsBusy : null,
          onSelected: () => _revoke(permission),
        ),
      ],
      menuLabel: title,
    );
  }
}
