// The subscriptions model behind Usage, its alerts and the home widget.
//
// A subscription is a plan on a provider account. It can be signed in on
// several connections and is read by a reader. Nothing here touches the
// network, storage or Flutter; the controller feeds it readings and
// [mergeUsageSubscriptions] turns them into one list. Contract:
// docs/design/usage-subscriptions-contract-2026-10-13.md.

/// The provider ids the app can offer under "Add a subscription".
const usagePlanProviders = ['codex', 'claude', 'glm', 'minimax'];

/// The providers whose usage the app's reader can read from an OpenCode
/// sign-in (Codex, GLM, MiniMax). Any other provider connected on an OpenCode
/// server is not a plan card: Claude's plan usage never comes through
/// OpenCode, and the others have no reader there.
const usageReadableFromOpenCode = {'codex', 'glm', 'minimax'};

/// Providers whose sign-in is a key, not an account sign-in. Their fix is
/// "Add key".
const _keyProviders = {'glm', 'minimax'};

/// Maps OpenCode's provider ids (and Paseo's) to the ids Usage uses. Null for
/// providers that are not subscriptions (OpenRouter and the like).
String? canonicalUsageProviderId(String id) => switch (id) {
  'codex' || 'openai' => 'codex',
  'claude' || 'anthropic' => 'claude',
  'glm' || 'zai-coding-plan' || 'zhipuai-coding-plan' => 'glm',
  'minimax' || 'minimax-coding-plan' => 'minimax',
  'copilot' || 'github-copilot' => 'copilot',
  'kimi' || 'kimi-for-coding' => 'kimi',
  _ => null,
};

enum UsageConnectionKind {
  inAppUbuntu,
  phoneAgents,
  openCodeServer,
  paseoServer,
  codexServer,
}

class UsageConnection {
  const UsageConnection({
    required this.id,
    required this.name,
    required this.kind,
  });

  /// This phone's agent host. Its id is not a saved profile id.
  static const phoneId = 'phone';

  final String id;
  final String name;
  final UsageConnectionKind kind;

  @override
  bool operator ==(Object other) => other is UsageConnection && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'UsageConnection($id)';
}

enum SignInState { signedIn, expired, notSignedIn }

/// How a provider is signed in. [plan] is an account sign-in; [apiKey] is a
/// pay-as-you-go key with no plan limits.
enum SignInMethod { plan, apiKey, unknown }

class SignedInOn {
  const SignedInOn({
    required this.connection,
    required this.state,
    this.method = SignInMethod.unknown,
    this.readsFromHere = false,
    this.online = true,
  });

  final UsageConnection connection;
  final SignInState state;
  final SignInMethod method;

  /// The numbers on the card came from this connection.
  final bool readsFromHere;
  final bool online;
}

enum UsageWindowKind { fiveHour, weekly, monthly, other }

class UsageWindow {
  UsageWindow({
    required this.id,
    required double usedPercent,
    this.durationSeconds,
    this.resetsAt,
    this.label = '',
  }) : usedPercent = usedPercent.clamp(0, 100).toDouble(),
       kind = _kindOf(id, durationSeconds);

  final String id;
  final UsageWindowKind kind;
  final String label;
  final double usedPercent;
  final int? durationSeconds;
  final DateTime? resetsAt;

  double get leftPercent => 100 - usedPercent;

  bool resetPassed(DateTime now) =>
      resetsAt != null && !now.isBefore(resetsAt!);

  static UsageWindowKind _kindOf(String id, int? seconds) {
    if (seconds == 18000) return UsageWindowKind.fiveHour;
    if (seconds == 604800) return UsageWindowKind.weekly;
    if (seconds != null && seconds >= 28 * 86400 && seconds <= 31 * 86400) {
      return UsageWindowKind.monthly;
    }
    return switch (id) {
      '5h' || 'five_hour' => UsageWindowKind.fiveHour,
      'weekly' || 'seven_day' || 'week' => UsageWindowKind.weekly,
      'monthly' || 'month' => UsageWindowKind.monthly,
      _ => UsageWindowKind.other,
    };
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'used': usedPercent,
    'seconds': durationSeconds,
    'resetsAt': resetsAt?.millisecondsSinceEpoch,
    'label': label,
  };

  static UsageWindow? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'], used = value['used'];
    if (id is! String || used is! num || !used.isFinite) return null;
    final seconds = value['seconds'], reset = value['resetsAt'];
    return UsageWindow(
      id: id,
      usedPercent: used.toDouble(),
      durationSeconds: seconds is int ? seconds : null,
      resetsAt: reset is int
          ? DateTime.fromMillisecondsSinceEpoch(reset, isUtc: true)
          : null,
      label: value['label'] is String ? value['label'] as String : '',
    );
  }
}

enum SubscriptionState {
  ok,
  nearLimit,
  exhausted,
  cantReadYet,
  signInExpired,
  notSignedIn,
  readerBroken,
  offlineStale,
  noLimits,
  apiKeyOnly,
}

enum UsageFix { none, signIn, addKey, setUp, tryAgain }

class UsageSubscription {
  const UsageSubscription({
    required this.key,
    required this.providerId,
    required this.displayName,
    required this.state,
    this.planLabel,
    this.accountRef,
    this.windows = const [],
    this.fetchedAt,
    this.checkedAt,
    this.readFrom,
    this.signedInOn = const [],
    this.fix = UsageFix.none,
    this.fixConnection,
    this.resetSinceLastReading = false,
    this.showConnectionName = false,
    this.alertThreshold = 80,
    this.hasAlertOverride = false,
    this.notifyOnReset = false,
  });

  final String key;
  final String providerId;
  final String displayName;
  final String? planLabel;
  final String? accountRef;
  final List<UsageWindow> windows;
  final DateTime? fetchedAt;
  final DateTime? checkedAt;
  final UsageConnection? readFrom;
  final List<SignedInOn> signedInOn;
  final SubscriptionState state;
  final UsageFix fix;
  final UsageConnection? fixConnection;
  final bool resetSinceLastReading;
  final bool showConnectionName;
  final double alertThreshold;
  final bool hasAlertOverride;
  final bool notifyOnReset;

  UsageWindow? get fiveHour => _first(UsageWindowKind.fiveHour);
  UsageWindow? get weekly => _first(UsageWindowKind.weekly);

  UsageWindow? _first(UsageWindowKind kind) {
    for (final window in windows) {
      if (window.kind == kind) return window;
    }
    return null;
  }

  double? get mostUsedPercent => windows.isEmpty
      ? null
      : windows.map((w) => w.usedPercent).reduce((a, b) => a > b ? a : b);

  double? get leastLeftPercent =>
      mostUsedPercent == null ? null : 100 - mostUsedPercent!;

  UsageSubscription withSignedInOn(List<SignedInOn> value) => UsageSubscription(
    key: key,
    providerId: providerId,
    displayName: displayName,
    state: state,
    planLabel: planLabel,
    accountRef: accountRef,
    windows: windows,
    fetchedAt: fetchedAt,
    checkedAt: checkedAt,
    readFrom: readFrom,
    signedInOn: value,
    fix: fix,
    fixConnection: fixConnection,
    resetSinceLastReading: resetSinceLastReading,
    showConnectionName: showConnectionName,
    alertThreshold: alertThreshold,
    hasAlertOverride: hasAlertOverride,
    notifyOnReset: notifyOnReset,
  );

  UsageSubscription withDisplay({required bool showConnectionName}) =>
      UsageSubscription(
        key: key,
        providerId: providerId,
        displayName: displayName,
        state: state,
        planLabel: planLabel,
        accountRef: accountRef,
        windows: windows,
        fetchedAt: fetchedAt,
        checkedAt: checkedAt,
        readFrom: readFrom,
        signedInOn: signedInOn,
        fix: fix,
        fixConnection: fixConnection,
        resetSinceLastReading: resetSinceLastReading,
        showConnectionName: showConnectionName,
        alertThreshold: alertThreshold,
        hasAlertOverride: hasAlertOverride,
        notifyOnReset: notifyOnReset,
      );

  @override
  String toString() => 'UsageSubscription($key, ${state.name})';
}

class ApiKeyAccount {
  const ApiKeyAccount({
    required this.providerId,
    required this.displayName,
    required this.connection,
    this.viaOpenCode = false,
  });
  final String providerId;
  final String displayName;
  final UsageConnection connection;

  /// Seen through an OpenCode server's providers: its plan limits cannot be
  /// read from there (Claude), so it is a Details row only.
  final bool viaOpenCode;
}

class UsageSnapshot {
  const UsageSnapshot({
    this.subscriptions = const [],
    this.apiKeyAccounts = const [],
    this.addable = const [],
    this.connections = const [],
    this.refreshedAt,
    this.loaded = false,
    this.offlineConnectionIds = const {},
    this.answeredConnectionIds = const {},
  });

  final List<UsageSubscription> subscriptions;
  final List<ApiKeyAccount> apiKeyAccounts;
  final List<String> addable;
  final List<UsageConnection> connections;
  final DateTime? refreshedAt;
  final bool loaded;

  /// Connections the last refresh could not reach: their state is unknown.
  final Set<String> offlineConnectionIds;

  /// Connections that answered with their sign-ins or numbers at least once.
  /// A connection in neither set was never asked (its sign-in is unknown).
  final Set<String> answeredConnectionIds;

  bool isOffline(UsageConnection connection) =>
      offlineConnectionIds.contains(connection.id);

  /// True when [connection] gave an answer, so "not signed in" there is a
  /// fact and not a guess.
  bool hasAnswered(UsageConnection connection) =>
      !isOffline(connection) && answeredConnectionIds.contains(connection.id);

  bool get hasSeveralConnections => connections.length > 1;
}

/// Why a computer could not be read. The Read-from screen and Details word
/// each one in plain language; none carries server or process text.
enum ComputerUsageProblem {
  /// Node.js is not on the computer's PATH.
  nodeMissing,

  /// Node.js is older than 20.
  nodeTooOld,

  /// This OpenCode has no terminal API the check can use.
  serverTooOld,

  /// The server did not answer.
  unreachable,

  /// The check started but never printed its answer.
  noAnswer,
}

/// What a reader of a computer last said, kept for Details and the Read-from
/// screen. Plain reasons only; never process or server text.
abstract interface class UsageReaderNotes {
  ComputerUsageProblem? problemFor(String connectionId);
}

// ---------------------------------------------------------------------------
// Source-side types.

enum UsageReadingStatus { ok, noLimits, authRequired, notSignedIn }

/// Why the last numbers could not be refreshed.
enum UsageProblem { rateLimited, broken, offline }

/// One provider as one connection reports it. Display numbers only.
class UsageReading {
  const UsageReading({
    required this.providerId,
    required this.displayName,
    required this.connectionId,
    required this.status,
    required this.fetchedAt,
    this.windows = const [],
    this.accountRef,
    this.plan,
    this.method = SignInMethod.unknown,
    this.checkedAt,
    this.problem,
  });

  final String providerId;
  final String displayName;
  final String connectionId;
  final UsageReadingStatus status;
  final DateTime fetchedAt;
  final List<UsageWindow> windows;

  /// Opaque account hash from the reader; never an email or token.
  final String? accountRef;
  final String? plan;
  final SignInMethod method;
  final DateTime? checkedAt;
  final UsageProblem? problem;

  String get cacheKey => '$connectionId|$providerId';

  bool get hasNumbers =>
      (status == UsageReadingStatus.ok ||
          status == UsageReadingStatus.noLimits) &&
      problem != UsageProblem.broken;

  UsageReading copyWith({
    UsageReadingStatus? status,
    List<UsageWindow>? windows,
    String? accountRef,
    DateTime? checkedAt,
    UsageProblem? problem,
    bool clearProblem = false,
  }) => UsageReading(
    providerId: providerId,
    displayName: displayName,
    connectionId: connectionId,
    status: status ?? this.status,
    fetchedAt: fetchedAt,
    windows: windows ?? this.windows,
    accountRef: accountRef ?? this.accountRef,
    plan: plan,
    method: method,
    checkedAt: checkedAt ?? this.checkedAt,
    problem: clearProblem ? null : problem ?? this.problem,
  );

  Map<String, Object?> toJson() => {
    'provider': providerId,
    'name': displayName,
    'status': status.name,
    'fetchedAt': fetchedAt.millisecondsSinceEpoch,
    'account': accountRef,
    'plan': plan,
    'method': method.name,
    'windows': [for (final w in windows) w.toJson()],
  };

  static UsageReading? fromJson(Object? value, String connectionId) {
    if (value is! Map) return null;
    final provider = value['provider'], name = value['name'];
    final fetched = value['fetchedAt'];
    if (provider is! String ||
        !RegExp(r'^[a-z0-9][a-z0-9_-]{0,31}$').hasMatch(provider) ||
        name is! String ||
        fetched is! int) {
      return null;
    }
    final status = UsageReadingStatus.values
        .where((s) => s.name == value['status'])
        .firstOrNull;
    if (status == null) return null;
    final rawWindows = value['windows'];
    final account = value['account'];
    return UsageReading(
      providerId: provider,
      displayName: name.length > 40 ? name.substring(0, 40) : name,
      connectionId: connectionId,
      status: status,
      fetchedAt: DateTime.fromMillisecondsSinceEpoch(fetched, isUtc: true),
      windows: [
        if (rawWindows is List)
          for (final raw in rawWindows.take(16)) ?UsageWindow.fromJson(raw),
      ],
      accountRef: account is String && account.length <= 128 ? account : null,
      plan: value['plan'] is String ? value['plan'] as String : null,
      method:
          SignInMethod.values
              .where((m) => m.name == value['method'])
              .firstOrNull ??
          SignInMethod.unknown,
    );
  }
}

/// What a connection says about one provider's sign-in (OpenCode's connected
/// providers). Says nothing about numbers.
class UsageSignIn {
  const UsageSignIn({
    required this.providerId,
    required this.connectionId,
    this.state = SignInState.signedIn,
    this.method = SignInMethod.unknown,
    this.displayName = '',
  });
  final String providerId;
  final String connectionId;
  final SignInState state;
  final SignInMethod method;
  final String displayName;
}

/// A reader tried and failed; no text from the failure is kept.
class UsageFailure {
  const UsageFailure(this.connectionId, this.providerId, this.problem);
  final String connectionId;
  final String providerId;
  final UsageProblem problem;
}

class UsageAlertOverride {
  const UsageAlertOverride({this.threshold, this.notifyOnReset});
  final double? threshold;
  final bool? notifyOnReset;
  bool get isEmpty => threshold == null && notifyOnReset == null;
}

// ---------------------------------------------------------------------------
// The merge.

String usageSubscriptionKey(
  String providerId,
  String? accountRef,
  String connectionId,
) => '$providerId|${accountRef ?? 'conn:$connectionId'}';

const _stateRank = <SubscriptionState, int>{
  SubscriptionState.exhausted: 0,
  SubscriptionState.signInExpired: 1,
  SubscriptionState.nearLimit: 2,
  SubscriptionState.readerBroken: 3,
  SubscriptionState.cantReadYet: 4,
  SubscriptionState.notSignedIn: 5,
  SubscriptionState.offlineStale: 6,
  SubscriptionState.ok: 7,
  SubscriptionState.noLimits: 8,
  SubscriptionState.apiKeyOnly: 9,
};

/// Turns every connection's readings and sign-ins into one list.
///
/// [readings] is one entry per connection and provider (cached numbers with
/// the problem of the last attempt, if any). [authoritativeSignIns] names the
/// connections whose [signIns] answer was complete, so a provider missing
/// from it is signed out there.
UsageSnapshot mergeUsageSubscriptions({
  required DateTime now,
  required List<UsageConnection> connections,
  required List<UsageReading> readings,
  List<UsageSignIn> signIns = const [],
  Set<String> authoritativeSignIns = const {},
  double defaultThreshold = 80,
  Map<String, UsageAlertOverride> overrides = const {},
  bool notifyOnResetDefault = false,
  DateTime? refreshedAt,
  bool loaded = true,
  Set<String> offlineConnections = const {},
}) {
  final byId = {for (final c in connections) c.id: c};
  UsageConnection? connection(String id) => byId[id];

  // A provider the connection no longer lists has been signed out there.
  final effective = <UsageReading>[];
  for (final r in readings) {
    if (connection(r.connectionId) == null) continue;
    var reading = r;
    if (reading.hasNumbers &&
        authoritativeSignIns.contains(r.connectionId) &&
        !signIns.any(
          (s) =>
              s.providerId == r.providerId &&
              s.connectionId == r.connectionId &&
              s.state != SignInState.notSignedIn,
        )) {
      reading = reading.copyWith(
        status: UsageReadingStatus.notSignedIn,
        windows: const [],
        clearProblem: true,
      );
    }
    effective.add(reading);
  }

  // Group by provider and account (or connection when there is no account).
  final groups = <String, List<UsageReading>>{};
  for (final r in effective) {
    groups
        .putIfAbsent(
          usageSubscriptionKey(r.providerId, r.accountRef, r.connectionId),
          () => [],
        )
        .add(r);
  }

  final built = <UsageSubscription>[];
  final apiKeys = <String, ApiKeyAccount>{};
  // (provider|connection) pairs that a reading already speaks for.
  final covered = <String>{for (final r in effective) r.cacheKey};

  UsageAlertOverride? overrideFor(String key) => overrides[key];

  UsageSubscription build({
    required String key,
    required String providerId,
    required String displayName,
    required SubscriptionState state,
    required List<SignedInOn> signedInOn,
    UsageReading? primary,
    UsageFix fix = UsageFix.none,
    UsageConnection? fixConnection,
    bool resetSince = false,
  }) {
    final override = overrideFor(key);
    return UsageSubscription(
      key: key,
      providerId: providerId,
      displayName: displayName,
      state: state,
      planLabel: primary?.plan,
      accountRef: primary?.accountRef,
      windows: primary == null ? const [] : _sortedWindows(primary.windows),
      // A record with no numbers (not signed in, sign-in ran out) was not
      // read, so it carries no "read" time.
      fetchedAt: _wasRead(primary) ? primary!.fetchedAt : null,
      checkedAt: _wasRead(primary)
          ? primary!.checkedAt ?? primary.fetchedAt
          : null,
      readFrom: primary != null && primary.hasNumbers
          ? connection(primary.connectionId)
          : null,
      signedInOn: signedInOn,
      fix: fix,
      fixConnection: fixConnection,
      resetSinceLastReading: resetSince,
      alertThreshold: override?.threshold ?? defaultThreshold,
      hasAlertOverride: override?.threshold != null,
      notifyOnReset: override?.notifyOnReset ?? notifyOnResetDefault,
    );
  }

  UsageFix signInFix(String providerId) =>
      _keyProviders.contains(providerId) ? UsageFix.addKey : UsageFix.signIn;

  for (final entry in groups.entries) {
    final list = entry.value;
    // Freshest usable reading wins; otherwise the most recent attempt.
    UsageReading? primary;
    for (final r in list) {
      final usable = r.hasNumbers && r.problem != UsageProblem.offline;
      if (!usable) continue;
      if (primary == null || r.fetchedAt.isAfter(primary.fetchedAt)) {
        primary = r;
      }
    }
    primary ??=
        (list.toList()..sort((a, b) => b.fetchedAt.compareTo(a.fetchedAt)))
            .first;
    final threshold = overrideFor(entry.key)?.threshold ?? defaultThreshold;

    final signedIn = <SignedInOn>[];
    final ordered = [primary, ...list.where((r) => !identical(r, primary))];
    for (final r in ordered) {
      final c = connection(r.connectionId);
      if (c == null) continue;
      signedIn.add(
        SignedInOn(
          connection: c,
          state: switch (r.status) {
            UsageReadingStatus.authRequired => SignInState.expired,
            UsageReadingStatus.notSignedIn => SignInState.notSignedIn,
            _ => SignInState.signedIn,
          },
          method: r.method,
          readsFromHere: identical(r, primary) && r.hasNumbers,
          online:
              r.problem != UsageProblem.offline &&
              !offlineConnections.contains(r.connectionId),
        ),
      );
    }

    final resetSince = primary.windows.any(
      (w) => w.resetPassed(now) && primary!.fetchedAt.isBefore(w.resetsAt!),
    );
    final primaryConnection = connection(primary.connectionId)!;
    late SubscriptionState state;
    var fix = UsageFix.none;
    UsageConnection? fixConnection;
    switch (primary.status) {
      case UsageReadingStatus.authRequired:
        state = SubscriptionState.signInExpired;
        fix = signInFix(primary.providerId);
        fixConnection = primaryConnection;
      case UsageReadingStatus.notSignedIn:
        state = SubscriptionState.notSignedIn;
        fix = signInFix(primary.providerId);
        fixConnection = primaryConnection;
      case UsageReadingStatus.noLimits:
      case UsageReadingStatus.ok:
        if (primary.problem == UsageProblem.offline) {
          state = SubscriptionState.offlineStale;
        } else if (primary.problem == UsageProblem.broken) {
          state = SubscriptionState.readerBroken;
          fix = UsageFix.tryAgain;
          fixConnection = primaryConnection;
        } else if (primary.status == UsageReadingStatus.noLimits ||
            primary.windows.isEmpty) {
          state = SubscriptionState.noLimits;
        } else {
          final used = primary.windows
              .map((w) => w.usedPercent)
              .reduce((a, b) => a > b ? a : b);
          state = used >= 100
              ? SubscriptionState.exhausted
              : used >= threshold
              ? SubscriptionState.nearLimit
              : SubscriptionState.ok;
        }
    }
    built.add(
      build(
        key: entry.key,
        providerId: primary.providerId,
        displayName: primary.displayName,
        state: state,
        signedInOn: signedIn,
        primary: primary,
        fix: fix,
        fixConnection: fixConnection,
        resetSince: resetSince,
      ),
    );
  }

  // Sign-ins that no reader speaks for.
  for (final s in signIns) {
    if (s.state == SignInState.notSignedIn) continue;
    final c = connection(s.connectionId);
    if (c == null) continue;
    if (covered.contains('${s.connectionId}|${s.providerId}')) continue;
    final name = s.displayName.isEmpty ? s.providerId : s.displayName;
    final viaOpenCode =
        c.kind == UsageConnectionKind.openCodeServer ||
        c.kind == UsageConnectionKind.inAppUbuntu;
    if (s.method == SignInMethod.apiKey ||
        (s.providerId == 'claude' && viaOpenCode)) {
      apiKeys['${s.providerId}|${s.connectionId}'] = ApiKeyAccount(
        providerId: s.providerId,
        displayName: name,
        connection: c,
        viaOpenCode: viaOpenCode && s.providerId == 'claude',
      );
      continue;
    }
    // Providers the app's reader cannot read from an OpenCode sign-in are
    // not plan cards.
    if (viaOpenCode && !usageReadableFromOpenCode.contains(s.providerId)) {
      continue;
    }
    final expired = s.state == SignInState.expired;
    built.add(
      build(
        key: usageSubscriptionKey(s.providerId, null, s.connectionId),
        providerId: s.providerId,
        displayName: name,
        state: expired
            ? SubscriptionState.signInExpired
            : SubscriptionState.cantReadYet,
        signedInOn: [
          SignedInOn(
            connection: c,
            state: s.state,
            method: s.method,
            online: !offlineConnections.contains(c.id),
          ),
        ],
        fix: expired ? signInFix(s.providerId) : UsageFix.setUp,
        fixConnection: c,
      ),
    );
  }

  _collapseNotSignedIn(built);

  // Order: urgency, then least left, then name.
  built.sort((a, b) {
    final rank = _stateRank[a.state]!.compareTo(_stateRank[b.state]!);
    if (rank != 0) return rank;
    final left = (a.leastLeftPercent ?? 101).compareTo(
      b.leastLeftPercent ?? 101,
    );
    if (left != 0) return left;
    final provider = a.providerId.compareTo(b.providerId);
    return provider != 0 ? provider : a.key.compareTo(b.key);
  });

  final counts = <String, int>{};
  for (final s in built) {
    counts[s.providerId] = (counts[s.providerId] ?? 0) + 1;
  }
  final subscriptions = [
    for (final s in built)
      (counts[s.providerId]! > 1) ? s.withDisplay(showConnectionName: true) : s,
  ];

  final present = {for (final s in subscriptions) s.providerId};
  final seenProviders = {
    ...present,
    for (final a in apiKeys.values)
      if (!a.viaOpenCode) a.providerId,
  };
  return UsageSnapshot(
    subscriptions: List.unmodifiable(subscriptions),
    apiKeyAccounts: List.unmodifiable(apiKeys.values),
    addable: List.unmodifiable([
      for (final p in usagePlanProviders)
        if (!seenProviders.contains(p)) p,
    ]),
    connections: List.unmodifiable(connections),
    refreshedAt: refreshedAt,
    loaded: loaded,
    offlineConnectionIds: Set.unmodifiable(offlineConnections),
    answeredConnectionIds: Set.unmodifiable({
      ...authoritativeSignIns,
      for (final r in effective)
        if (r.problem != UsageProblem.offline) r.connectionId,
    }),
  );
}

bool _wasRead(UsageReading? r) =>
    r != null && (r.hasNumbers || r.windows.isNotEmpty);

/// "Not signed in anywhere" is only true when no connection has the provider.
/// A provider with no account identity keeps one card: leftover not-signed-in
/// records fold into the signed-in card (or into one another), and the
/// connections they stood for stay listed on it. Two cards for a provider
/// remain only when two readers report different accounts.
void _collapseNotSignedIn(List<UsageSubscription> built) {
  final byProvider = <String, List<UsageSubscription>>{};
  for (final s in built) {
    byProvider.putIfAbsent(s.providerId, () => []).add(s);
  }
  for (final list in byProvider.values) {
    final leftovers = [
      for (final s in list)
        if (s.state == SubscriptionState.notSignedIn && s.accountRef == null) s,
    ];
    if (leftovers.isEmpty) continue;
    final signed = [
      for (final s in list)
        if (s.state != SubscriptionState.notSignedIn) s,
    ];
    final UsageSubscription keeper;
    final drop = <UsageSubscription>[];
    if (signed.isNotEmpty) {
      keeper = signed.first;
      drop.addAll(leftovers);
    } else {
      keeper = leftovers.first;
      drop.addAll(leftovers.skip(1));
    }
    if (drop.isEmpty) continue;
    final extra = <SignedInOn>[
      for (final d in drop)
        for (final on in d.signedInOn)
          if (!keeper.signedInOn.any((k) => k.connection == on.connection)) on,
    ];
    final index = built.indexOf(keeper);
    built[index] = keeper.withSignedInOn([...keeper.signedInOn, ...extra]);
    for (final d in drop) {
      built.remove(d);
    }
  }
}

List<UsageWindow> _sortedWindows(List<UsageWindow> windows) {
  int rank(UsageWindow w) => switch (w.kind) {
    UsageWindowKind.fiveHour => 0,
    UsageWindowKind.weekly => 1,
    UsageWindowKind.monthly => 2,
    UsageWindowKind.other => 3,
  };
  final copy = windows.toList()..sort((a, b) => rank(a).compareTo(rank(b)));
  return List.unmodifiable(copy);
}
