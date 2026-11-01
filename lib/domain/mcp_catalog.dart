import 'server_gateway.dart';
import 'setup_registry.dart';

/// What a catalogue server needs on the machine that runs it.
enum McpCatalogRuntime {
  /// Someone else hosts it; the server only connects to its address.
  hosted,

  /// An npm package started with `npx` (Node).
  node,

  /// A PyPI package started with `uvx` (Python with uv).
  python,

  /// A container image (Docker). The catalogue does not add these.
  docker,

  /// No address or package the app can use.
  none,
}

/// One registry listing as the MCP catalogue shows it (P2.5): a toggle row
/// with what it is, where it runs and what it needs, and the draft the
/// manual form opens with when it is turned on.
///
/// Registry text is untrusted: [title] and [description] are plain text
/// (already redacted by [RegistryEntry]); the draft holds only validated
/// identifiers, an HTTPS address without credentials, and variable *names*
/// with empty values. Nothing here is saved or run: turning a row on opens
/// the same form, and the same Save, as entering a server by hand.
class McpCatalogItem {
  const McpCatalogItem._({
    required this.entry,
    required this.serverName,
    required this.runtime,
    this.draft,
    this.hostedBy,
    this.needsKey = false,
    this.needsSettings = false,
  });

  final RegistryEntry entry;

  /// The MCP server name the form suggests, and the name the catalogue
  /// looks for in the server's list to show the row as on.
  final String serverName;
  final McpCatalogRuntime runtime;

  /// The form's starting point; null when the catalogue cannot add it
  /// ([runtime] is docker or none).
  final McpServerDraft? draft;

  /// The host of a hosted server's address.
  final String? hostedBy;

  /// The listing declares a required secret (an API key or token).
  final bool needsKey;

  /// The listing declares other required settings or arguments.
  final bool needsSettings;

  String get title => entry.title.isNotEmpty ? entry.title : serverName;
  String get description => entry.description;
  bool get addable => draft != null;

  static McpCatalogItem from(RegistryEntry entry) {
    final name = catalogServerName(entry.name);
    final remote = entry.connectableRemote ?? entry.remotes.firstOrNull;
    if (remote != null) {
      final declared = remote.headers;
      // Only required names become rows the form insists on; the person
      // can add any optional header by hand.
      final headers = declared.where((h) => h.required);
      return McpCatalogItem._(
        entry: entry,
        serverName: name,
        runtime: McpCatalogRuntime.hosted,
        hostedBy: Uri.tryParse(remote.url)?.host,
        needsKey: declared.any((h) => h.secret && h.required),
        needsSettings:
            declared.any((h) => h.required && !h.secret) ||
            (remote.requiresConfiguration && declared.isEmpty),
        draft: McpServerDraft(
          name: name,
          kind: McpServerKind.remote,
          url: remote.url,
          headers: {for (final header in headers) header.name: ''},
        ),
      );
    }
    final package = _runnable(entry.packages);
    if (package == null) {
      final docker = entry.packages.any((p) => p.registryType == 'oci');
      return McpCatalogItem._(
        entry: entry,
        serverName: name,
        runtime: docker ? McpCatalogRuntime.docker : McpCatalogRuntime.none,
      );
    }
    final node = package.registryType == 'npm';
    final environment = package.environment.where((v) => v.required);
    return McpCatalogItem._(
      entry: entry,
      serverName: name,
      runtime: node ? McpCatalogRuntime.node : McpCatalogRuntime.python,
      needsKey: environment.any((v) => v.secret),
      needsSettings:
          package.requiresArguments || environment.any((v) => !v.secret),
      draft: McpServerDraft(
        name: name,
        kind: McpServerKind.local,
        command: node
            ? ['npx', '-y', '${package.identifier}@${package.version}']
            : ['uvx', '${package.identifier}==${package.version}'],
        environment: {for (final variable in environment) variable.name: ''},
      ),
    );
  }

  /// The first package the catalogue can start: npm or PyPI over stdio.
  static RegistryPackage? _runnable(List<RegistryPackage> packages) => packages
      .where(
        (p) =>
            (p.registryType == 'npm' || p.registryType == 'pypi') &&
            (p.transport == null || p.transport == 'stdio'),
      )
      .firstOrNull;
}

/// The MCP server name for registry listing [registryName]
/// (`io.github.acme/weather-mcp` → `weather-mcp`): its last path segment,
/// or, when that is only a generic word (`mcp`, `mcp-server`), its
/// namespace without the reversed-domain prefix (`ac.inference.sh/mcp` →
/// `inference-sh`). Lower case; anything but letters, digits, `-` and `_`
/// becomes `-`; at most 64 characters.
String catalogServerName(String registryName) {
  String clean(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_-]+'), '-')
      .replaceAll(RegExp(r'-{2,}'), '-')
      .replaceAll(RegExp(r'^[-_]+|[-_]+$'), '');
  final parts = registryName.split('/').where((s) => s.isNotEmpty).toList();
  var name = clean(parts.lastOrNull ?? registryName);
  if (parts.length > 1 && _genericNames.contains(name)) {
    final labels = parts.first
        .split('.')
        .where((label) => !_namespacePrefixes.contains(label.toLowerCase()))
        .toList();
    final namespace = clean(labels.join('-'));
    if (namespace.isNotEmpty) name = namespace;
  }
  if (name.length > 64) name = name.substring(0, 64);
  return name.isEmpty ? 'mcp-server' : name;
}

const _genericNames = {'mcp', 'mcp-server', 'mcpserver', 'server', 'remote'};
const _namespacePrefixes = {
  'io',
  'com',
  'ai',
  'ac',
  'dev',
  'app',
  'org',
  'net',
  'co',
  'github',
  'gitlab',
  'www',
};

/// The catalogue's rows in the page's order: the ones already on this
/// server first, then those it can add, then those it cannot (one list,
/// most useful first). Within each group the registry's own order holds.
List<McpCatalogItem> orderCatalog(
  Iterable<RegistryEntry> entries, {
  required Set<String> installed,
}) {
  final items = entries.map(McpCatalogItem.from).toList();
  int rank(McpCatalogItem item) => installed.contains(item.serverName)
      ? 0
      : item.addable
      ? 1
      : 2;
  final indexed = items.indexed.toList()
    ..sort((a, b) {
      final byRank = rank(a.$2).compareTo(rank(b.$2));
      return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
    });
  return [for (final (_, item) in indexed) item];
}
