import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/provider_quota.dart';
import '../domain/server_gateway.dart';
import '../domain/terminal_lifecycle.dart';
import '../domain/usage_subscriptions.dart';
import 'profiles.dart';
import 'usage_subscription_sources.dart';
import 'usage_subscriptions_controller.dart';

/// The reader script that ships with the app.
const computerUsageAsset = 'tool/quota/read_once.mjs';

/// The one line the reader prints (`tool/quota/read_once.mjs`).
const computerUsageMarker = 'OCMN_USAGE_V1';

/// The providers the reader looks for, and what it found for each.
class ComputerUsageResult {
  const ComputerUsageResult({
    this.snapshots = const {},
    this.auth = const {},
    this.problem,
  });

  final Map<QuotaProvider, ProviderQuotaSnapshot> snapshots;

  /// `oauth`, `api`, or absent when nothing is signed in for that provider.
  final Map<QuotaProvider, String> auth;
  final ComputerUsageProblem? problem;

  bool get ok => problem == null;

  /// Providers with a plan the check could use (a plan sign-in, or a key that
  /// is itself the plan).
  List<QuotaProvider> get found => [
    for (final p in QuotaProvider.values)
      if (quotaCollectionAvailable(p) && auth.containsKey(p) && !payAsYouGo(p))
        p,
  ];

  /// An OpenAI API key, or a MiniMax pay-as-you-go key: it has no plan limits.
  bool payAsYouGo(QuotaProvider provider) =>
      auth[provider] == 'api' &&
      (provider == QuotaProvider.codex ||
          (provider == QuotaProvider.minimax &&
              snapshots[provider]?.status == ProviderQuotaStatus.unsupported));
}

// ---------------------------------------------------------------------------
// Parsing what the terminal prints.

final _ansi = RegExp(
  r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)|\x1B\[[0-9;?<=>]*[ -/]*[@-~]|\x1B[@-Z\\-_]',
);
final _markerLine = RegExp('^$computerUsageMarker ([A-Za-z0-9+/]+={0,2})\$');

/// Removes terminal control codes.
String stripTerminalCodes(String text) => text.replaceAll(_ansi, '');

/// Finds the reader's answer in raw terminal [output]: echo, colour codes and
/// carriage returns are ignored; only a line that is exactly the marker and a
/// base64 JSON document counts. Null when there is none (yet).
ComputerUsageResult? parseComputerUsageOutput(String output) {
  final clean = stripTerminalCodes(output);
  ComputerUsageResult? found;
  for (final raw in clean.split(RegExp(r'[\r\n]+'))) {
    final match = _markerLine.firstMatch(raw.trim());
    if (match == null) continue;
    final result = _decode(match.group(1)!);
    if (result != null) found = result;
  }
  return found;
}

ComputerUsageResult? _decode(String encoded) {
  if (encoded.length > 96 * 1024) return null;
  try {
    final json = jsonDecode(utf8.decode(base64.decode(encoded)));
    if (json is! Map<String, dynamic> || json['v'] != 1) return null;
    final error = json['error'];
    if (error != null) {
      return ComputerUsageResult(
        problem: error == 'nodeTooOld'
            ? ComputerUsageProblem.nodeTooOld
            : ComputerUsageProblem.noAnswer,
      );
    }
    final snapshots = <QuotaProvider, ProviderQuotaSnapshot>{};
    final providers = json['providers'];
    if (providers is Map) {
      for (final provider in QuotaProvider.values) {
        final raw = providers[provider.name];
        if (raw == null) continue;
        try {
          snapshots[provider] = ProviderQuotaSnapshot.fromJson(raw);
        } on Object {
          // One provider's bad answer does not hide the others.
        }
      }
    }
    final auth = <QuotaProvider, String>{};
    final rawAuth = json['auth'];
    if (rawAuth is Map) {
      for (final provider in QuotaProvider.values) {
        final type = rawAuth[provider.name];
        if (type == 'oauth' || type == 'api') auth[provider] = type as String;
      }
    }
    return ComputerUsageResult(snapshots: snapshots, auth: auth);
  } on Object {
    return null;
  }
}

/// Words in the output that say why Node itself did not run. Used only to
/// choose a reason; the output is never kept.
ComputerUsageProblem classifyComputerUsageOutput(String output) {
  final text = stripTerminalCodes(output).toLowerCase();
  if (text.contains('not found') ||
      text.contains('not recognized') ||
      text.contains('enoent') ||
      text.contains('no such file')) {
    return ComputerUsageProblem.nodeMissing;
  }
  if (text.contains('syntaxerror') ||
      text.contains('err_unknown_builtin') ||
      text.contains('unexpected token') ||
      text.contains('requires node')) {
    return ComputerUsageProblem.nodeTooOld;
  }
  return ComputerUsageProblem.noAnswer;
}

// ---------------------------------------------------------------------------
// The terminal the check runs in.

/// One short-lived way to run a command on a server and read its output. The
/// production one wraps a monitor gateway pair; tests fake it.
abstract interface class ComputerTerminalPort {
  /// Starts [command]. Throws [ComputerUsageException] when it cannot.
  Future<TerminalProcess> start(
    String command,
    List<String> arguments, {
    required String title,
  });
  Future<TerminalChannel> connect(String id);
  Future<void> remove(String id);
  void close();
}

class ComputerUsageException implements Exception {
  const ComputerUsageException(this.problem);
  final ComputerUsageProblem problem;
  @override
  String toString() => 'ComputerUsageException($problem)';
}

/// The terminal port over a saved server's operations gateway.
class GatewayComputerTerminalPort implements ComputerTerminalPort {
  GatewayComputerTerminalPort(this.operations, {this.onClose});
  final ServerOperationsGateway operations;
  final void Function()? onClose;

  @override
  Future<TerminalProcess> start(
    String command,
    List<String> arguments, {
    required String title,
  }) async {
    final Object facet = operations;
    if (facet is! OneShotCommandGateway) {
      throw const ComputerUsageException(ComputerUsageProblem.serverTooOld);
    }
    try {
      return await facet.createCommandTerminal(
        command: command,
        arguments: arguments,
        title: title,
      );
    } on Object catch (error) {
      throw ComputerUsageException(classifyComputerStartFailure(error));
    }
  }

  @override
  Future<TerminalChannel> connect(String id) => operations.connectTerminal(id);

  @override
  Future<void> remove(String id) => operations.removeTerminal(id);

  @override
  void close() => onClose?.call();
}

int? _statusCodeOf(Object? error) {
  if (error is ProductException) return _statusCodeOf(error.cause);
  try {
    final code = (error as dynamic).statusCode;
    if (code is int) return code;
  } on Object {
    // Not a typed API failure.
  }
  try {
    final code = (error as dynamic).response?.statusCode;
    if (code is int) return code;
  } on Object {
    // No HTTP answer at all.
  }
  return null;
}

/// 404/405/501 mean this OpenCode has no terminal API; no status at all means
/// the server did not answer; anything else (a refused command) is treated as
/// "the command did not run" so the login-shell fallback can try.
ComputerUsageProblem classifyComputerStartFailure(Object error) {
  final status = _statusCodeOf(error);
  if (status == null) return ComputerUsageProblem.unreachable;
  if (status == 404 || status == 405 || status == 501) {
    return ComputerUsageProblem.serverTooOld;
  }
  return ComputerUsageProblem.nodeMissing;
}

// ---------------------------------------------------------------------------
// One run.

/// Runs the reader on a computer through [port]: `node` first, then once more
/// through a login shell (so an nvm PATH is found). The terminal is removed in
/// every case, including a timeout.
Future<ComputerUsageResult> runComputerUsageCheck(
  ComputerTerminalPort port,
  String source, {
  Duration timeout = const Duration(seconds: 25),
}) async {
  final deadline = DateTime.now().add(timeout);
  Duration left() {
    final remaining = deadline.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  final attempts = <(String, List<String>)>[
    ('node', ['--input-type=module', '-e', source]),
    (
      'bash',
      [
        '-lc',
        'command -v node >/dev/null 2>&1 || '
            '{ echo "node: command not found"; sleep 1; exit 127; }; '
            'node --input-type=module -e "\$1"; s=\$?; sleep 1; exit \$s',
        '_',
        source,
      ],
    ),
  ];
  var last = ComputerUsageProblem.noAnswer;
  for (final (index, attempt) in attempts.indexed) {
    if (left() <= Duration.zero) break;
    final run = await _attempt(port, attempt.$1, attempt.$2, left());
    if (run.result != null) return run.result!;
    last = index == 0 ? run.problem : _worse(last, run.problem);
    // The server cannot do this at all, or does not answer: a second try
    // through another shell would only repeat that.
    if (run.problem == ComputerUsageProblem.serverTooOld ||
        run.problem == ComputerUsageProblem.unreachable) {
      return ComputerUsageResult(problem: run.problem);
    }
  }
  return ComputerUsageResult(problem: last);
}

ComputerUsageProblem _worse(
  ComputerUsageProblem first,
  ComputerUsageProblem second,
) => second == ComputerUsageProblem.noAnswer ? first : second;

class _Attempt {
  const _Attempt(this.result, this.problem);
  final ComputerUsageResult? result;
  final ComputerUsageProblem problem;
}

Future<_Attempt> _attempt(
  ComputerTerminalPort port,
  String command,
  List<String> arguments,
  Duration timeout,
) async {
  String? id;
  TerminalChannel? channel;
  StreamSubscription<String>? subscription;
  final seen = StringBuffer();
  try {
    final TerminalProcess process;
    try {
      process = await port
          .start(command, arguments, title: computerUsageTitle)
          .timeout(timeout);
    } on ComputerUsageException catch (error) {
      return _Attempt(null, error.problem);
    } on TimeoutException {
      return const _Attempt(null, ComputerUsageProblem.unreachable);
    }
    id = process.id;
    final answer = Completer<ComputerUsageResult?>();
    try {
      channel = await port.connect(id).timeout(timeout);
    } on Object {
      // It already ended (a missing command exits at once) or the socket
      // failed: no output to read.
      return const _Attempt(null, ComputerUsageProblem.nodeMissing);
    }
    subscription = channel.output.listen(
      (chunk) {
        if (seen.length < 256 * 1024) seen.write(chunk);
        final parsed = parseComputerUsageOutput(seen.toString());
        if (parsed != null && !answer.isCompleted) answer.complete(parsed);
      },
      onDone: () {
        if (!answer.isCompleted) answer.complete(null);
      },
      onError: (Object _) {
        if (!answer.isCompleted) answer.complete(null);
      },
      cancelOnError: true,
    );
    ComputerUsageResult? result;
    try {
      result = await answer.future.timeout(timeout);
    } on TimeoutException {
      return _Attempt(null, classifyComputerUsageOutput(seen.toString()));
    }
    if (result != null) return _Attempt(result, ComputerUsageProblem.noAnswer);
    return _Attempt(null, classifyComputerUsageOutput(seen.toString()));
  } finally {
    seen.clear();
    // Teardown is bounded: a socket that does not close must not hold the
    // terminal's removal, which is what stops the process.
    try {
      await subscription?.cancel().timeout(const Duration(seconds: 2));
    } on Object {
      // Teardown errors are not shown.
    }
    try {
      await channel?.close().timeout(const Duration(seconds: 2));
    } on Object {
      // Teardown errors are not shown.
    }
    if (id != null) {
      try {
        await port.remove(id).timeout(const Duration(seconds: 5));
      } on Object {
        // Already gone, or the server went away: nothing more to do.
      }
    }
  }
}

// ---------------------------------------------------------------------------
// The source.

/// Reads Codex, GLM and MiniMax plans on a saved OpenCode server that is not
/// In-app Ubuntu, by running a one-shot, read-only check there through the
/// server's own terminal API. Per server and off until the person turns it on
/// (`oc.usageComputerReader.<profileId>`, swept with the profile).
class ComputerUsageSource implements UsageSource, UsageReaderNotes {
  ComputerUsageSource({
    required this.prefs,
    required this.profiles,
    required this.isReadable,
    required this.isInApp,
    required this.createPort,
    required this.loadSource,
    DateTime Function()? clock,
    this.timeout = const Duration(seconds: 25),
    this.backgroundEvery = const Duration(minutes: 15),
    this.foregroundEvery = const Duration(seconds: 60),
  }) : clock = clock ?? DateTime.now;

  final SharedPreferences prefs;
  final List<ServerProfile> Function() profiles;
  final bool Function(String profileId) isReadable;
  final bool Function(ServerProfile) isInApp;
  final ComputerTerminalPort Function(ServerProfile) createPort;

  /// The reader script (the `tool/quota/read_once.mjs` asset).
  final Future<String> Function() loadSource;
  final DateTime Function() clock;
  final Duration timeout, backgroundEvery, foregroundEvery;

  static String enabledKey(String profileId) =>
      'oc.usageComputerReader.$profileId';

  final _attempted = <String, DateTime>{};
  final _problems = <String, ComputerUsageProblem?>{};
  final _pending = <String, ComputerUsageResult>{};
  final _lastFound = <String, List<QuotaProvider>>{};
  final _running = <String, Future<ComputerUsageResult>>{};

  bool isEnabled(String profileId) =>
      prefs.getBool(enabledKey(profileId)) ?? false;

  /// Saved OpenCode servers this can read: not In-app Ubuntu, a normal
  /// password in place.
  bool appliesTo(ServerProfile profile) =>
      profile.backend == ServerBackend.openCode &&
      !isInApp(profile) &&
      isReadable(profile.id) &&
      !profile.requiresPasswordReentry;

  @override
  ComputerUsageProblem? problemFor(String connectionId) =>
      _problems[connectionId];

  /// What the last run found on [connectionId], for the Read-from screen.
  List<QuotaProvider> foundOn(String connectionId) =>
      _lastFound[connectionId] ?? const [];

  Future<ComputerUsageResult> _run(ServerProfile profile) {
    final running = _running[profile.id];
    if (running != null) return running;
    final operation = _runNow(profile).whenComplete(() {
      _running.remove(profile.id);
    });
    _running[profile.id] = operation;
    return operation;
  }

  Future<ComputerUsageResult> _runNow(ServerProfile profile) async {
    _attempted[profile.id] = clock();
    ComputerTerminalPort? port;
    try {
      final source = await loadSource();
      port = createPort(profile);
      final result = await runComputerUsageCheck(
        port,
        source,
        timeout: timeout,
      );
      _problems[profile.id] = result.problem;
      _lastFound[profile.id] = result.found;
      return result;
    } on Object {
      _problems[profile.id] = ComputerUsageProblem.unreachable;
      return const ComputerUsageResult(
        problem: ComputerUsageProblem.unreachable,
      );
    } finally {
      try {
        port?.close();
      } on Object {
        // Teardown errors are not shown.
      }
    }
  }

  /// Turns reading on for [profile] and runs one check right away. The next
  /// refresh uses that answer instead of running again.
  Future<ComputerUsageResult> turnOn(ServerProfile profile) async {
    await prefs.setBool(enabledKey(profile.id), true);
    final result = await _run(profile);
    if (result.problem == ComputerUsageProblem.serverTooOld) {
      // This OpenCode has no terminal API: there is nothing to keep trying.
      await prefs.remove(enabledKey(profile.id));
      return result;
    }
    _pending[profile.id] = result;
    return result;
  }

  /// One check now, for "Read now" on the Read-from screen.
  Future<ComputerUsageResult> readNow(ServerProfile profile) async {
    final result = await _run(profile);
    _pending[profile.id] = result;
    return result;
  }

  Future<void> turnOff(String profileId) async {
    await prefs.remove(enabledKey(profileId));
    forget(profileId);
  }

  /// A deleted server: drop what is kept in memory for it. The stored switch
  /// goes with the profile's preference sweep.
  void forget(String profileId) {
    _pending.remove(profileId);
    _problems.remove(profileId);
    _lastFound.remove(profileId);
    _attempted.remove(profileId);
  }

  @override
  Future<UsageSourceResult> read(UsageReadContext context) async {
    final readings = <UsageReading>[];
    final signIns = <UsageSignIn>[];
    final failures = <UsageFailure>[];
    final unreached = <String>{};
    for (final profile in profiles()) {
      if (!appliesTo(profile) || !isEnabled(profile.id)) continue;
      ComputerUsageResult? result = _pending.remove(profile.id);
      if (result == null) {
        final before = _attempted[profile.id];
        final every = context.background ? backgroundEvery : foregroundEvery;
        if (!context.force &&
            before != null &&
            context.now.difference(before) < every) {
          continue;
        }
        result = await _run(profile);
      }
      _fold(
        profile,
        result,
        context,
        readings: readings,
        signIns: signIns,
        failures: failures,
        unreached: unreached,
      );
    }
    return UsageSourceResult(
      readings: readings,
      signIns: signIns,
      failures: failures,
      unreached: unreached,
    );
  }

  void _fold(
    ServerProfile profile,
    ComputerUsageResult result,
    UsageReadContext context, {
    required List<UsageReading> readings,
    required List<UsageSignIn> signIns,
    required List<UsageFailure> failures,
    required Set<String> unreached,
  }) {
    final id = profile.id;
    final problem = result.problem;
    if (problem == ComputerUsageProblem.unreachable) {
      unreached.add(id);
      return;
    }
    if (problem != null) {
      // The reader itself is broken: every plan it would have read says so.
      final known = <String>{
        for (final p in QuotaProvider.values)
          if (quotaCollectionAvailable(p) &&
              (context.lastReading?.call(id, p.name) != null ||
                  (context.signedIn?.call(id) ?? const {}).contains(p.name)))
            p.name,
      };
      for (final provider in known) {
        failures.add(UsageFailure(id, provider, UsageProblem.broken));
      }
      return;
    }
    for (final provider in QuotaProvider.values) {
      if (!quotaCollectionAvailable(provider)) continue;
      final auth = result.auth[provider];
      final snapshot = result.snapshots[provider];
      if (auth == null) {
        // Signed out here now: only a plan that was read here before stays
        // listed, as "not signed in".
        if (context.lastReading?.call(id, provider.name) != null) {
          readings.add(
            usageBareReading(id, provider, UsageReadingStatus.notSignedIn),
          );
        }
        continue;
      }
      final payAsYouGo = result.payAsYouGo(provider);
      signIns.add(
        UsageSignIn(
          providerId: provider.name,
          connectionId: id,
          method: payAsYouGo ? SignInMethod.apiKey : SignInMethod.plan,
          displayName: usageQuotaName(provider),
        ),
      );
      if (payAsYouGo || snapshot == null) continue;
      switch (snapshot.status) {
        case ProviderQuotaStatus.ok when snapshot.canShowWindows:
          readings.add(usageReadingFromSnapshot(id, provider, snapshot));
        case ProviderQuotaStatus.authRequired:
          readings.add(
            usageBareReading(id, provider, UsageReadingStatus.authRequired),
          );
        case ProviderQuotaStatus.rateLimited:
          failures.add(
            UsageFailure(id, provider.name, UsageProblem.rateLimited),
          );
        case _:
          failures.add(UsageFailure(id, provider.name, UsageProblem.broken));
      }
    }
  }
}
