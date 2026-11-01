import '../../domain/termux_migration.dart';
import '../../state/connection.dart';
import '../../state/profiles.dart';
import '../../termux/bridge.dart';
import '../builtin_linux.dart';
import '../builtin_server.dart';

/// Finishes an already verified import without retiring its Termux profile.
/// Session IDs are not portable: pins, drafts and queued prompts stay with
/// their original profile. Moving queued prompts is a separate, explicit use
/// of ConnectionController.moveQueuedPrompts after connecting successfully.
class TermuxMigrationProfileSwitcher {
  factory TermuxMigrationProfileSwitcher({
    required ConnectionController connection,
    required String builtinProfileName,
    BuiltinLinux? linux,
  }) {
    final runtime = linux ?? BuiltinLinux();
    return TermuxMigrationProfileSwitcher.withCallbacks(
      store: connection.store,
      ensureProfile: (flavor) => ensureBuiltinProfile(
        connection.store,
        flavor: flavor,
        name: builtinProfileName,
      ),
      start: (profile, stillWanted) async =>
          await startBuiltinServer(
            linux: runtime,
            profile: profile,
            stillWanted: stillWanted,
          ) ==
          null,
      connect: connection.connect,
      isConnectedTo: (profile) =>
          connection.isConnected && connection.profile?.id == profile.id,
      selectedProfileId: () => connection.profile?.id,
    );
  }

  /// Seams for testing the existing profile/start/connection APIs without
  /// invoking Android, a server, or secure storage.
  TermuxMigrationProfileSwitcher.withCallbacks({
    required this.store,
    required Future<ServerProfile> Function(ServerFlavor flavor) ensureProfile,
    required Future<bool> Function(
      ServerProfile profile,
      bool Function() stillWanted,
    )
    start,
    required Future<void> Function(ServerProfile profile) connect,
    required bool Function(ServerProfile profile) isConnectedTo,
    required String? Function() selectedProfileId,
  }) : _ensureProfile = ensureProfile,
       _start = start,
       _connect = connect,
       _isConnectedTo = isConnectedTo,
       _selectedProfileId = selectedProfileId;

  final ProfileStore store;
  final Future<ServerProfile> Function(ServerFlavor) _ensureProfile;
  final Future<bool> Function(ServerProfile, bool Function()) _start;
  final Future<void> Function(ServerProfile) _connect;
  final bool Function(ServerProfile) _isConnectedTo;
  final String? Function() _selectedProfileId;
  bool _switching = false;

  /// [verifiedProjectPaths] maps imported source roots to their verified
  /// /root/projects destinations. The caller must finish archive verification
  /// before invoking this method. No other source location follows the switch.
  Future<String> switchProfile({
    required String sourceProfileId,
    required bool Function() stillWanted,
    required Map<String, String> verifiedProjectPaths,
  }) async {
    if (_switching) {
      throw const TermuxMigrationException(
        TermuxMigrationFailure.profileSwitch,
      );
    }
    _switching = true;
    ServerProfile? source;
    ServerProfile? destination;
    final selectedBefore = _selectedProfileId();
    try {
      _wanted(stillWanted);
      source = _profile(sourceProfileId);
      if (source == null ||
          source.backend != ServerBackend.openCode ||
          source.baseUrl != TermuxBridge.managedServerUrl) {
        throw const TermuxMigrationException(
          TermuxMigrationFailure.invalidSelection,
        );
      }
      final mappedDirectory = _mappedDirectory(
        store.locationFor(source.id)?.directory,
        verifiedProjectPaths,
      );
      destination = await _ensureProfile(source.flavor);
      _wanted(stillWanted);
      if (destination.id == source.id ||
          destination.backend != ServerBackend.openCode ||
          destination.flavor != source.flavor ||
          !BuiltinLinux.managesServerUrl(destination.baseUrl) ||
          _profile(source.id) == null ||
          _profile(destination.id) == null) {
        throw const TermuxMigrationException(
          TermuxMigrationFailure.profileSwitch,
        );
      }
      if (mappedDirectory != null) {
        // Workspace IDs belong to the old server and must never follow.
        await store.setLocation(destination.id, directory: mappedDirectory);
      }
      _wanted(stillWanted);
      if (!await _start(destination, stillWanted)) {
        _wanted(stillWanted);
        throw const TermuxMigrationException(
          TermuxMigrationFailure.profileSwitch,
        );
      }
      _wanted(stillWanted);
      if (_selectedProfileId() != selectedBefore) {
        throw const TermuxMigrationException(
          TermuxMigrationFailure.profileSwitch,
        );
      }
      await _connect(destination);
      _wanted(stillWanted);
      if (!_isConnectedTo(destination)) {
        throw const TermuxMigrationException(
          TermuxMigrationFailure.profileSwitch,
        );
      }
      return destination.id;
    } catch (error) {
      // Restore only a selection this operation displaced. A simultaneous
      // user selection wins. Never remove either profile on a partial switch.
      if (source != null &&
          destination != null &&
          selectedBefore == source.id &&
          _selectedProfileId() == destination.id &&
          _profile(source.id) != null) {
        try {
          await _connect(source);
        } catch (_) {
          // The saved source remains available even if it cannot reconnect.
        }
      }
      if (error is TermuxMigrationException) rethrow;
      // Underlying connection/storage exceptions can include credentials.
      throw const TermuxMigrationException(
        TermuxMigrationFailure.profileSwitch,
      );
    } finally {
      _switching = false;
    }
  }

  ServerProfile? _profile(String id) {
    for (final profile in store.profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  static void _wanted(bool Function() stillWanted) {
    if (!stillWanted()) {
      throw const TermuxMigrationException(TermuxMigrationFailure.cancelled);
    }
  }

  static bool _absolutePath(String path) =>
      path.startsWith('/') &&
      !path.contains('\u0000') &&
      !path.contains('\\') &&
      !path
          .split('/')
          .skip(1)
          .any((part) => part.isEmpty || part == '.' || part == '..');

  static String? _mappedDirectory(
    String? directory,
    Map<String, String> mappings,
  ) {
    for (final entry in mappings.entries) {
      if (!_absolutePath(entry.key) ||
          !_absolutePath(entry.value) ||
          !(entry.value == '/root/projects' ||
              entry.value.startsWith('/root/projects/'))) {
        throw const TermuxMigrationException(
          TermuxMigrationFailure.invalidSelection,
        );
      }
    }
    if (directory == null || !_absolutePath(directory)) return null;
    final roots = mappings.keys.toList()
      ..sort((left, right) => right.length.compareTo(left.length));
    for (final root in roots) {
      if (directory == root || directory.startsWith('$root/')) {
        return '${mappings[root]}${directory.substring(root.length)}';
      }
    }
    return null;
  }
}
