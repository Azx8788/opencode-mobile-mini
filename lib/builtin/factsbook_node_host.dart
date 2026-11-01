import 'dart:convert';
import 'abi_shim.dart';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'builtin_linux.dart';

/// Why a step of running the FactsBook node on this phone failed. The page
/// words it; [detail] is technical text for Details only and never holds the
/// passphrase or a pairing code.
enum NodeHostFailure {
  /// No node build for this phone is in the documented place.
  noBinary,

  /// The copied file did not match its checksum, or did not run.
  badBinary,

  /// Preparing the data folder or creating the vault failed.
  prepare,

  /// The node did not start, or stopped by itself.
  start,

  /// Pairing with the node did not complete.
  pair,

  /// Stopping or removing did not finish.
  remove,
}

class NodeHostException implements Exception {
  const NodeHostException(this.failure, [this.detail]);

  final NodeHostFailure failure;
  final String? detail;

  @override
  String toString() => 'NodeHostException($failure)';
}

/// What the built-in Linux says about the node right now.
class NodeHostFacts {
  const NodeHostFacts({
    this.linuxReady = false,
    this.binaryInstalled = false,
    this.dataExists = false,
    this.serviceRunning = false,
    this.binaryAvailable = false,
  });

  /// The built-in Linux is installed and ready.
  final bool linuxReady;

  /// `factsbook-node` is inside the built-in Linux.
  final bool binaryInstalled;

  /// A vault was created (the node has been set up here).
  final bool dataExists;

  /// The app-owned service is running now.
  final bool serviceRunning;

  /// A build for this phone is in the documented place, ready to install.
  final bool binaryAvailable;
}

/// What `factsbook-node pair` printed that the app needs: the one-time code
/// and the owner device id. Never logged, never shown.
class NodePairing {
  const NodePairing({required this.code, this.ownerDevice});

  final String code;
  final String? ownerDevice;

  /// Reads the node's one JSON line (`{"code":..,"owner_device":..}`) out of
  /// everything the command printed.
  static NodePairing? parse(String output) {
    for (final line in const LineSplitter().convert(output).reversed) {
      final text = line.trim();
      if (!text.startsWith('{')) continue;
      try {
        final json = jsonDecode(text);
        if (json is Map && json['code'] is String) {
          return NodePairing(
            code: json['code'] as String,
            ownerDevice: json['owner_device'] as String?,
          );
        }
      } on FormatException {
        continue;
      }
    }
    return null;
  }
}

/// The steps of running the node inside the built-in Linux. The controller
/// calls these in order; tests answer them with a fake.
abstract interface class FactsBookNodeHost {
  /// The built-in Linux exists on this runner (Android).
  bool get supported;

  /// The address the node listens on, loopback only, inside this phone.
  String get address;

  Future<NodeHostFacts> inspect();

  /// Copies the node build from the documented place into the Linux and
  /// checks it. Throws [NodeHostFailure.noBinary] when there is none.
  Future<void> installBinary();

  /// Writes the config, makes a passphrase (kept in the phone's secure
  /// storage, never in a file next to the vault), creates the vault, and
  /// leaves it ready to serve.
  Future<void> createVault();

  Future<void> startNode();

  Future<void> stopNode();

  /// Asks the node for a one-time pairing code that also enrols
  /// [ownerKeyHex] as this phone's approval key.
  Future<NodePairing> pairingCode({required String ownerKeyHex});

  Future<String> log();

  /// Stops the node and deletes its data folder and its passphrase. The node
  /// program itself stays.
  Future<void> removeData();
}

/// The real host: the app's built-in Linux (proot) through [BuiltinLinux].
/// The node build is found at
/// `<phone storage>/Android/data/<app id>/files/factsbook/factsbook-node-<abi>`
/// (`aarch64` or `x86_64`), with an optional `.sha256` file beside it.
///
/// TODO(factsbook-release): fetch a published build instead of looking in
/// that folder; there is no download address yet, so none is made up.
class BuiltinLinuxNodeHost implements FactsBookNodeHost {
  BuiltinLinuxNodeHost({
    BuiltinLinux? linux,
    Random? random,
    FlutterSecureStorage? secure,
    Future<Directory> Function()? rootfs,
  }) : _linux = linux ?? BuiltinLinux(),
       _random = random ?? Random.secure(),
       _secure = secure ?? const FlutterSecureStorage(),
       _rootfsOverride = rootfs;

  final BuiltinLinux _linux;
  final Random _random;
  final FlutterSecureStorage _secure;
  final Future<Directory> Function()? _rootfsOverride;

  /// Where the vault's passphrase lives: Android Keystore-backed secure
  /// storage, like the profile secrets.
  static const secureKey = 'oc.factsbook-node.passphrase';

  static const port = 8787;
  static const serviceName = 'factsbook';
  static const home = '/root/.factsbook';
  static const binaryPath = '/usr/local/bin/factsbook-node';

  /// A short-lived file inside the Linux that holds the passphrase only while
  /// a node command reads it from stdin. Before this version it stayed there
  /// for good; [inspect] moves such a file into secure storage and deletes it.
  static const passphrasePath = '/root/.oc-builtin/factsbook.passphrase';

  @override
  bool get supported => BuiltinLinux.supported;

  @override
  String get address => '127.0.0.1:$port';

  /// `aarch64` or `x86_64`: the build this phone runs.
  static String get archName =>
      Abi.current() == Abi.androidX64 ? 'x86_64' : 'aarch64';

  Future<Directory> _rootfs() async {
    final override = _rootfsOverride;
    if (override != null) return override();
    return Directory(
      '${(await getApplicationSupportDirectory()).path}/linux/ubuntu',
    );
  }

  Future<File> _passphraseFile() async =>
      File('${(await _rootfs()).path}$passphrasePath');

  /// Moves a passphrase file left by an earlier version into secure storage
  /// and deletes it. Safe to run any time; never logs the value.
  Future<void> migratePassphrase() async {
    final file = await _passphraseFile();
    if (!await file.exists()) return;
    final stored = await _secure.read(key: secureKey);
    if (stored == null || stored.isEmpty) {
      final legacy = (await file.readAsString()).trim();
      if (legacy.isNotEmpty) {
        await _secure.write(key: secureKey, value: legacy);
      }
    }
    await file.delete();
  }

  Future<void> _unstage() async {
    final file = await _passphraseFile();
    if (await file.exists()) await file.delete();
  }

  /// Puts the passphrase where a node command can read it from stdin. With
  /// [create] a first passphrase is made when there is none yet.
  Future<void> _stage({bool create = false}) async {
    await migratePassphrase();
    var pass = await _secure.read(key: secureKey);
    if (pass == null || pass.isEmpty) {
      if (!create) {
        throw const NodeHostException(
          NodeHostFailure.prepare,
          'The vault passphrase is not in secure storage.',
        );
      }
      pass = _newPassphrase();
      await _secure.write(key: secureKey, value: pass);
    }
    final file = await _passphraseFile();
    await file.parent.create(recursive: true);
    await file.writeAsString('$pass\n', flush: true);
  }

  /// Runs [body] with the passphrase staged, and takes it away again.
  Future<T> _withPassphrase<T>(
    Future<T> Function() body, {
    bool create = false,
  }) async {
    await _stage(create: create);
    try {
      return await body();
    } finally {
      await _unstage();
    }
  }

  Future<File?> _source() async {
    final external = await getExternalStorageDirectory();
    if (external == null) return null;
    final file = File('${external.path}/factsbook/factsbook-node-$archName');
    return await file.exists() ? file : null;
  }

  static String _env() => 'export FACTSBOOK_HOME=$home';

  @override
  Future<NodeHostFacts> inspect() async {
    if (!supported) return const NodeHostFacts();
    try {
      await migratePassphrase();
    } on Object {
      // Migration is retried on the next look; it must not hide the state.
    }
    final status = await _linux.status();
    final ready = status.installed && status.phase == BuiltinLinuxPhase.ready;
    if (!ready) return const NodeHostFacts();
    final result = await _linux.run(
      'b=0; [ -x $binaryPath ] && b=1; d=0; '
      '[ -f $home/state/enrollment.enc ] && d=1; echo "fb b=\$b d=\$d"',
      timeout: const Duration(seconds: 30),
    );
    final facts = parseInspect(result.output);
    return NodeHostFacts(
      linuxReady: true,
      binaryInstalled: facts.binaryInstalled,
      dataExists: facts.dataExists,
      serviceRunning: status.services.contains(serviceName),
      binaryAvailable: facts.binaryInstalled || await _source() != null,
    );
  }

  /// Reads the `fb b=1 d=0` line of the inspect script.
  static ({bool binaryInstalled, bool dataExists}) parseInspect(String output) {
    final match = RegExp(r'fb b=(\d) d=(\d)').firstMatch(output);
    return (
      binaryInstalled: match?.group(1) == '1',
      dataExists: match?.group(2) == '1',
    );
  }

  @override
  Future<void> installBinary() async {
    final source = await _source();
    if (source == null) {
      throw const NodeHostException(NodeHostFailure.noBinary);
    }
    final bytes = await source.readAsBytes();
    final digest = sha256.convert(bytes).toString();
    final sidecar = File('${source.path}.sha256');
    if (await sidecar.exists()) {
      final expected = (await sidecar.readAsString())
          .trim()
          .split(RegExp(r'\s+'))
          .first
          .toLowerCase();
      if (expected != digest) {
        throw const NodeHostException(
          NodeHostFailure.badBinary,
          'The node build does not match its checksum.',
        );
      }
    }
    final rootfs = await _rootfs();
    final target = File('${rootfs.path}$binaryPath');
    await target.parent.create(recursive: true);
    await target.writeAsBytes(bytes, flush: true);
    final check = await _linux.run(
      'chmod 755 $binaryPath && $binaryPath --help >/dev/null 2>&1; '
      'echo "fb exit=\$?"',
      timeout: const Duration(seconds: 30),
    );
    // `--help` prints usage and exits normally.
    if (!check.output.contains('fb exit=0')) {
      throw NodeHostException(
        NodeHostFailure.badBinary,
        'The node build did not run (sha256 $digest).',
      );
    }
  }

  String _newPassphrase() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  @override
  Future<void> createVault() async {
    // Kept: a vault made with an earlier passphrase needs that one.
    final result = await _withPassphrase(create: true, () {
      // The folders and the config are made by the node's own user inside the
      // Linux: the node refuses a data folder that another user owns.
      return _linux.run(
        'chmod 600 $passphrasePath && umask 077 && '
        '[ -f $home/state/enrollment.enc ] || rm -rf $home; mkdir -p $home/config && '
        'chmod 700 $home $home/config && '
        "printf '%s\\n' 'node = { listen = \"127.0.0.1:$port\" }' "
        "'vault = { path = \"$home/vault\" }' > $home/config/config.toml && "
        '${_env()} && if [ -f $home/state/enrollment.enc ]; then '
        'echo "fb init=exists"; else out=\$($binaryPath init < $passphrasePath '
        '2>&1); echo "fb init=\$?"; echo "\$out"; fi',
        timeout: const Duration(minutes: 5),
      );
    });
    if (!result.output.contains('fb init=0') &&
        !result.output.contains('fb init=exists')) {
      // The node's own error is a code, never a secret.
      throw NodeHostException(
        NodeHostFailure.prepare,
        'The vault could not be created: ${result.output.trim()}',
      );
    }
  }

  @override
  Future<void> startNode() async {
    await _stage();
    try {
      // The service reads the passphrase once from stdin and removes the
      // staged file itself, so it does not stay on disk while the node runs.
      await _linux.startService(
        serviceName,
        '${_env()}\nexec 3<$passphrasePath\nrm -f $passphrasePath\n'
        'exec $binaryPath serve <&3\n',
        port: port,
        notice: null,
      );
    } on Object {
      await _unstage();
      rethrow;
    }
  }

  @override
  Future<void> stopNode() => _linux.stopService(serviceName);

  @override
  Future<NodePairing> pairingCode({required String ownerKeyHex}) async {
    final result = await _withPassphrase(
      () => _linux.run(
        '${_env()} && $binaryPath pair --scopes read,write,admin,owner '
        '--owner-key $ownerKeyHex < $passphrasePath 2>&1',
        timeout: const Duration(minutes: 2),
      ),
    );
    final pairing = result.exitCode == 0
        ? NodePairing.parse(result.output)
        : null;
    // Never put the output in the error: it holds the code.
    if (pairing == null) {
      throw NodeHostException(
        NodeHostFailure.pair,
        'The node gave no pairing code (exit ${result.exitCode}).',
      );
    }
    return pairing;
  }

  @override
  Future<String> log() => _linux.serviceLog(serviceName);

  @override
  Future<void> removeData() async {
    await _linux.stopService(serviceName);
    final result = await _linux.run(
      'rm -rf $home $passphrasePath && echo "fb removed"',
      timeout: const Duration(minutes: 2),
    );
    if (!result.output.contains('fb removed')) {
      throw const NodeHostException(NodeHostFailure.remove);
    }
    await _secure.delete(key: secureKey);
    await _unstage();
  }
}
