// Part of library_screen.dart — custom supplier section.
part of '../library_screen.dart';

extension _IntegrationsCustomSection on _IntegrationsScreenState {
  List<Widget> _customSupplierSection(BuildContext context) {
    final l = _l10n;
    final show = _showProviders && BuiltinLinux.supported &&
        BuiltinLinux.managesServerUrl(widget.controller.profile?.baseUrl);
    if (!show) return const [];

    return [
      const SizedBox(height: 8),
      _railed(
        Row(children: [
          Expanded(child: Text(l.customSupplierTitle, style: Theme.of(context).textTheme.titleMedium)),
          if (_catalogAvailable)
            KitButton.tertiary(
              key: const ValueKey('add-custom-supplier'),
              label: l.customSupplierAdd,
              icon: AppIconography.add,
              onPressed: _openCustomSupplierAdd,
            ),
        ]),
      ),
      if (_customSuppliers.isNotEmpty)
        KitRowGroup(
          label: l.customSupplierTitle,
          children: [
            for (final s in _customSuppliers)
              _CustomSupplierRow(
                supplier: s,
                onTap: () => _openCustomSupplierEdit(s.id),
                onDelete: () => _deleteCustomSupplier(s.id),
              ),
          ],
        ),
    ];
  }

  List<CustomSupplierSummary> get _customSuppliers {
    final all = widget.controller.catalog?.customProviders ?? const [];
    return all.where((p) => !reservedCustomProviderIds.contains(p.id)).toList();
  }

  void _openCustomSupplierAdd() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CustomProviderScreen(
        onSaved: (id, isNew) => _onCustomSaved(id, isNew),
      ),
    ));
  }

  void _openCustomSupplierEdit(String id) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CustomProviderScreen(
        initialId: id,
        onSaved: (id, _) => _onCustomSaved(id, false),
      ),
    ));
  }

  void _onCustomSaved(String id, bool isNew) async {
    if (!mounted) return;
    _say(isNew ? l.customSupplierSaved : l.customSupplierUpdated, brief: true);
    widget.controller.refreshCatalog();
    await Future.delayed(const Duration(seconds: 1));
    if (mounted) setState(() {});
  }

  void _deleteCustomSupplier(String id) {}
}

class _CustomSupplierRow extends StatelessWidget {
  const _CustomSupplierRow({required this.supplier, required this.onTap, required this.onDelete});
  final CustomSupplierSummary supplier;
  final VoidCallback onTap, onDelete;

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    return ListTile(
      leading: ProviderLogo(supplier.id, size: tokens.avatarTile),
      title: Text(supplier.name),
      subtitle: Text('${supplier.models.length} models · ${supplier.baseUrl}'),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(icon: const Icon(Icons.edit), onPressed: onTap),
        IconButton(icon: const Icon(Icons.delete), onPressed: onDelete),
      ]),
      onTap: onTap,
      contentPadding: EdgeInsets.symmetric(horizontal: tokens.gutter),
    );
  }
}
