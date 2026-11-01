import '../ui/kit/kit_redact.dart';

/// Independent of transport flavor. False means the UI must show [reason].
class SetupSupport {
  const SetupSupport({
    this.readConfig = false,
    this.writeConfig = false,
    this.mcpInventory = false,
    this.assistant = false,
    this.reason = 'This server does not expose setup configuration APIs.',
  });
  final bool readConfig;

  /// Requires the atomic transaction facet. Production adapters keep this false.
  final bool writeConfig;
  final bool mcpInventory;

  /// A server-enforced, proposal-only assistant, not ordinary chat access.
  final bool assistant;
  final String reason;
}

enum SetupFailureCode {
  offline,
  unsupported,
  needsSignIn,
  invalid,
  conflict,
  storage,
  transport,
  busy,
  uncertain,
}

class SetupFailure implements Exception {
  const SetupFailure(this.code, this.message);
  final SetupFailureCode code;

  /// Adapter/controller-authored copy only. Never include response bodies.
  final String message;
  @override
  String toString() => 'SetupFailure(${code.name})';
}

/// Raw transport boundary, for controllers only; UI uses SetupController.
/// Never persist, log, or display the returned raw configuration.
abstract interface class SetupConfigGateway {
  SetupSupport get support;
  Future<Map<String, Object?>> readConfig();
  Future<void> patchConfig(Map<String, Object?> patch);
  Future<List<SetupMcpStatus>> listMcpServers();
}

/// Optional host transaction contract. Never emulate this with GET plus PATCH.
/// The host binds immutable source identity and atomically compares [expected]
/// before committing all edits. Conflict means no write occurred. Snapshots
/// include exact source values (including absence), not merged effective config.
/// Disabled MCP definition transactions must not start connections or change
/// authentication state. Runtime-only MCP mutation is not this contract.
/// Restore consumes a host-owned handle and conditionally restores the exact
/// original source against commit.after; credentials never return in edits.
/// Implementations must not log snapshots, receipts, handles or response bodies.
abstract interface class SetupTransactionalConfigGateway
    implements SetupConfigGateway {
  Future<SetupConfigRevision> readSnapshot();
  Future<SetupConfigCommit> commit({
    required SetupConfigRevision expected,
    required List<SetupEdit> edits,
    required String operationId,
  });
  Future<SetupConfigCommit> restore({
    required SetupConfigCommit commit,
    required String operationId,
  });
}

/// Raw controller-only source snapshot. Never expose to UI or persistence.
class SetupConfigRevision {
  SetupConfigRevision({
    required this.targetId,
    required this.revision,
    required Map<String, Object?> config,
  }) : config = _freezeSetup(config) as Map<String, Object?>;
  final String targetId;
  final String revision;
  final Map<String, Object?> config;
}

/// Raw memory-only receipt. The opaque restore handle remains on this boundary.
class SetupConfigCommit {
  const SetupConfigCommit({
    required this.before,
    required this.after,
    required this.undoHandle,
  });
  final SetupConfigRevision before;
  final SetupConfigRevision after;
  final String undoHandle;
}

Object? _freezeSetup(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key as String: _freezeSetup(entry.value),
    });
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_freezeSetup));
  return value;
}

class SetupMcpStatus {
  const SetupMcpStatus({required this.name, required this.status});
  final String name;

  /// connected/pending/disabled/failed/needs_auth/unknown. No error bodies.
  final String status;
}

/// Input only. Never render this object directly; render SetupDiff instead.
class SetupEdit {
  const SetupEdit({required this.path, this.value, this.remove = false});
  final List<String> path;
  final Object? value;
  final bool remove;
}

class SetupDiff {
  SetupDiff({
    required List<String> path,
    required Object? before,
    required Object? after,
    required this.remove,
    this.beforePresent = true,
    this.afterPresent = true,
  }) : path = List.unmodifiable(path.map(KitRedact.text)),
       before = setupRedact(before),
       after = setupRedact(after);
  final List<String> path;
  final Object? before;
  final Object? after;
  final bool beforePresent;
  final bool afterPresent;
  final bool remove;
}

class SetupProposal {
  SetupProposal({
    required this.id,
    required List<SetupDiff> changes,
    required this.canApply,
    required this.reason,
  }) : changes = List.unmodifiable(changes);
  final String id;
  final List<SetupDiff> changes;
  final bool canApply;
  final String? reason;

  /// Any change may affect future sessions; never claim an automatic restart.
  String get effect =>
      'Runtime activation is not verified. Recheck server status after a change.';
}

enum SetupPhase {
  idle,
  loading,
  applying,
  verifying,
  undoing,
  uncertain,
  ready,
  empty,
  offline,
  unsupported,
  needsSignIn,
  error,
}

class SetupSnapshot {
  const SetupSnapshot({
    this.phase = SetupPhase.idle,
    this.config = const {},
    this.servers = const [],
    this.proposal,
    this.reason,
    this.canUndo = false,
  });
  final SetupPhase phase;
  final Map<String, Object?> config;
  final List<SetupMcpStatus> servers;
  final SetupProposal? proposal;
  final String? reason;
  final bool canUndo;
}

/// Structural redaction complements KitRedact: arbitrary env/header values,
/// provider credentials and free-form executable/prompt bodies are hidden even
/// when they do not resemble a known credential. Immutable output is UI-safe.
Object? setupRedact(Object? value, [String key = '']) {
  if (RegExp(
    r'key|token|secret|password|credential|environment|headers|options|request|command|template|prompt|system|content',
    caseSensitive: false,
  ).hasMatch(key)) {
    return KitRedact.mask;
  }
  if (value is Map) {
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        KitRedact.text(entry.key.toString()): setupRedact(
          entry.value,
          entry.key.toString(),
        ),
    });
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map((v) => setupRedact(v, key)));
  }
  if (value is String) return KitRedact.text(value);
  if (value == null || value is bool || value is num) return value;
  return KitRedact.mask;
}
