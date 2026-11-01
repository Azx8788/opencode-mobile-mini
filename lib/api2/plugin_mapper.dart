import '../domain/plugin_inventory.dart';

/// The plugin endpoint includes raw loader errors and installation sources.
/// Retain only bounded display IDs, source kinds and npm package identifiers.
PluginInfo mapPluginInfo(Map<dynamic, dynamic> value) {
  final source = value['source'];
  // The beta reported `status` and `tui` on the row. The stable line (2.0.4
  // and later) nests them: `state.status`, and `features.tui` beside
  // `features.server`, with an absent feature meaning false.
  final state = value['state'];
  final features = value['features'];
  final status = value['status'] ?? (state is Map ? state['status'] : null);
  final tui =
      value['tui'] ?? (features is Map ? features['tui'] ?? false : null);
  if (source is! Map ||
      source['type'] is! String ||
      status is! String ||
      tui is! bool) {
    throw const FormatException('Invalid plugin metadata');
  }
  final rawID = value['id'];
  final id =
      rawID is String &&
          rawID.length <= 200 &&
          RegExp(r'^@?[A-Za-z0-9][A-Za-z0-9_./@-]*$').hasMatch(rawID)
      ? rawID
      : null;
  final package = source['package'];
  final packageName =
      package is String &&
          package.length <= 200 &&
          RegExp(
            r'^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*(?:@[A-Za-z0-9][A-Za-z0-9._+-]*)?$',
          ).hasMatch(package)
      ? package
      : null;
  final kind = switch (source['type']) {
    'builtin' => PluginSourceKind.builtin,
    'package' => PluginSourceKind.package,
    'local' => PluginSourceKind.local,
    'sdk' => PluginSourceKind.sdk,
    _ => PluginSourceKind.unknown,
  };
  return PluginInfo(
    id: id,
    status: switch (status) {
      'active' => PluginStatus.active,
      'failed' => PluginStatus.failed,
      _ => PluginStatus.unknown,
    },
    source: kind,
    packageName: kind == PluginSourceKind.package ? packageName : null,
    terminalUi: tui,
  );
}
