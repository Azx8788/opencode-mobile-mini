/// App-authored installation metadata, separate from runtime qualification.
/// A pinned download never proves sign-in, resume, or phone compatibility.
library;

enum AgentRoute { opencode2, paseoNative, acpPaseo }

enum AgentArchitecture { arm64, x64 }

enum AgentArtifactFormat { executable, tarGz, tarBz2, zip, npmTarGz }

enum AgentSignInMethod { browserOAuthHost, apiKeyHost, none }

enum AgentAvailability { available, limited, hidden }

const agentResumeUnverifiedLabel = "Can't reopen old chats";
const agentStartsNewChatNote = 'Starts a new chat';

enum AgentUnavailableReason {
  recipeUnverified,
  dependencyClosureUnverified,
  unsupportedArchitecture,
}

/// Proof obtained for the selected runtime, never inferred from agent identity.
final class AgentCapabilities {
  const AgentCapabilities({
    this.resumeVerified = false,
    this.modelList = false,
    this.permissions = false,
    this.images = false,
    this.cancel = false,
  });

  final bool resumeVerified;
  final bool modelList;
  final bool permissions;
  final bool images;
  final bool cancel;
}

final class AgentArtifact {
  AgentArtifact({
    required this.url,
    required this.sha256,
    required this.format,
    this.archiveMember,
    this.downloadBytes,
    this.installedBytes,
  }) {
    if (url.scheme != 'https' ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        url.hasFragment) {
      throw ArgumentError('Artifact URL must be HTTPS without credentials.');
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw ArgumentError('Artifact needs an exact lowercase SHA-256 pin.');
    }
    if (format == AgentArtifactFormat.executable) {
      if (archiveMember != null) {
        throw ArgumentError('Executable artifacts have no archive member.');
      }
    } else if (archiveMember == null || !_safeMember(archiveMember!)) {
      throw ArgumentError('Archive artifacts need a safe relative member.');
    }
    if ((downloadBytes != null && downloadBytes! <= 0) ||
        (installedBytes != null && installedBytes! <= 0)) {
      throw ArgumentError('Known artifact sizes must be positive.');
    }
  }

  final Uri url;
  final String sha256;
  final AgentArtifactFormat format;

  /// Entrypoint to copy for simple archives. For npmTarGz preserve the ENTIRE
  /// package tree and invoke this member with the separately pinned host Node.
  final String? archiveMember;
  final int? downloadBytes;

  /// Payload size, not a promise about total disk use or peak install space.
  /// Null means unknown; never substitute a made-up estimate.
  final int? installedBytes;

  static bool _safeMember(String value) {
    final normalized = value.startsWith('./') ? value.substring(2) : value;
    return normalized.isNotEmpty &&
        !normalized.startsWith('/') &&
        !normalized.contains('\\') &&
        !normalized.contains('\u0000') &&
        normalized
            .split('/')
            .every((part) => part.isNotEmpty && part != '.' && part != '..');
  }
}

final class AgentInstallRecipe {
  AgentInstallRecipe({
    required this.version,
    required this.executable,
    required Map<AgentArchitecture, AgentArtifact> artifacts,
    List<String> launchArgs = const [],
    List<String> signInArgs = const [],
  }) : artifacts = Map.unmodifiable(artifacts),
       launchArgs = List.unmodifiable(launchArgs),
       signInArgs = List.unmodifiable(signInArgs) {
    if (version.trim().isEmpty ||
        !RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(executable) ||
        artifacts.isEmpty) {
      throw ArgumentError('Recipe needs a version, executable, and artifact.');
    }
    if ([...launchArgs, ...signInArgs].any((arg) => arg.contains('\u0000'))) {
      throw ArgumentError('Arguments cannot contain NUL.');
    }
  }

  final String version;
  final String executable;
  final Map<AgentArchitecture, AgentArtifact> artifacts;

  /// Argument arrays are data, never shell fragments. ACP provider config uses
  /// executable + launchArgs; Paseo native providers own their launch protocol.
  final List<String> launchArgs;

  /// Empty means interactive host setup; it does not mean no authentication.
  final List<String> signInArgs;
}

final class AgentDescriptor {
  AgentDescriptor({
    required this.id,
    required this.name,
    required this.iconKey,
    required this.route,
    required this.providerId,
    required this.signInMethod,
    this.recipe,
    this.capabilities = const AgentCapabilities(),
    this.availability = AgentAvailability.limited,
    this.unavailableReason,
    this.limitation,
    this.resumeReason,
  }) {
    if (!RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(id) ||
        providerId.trim().isEmpty ||
        name.trim().isEmpty ||
        iconKey.trim().isEmpty) {
      throw ArgumentError('Agent identity must be nonempty and stable.');
    }
    if ((recipe == null || availability == AgentAvailability.hidden) &&
        unavailableReason == null) {
      throw ArgumentError('An unavailable agent needs an explicit reason.');
    }
    if (availability != AgentAvailability.hidden && unavailableReason != null) {
      throw ArgumentError('Unavailable agents must be hidden.');
    }
    if (!capabilities.resumeVerified &&
        (resumeReason?.trim().isEmpty ?? true)) {
      throw ArgumentError('Unverified resume needs a plain explanation.');
    }
    if (availability == AgentAvailability.limited &&
        (limitation?.trim().isEmpty ?? true)) {
      throw ArgumentError('Limited agents need a plain explanation.');
    }
  }

  final String id;
  final String name;
  final String iconKey;
  final AgentRoute route;
  final String providerId;
  final AgentSignInMethod signInMethod;
  final AgentInstallRecipe? recipe;
  final AgentCapabilities capabilities;
  final AgentAvailability availability;
  final AgentUnavailableReason? unavailableReason;
  final String? limitation;
  final String? resumeReason;

  String? get resumeLabel =>
      capabilities.resumeVerified ? null : agentResumeUnverifiedLabel;
  String? get resumeNote =>
      capabilities.resumeVerified ? null : agentStartsNewChatNote;

  AgentArtifact? artifactFor(AgentArchitecture architecture) =>
      recipe?.artifacts[architecture];

  /// Installation availability does not make this agent selectable for chat.
  bool installableOn(AgentArchitecture architecture) =>
      unavailableReason == null && artifactFor(architecture) != null;
}

final class AgentCatalog {
  AgentCatalog({required List<AgentDescriptor> agents})
    : agents = List.unmodifiable(agents) {
    if (agents.map((agent) => agent.id).toSet().length != agents.length) {
      throw ArgumentError('Agent IDs must be unique.');
    }
  }

  final List<AgentDescriptor> agents;

  AgentDescriptor? byId(String id) {
    for (final agent in agents) {
      if (agent.id == id) return agent;
    }
    return null;
  }

  static final AgentCatalog builtIn = _builtInCatalog();
}

AgentCatalog _builtInCatalog() {
  AgentArtifact binary(String url, String hash, int bytes) => AgentArtifact(
    url: Uri.parse(url),
    sha256: hash,
    format: AgentArtifactFormat.executable,
    downloadBytes: bytes,
    installedBytes: bytes,
  );
  AgentArtifact archive(
    String url,
    String hash,
    String member, {
    int? bytes,
    int? installedBytes,
    AgentArtifactFormat format = AgentArtifactFormat.tarGz,
  }) => AgentArtifact(
    url: Uri.parse(url),
    sha256: hash,
    format: format,
    archiveMember: member,
    downloadBytes: bytes,
    installedBytes: installedBytes,
  );
  AgentDescriptor entry(
    String id,
    String name,
    AgentRoute route,
    String providerId,
    AgentSignInMethod signIn,
    AgentInstallRecipe recipe, {
    String? limitation,
  }) => AgentDescriptor(
    id: id,
    name: name,
    iconKey: id,
    route: route,
    providerId: providerId,
    signInMethod: signIn,
    recipe: recipe,
    limitation: limitation ?? 'Needs a check on your phone before use.',
    resumeReason: agentResumeUnverifiedLabel,
  );

  const github = 'https://github.com';
  return AgentCatalog(
    agents: [
      entry(
        'opencode2',
        'OpenCode 2',
        AgentRoute.opencode2,
        'opencode',
        AgentSignInMethod.apiKeyHost,
        AgentInstallRecipe(
          version: '2.1.1',
          executable: 'opencode',
          artifacts: {
            AgentArchitecture.arm64: archive(
              'https://registry.npmjs.org/@opencode/cli-linux-arm64/-/cli-linux-arm64-2.1.1.tgz',
              'cfa3ae6363fc3082f03072297069d81f53559a761371fdb4b56fe6bfa01ca066',
              'package/bin/opencode',
            ),
            AgentArchitecture.x64: archive(
              'https://registry.npmjs.org/@opencode/cli-linux-x64-baseline/-/cli-linux-x64-baseline-2.1.1.tgz',
              '216d3861d0a167adad5850282439bae13483203f4b110f0510f260118bba2858',
              'package/bin/opencode',
            ),
          },
          launchArgs: ['serve', '--hostname', '127.0.0.1'],
        ),
      ),
      entry(
        'claude',
        'Claude Code',
        AgentRoute.paseoNative,
        'claude',
        AgentSignInMethod.browserOAuthHost,
        AgentInstallRecipe(
          version: '2.1.294',
          executable: 'claude',
          artifacts: {
            AgentArchitecture.arm64: binary(
              'https://downloads.claude.ai/claude-code-releases/2.1.294/linux-arm64/claude',
              'e5d2df19f30a6d63bf11188121f7edb2775249b57352a69269509a4b1496e763',
              252108792,
            ),
            AgentArchitecture.x64: binary(
              'https://downloads.claude.ai/claude-code-releases/2.1.294/linux-x64/claude',
              '27122ca7b624f537546fbef35b80c66370d974ff258f3d9b10ac50bb8771f262',
              252755128,
            ),
          },
          signInArgs: ['auth', 'login', '--claudeai'],
        ),
      ),
      entry(
        'codex',
        'Codex',
        AgentRoute.paseoNative,
        'codex',
        AgentSignInMethod.browserOAuthHost,
        AgentInstallRecipe(
          version: '0.162.1',
          executable: 'codex',
          artifacts: {
            AgentArchitecture.arm64: archive(
              '$github/openai/codex/releases/download/rust-v0.162.1/codex-aarch64-unknown-linux-musl.tar.gz',
              'bf3ca2719f1143b1440fbd85c149379e696c782c50ad7991f8bfcec60b2600c1',
              'codex-aarch64-unknown-linux-musl',
              bytes: 103595962,
              installedBytes: 254866040,
            ),
            AgentArchitecture.x64: archive(
              '$github/openai/codex/releases/download/rust-v0.162.1/codex-x86_64-unknown-linux-musl.tar.gz',
              '86f268d81b898f3e144c5ecff2ad2fda2c5802e042d6195b72538fe0fa125057',
              'codex-x86_64-unknown-linux-musl',
              bytes: 111350218,
              installedBytes: 294415048,
            ),
          },
          launchArgs: ['app-server'],
          signInArgs: ['login', '--device-auth'],
        ),
      ),
    ],
  );
}
