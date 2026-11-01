/// Local supervision consent, distinct from a host's observed policy.
enum AutomationSupervision { high, balanced, autonomous }

/// Existing behaviours grouped by the automation contract (personas §3).
/// A choice permits an existing executor; it never starts or creates one.
enum AutomationBehavior {
  reconnect,
  retryIntake,
  reconcileQueuedSends,
  retryProviderErrors,
  restartPhoneServer,
  resumeSetup,
  recheckEnvironment,
  pollRestartHealth,
  thermalRecovery,
  reduceEffects,
  chooseDefaults,
  detectInstallations,
  preserveDrafts,
  followOutput,
  pollOpenPages,
  boundedPaging,
  routeReadyWork,
  wakeStalledPool,
  restartWorkers,
  recycleWorkers,
  holdAtProviderLimit,
  retryUnconfirmedAnswer,
  retryTransientTask,
  fallBackToDirectTask,
  applyCodePush,

  // Consent once, in flow. These never turn on merely by loading a profile.
  restartDevServices,
  stopIdleHelpers,
  cleanCaches,
  updateWhenIdle,
  monitorOtherServers,
  monitorQuota;

  bool get requiresConsent => switch (this) {
    restartDevServices ||
    stopIdleHelpers ||
    cleanCaches ||
    updateWhenIdle ||
    monitorOtherServers ||
    monitorQuota => true,
    _ => false,
  };
}

/// Immutable local preferences, not a claim about the host's current policy.
/// Irreversible/public actions and ad-hoc shell commands are deliberately
/// absent: this policy never grants permission for them.
class AutomationPolicy {
  AutomationPolicy({
    this.supervision = AutomationSupervision.high,
    this.autoApprove = false,
    this.autoMergeOnGreen = false,
    Map<AutomationBehavior, bool> behaviors = const {},
  }) : behaviors = Map.unmodifiable({
         for (final behavior in AutomationBehavior.values)
           behavior: behaviors[behavior] ?? !behavior.requiresConsent,
       });

  /// Corrupt or unsupported storage cannot grant any automation.
  factory AutomationPolicy.disabled() => AutomationPolicy(
    behaviors: {for (final b in AutomationBehavior.values) b: false},
  );

  final AutomationSupervision supervision;

  /// Local automatic answers only. Does not disable server-side saved rules.
  final bool autoApprove;
  final bool autoMergeOnGreen;
  final Map<AutomationBehavior, bool> behaviors;

  bool allows(AutomationBehavior behavior) => behaviors[behavior]!;
  bool get allowsAutoApproval =>
      supervision != AutomationSupervision.high && autoApprove;
  bool get allowsAutoMerge =>
      supervision != AutomationSupervision.high && autoMergeOnGreen;

  AutomationPolicy withBehavior(AutomationBehavior behavior, bool enabled) =>
      AutomationPolicy(
        supervision: supervision,
        autoApprove: autoApprove,
        autoMergeOnGreen: autoMergeOnGreen,
        behaviors: {...behaviors, behavior: enabled},
      );

  /// Call only after the in-flow consent. Balanced/Autonomous consent to both
  /// automatic answers and merge-on-green; either can then be disabled alone.
  AutomationPolicy withSupervision(AutomationSupervision value) =>
      AutomationPolicy(
        supervision: value,
        autoApprove: value != AutomationSupervision.high,
        autoMergeOnGreen: value != AutomationSupervision.high,
        behaviors: behaviors,
      );

  AutomationPolicy withApprovals({bool? autoApprove, bool? autoMergeOnGreen}) =>
      AutomationPolicy(
        supervision: supervision,
        autoApprove: autoApprove ?? this.autoApprove,
        autoMergeOnGreen: autoMergeOnGreen ?? this.autoMergeOnGreen,
        behaviors: behaviors,
      );

  Map<String, Object> toJson() => {
    'version': 1,
    'supervision': supervision.name,
    'autoApprove': autoApprove,
    'autoMergeOnGreen': autoMergeOnGreen,
    'behaviors': {for (final e in behaviors.entries) e.key.name: e.value},
  };

  /// Missing individual entries in an existing record stay off. Future
  /// behaviours therefore cannot silently opt an existing server in.
  static AutomationPolicy fromJson(Object? value) {
    if (value is! Map || value['version'] != 1) {
      return AutomationPolicy.disabled();
    }
    final supervision = AutomationSupervision.values
        .where((v) => v.name == value['supervision'])
        .firstOrNull;
    final behaviors = value['behaviors'];
    if (supervision == null || behaviors is! Map) {
      return AutomationPolicy.disabled();
    }
    return AutomationPolicy(
      supervision: supervision,
      autoApprove: value['autoApprove'] == true,
      autoMergeOnGreen: value['autoMergeOnGreen'] == true,
      behaviors: {
        for (final b in AutomationBehavior.values) b: behaviors[b.name] == true,
      },
    );
  }
}
