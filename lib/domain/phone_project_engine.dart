import 'team_project_gateway.dart';

/// Safe public failure: never retains a transport/native cause or payload.
class PhoneEngineException implements Exception {
  const PhoneEngineException(this.code);
  final String code;
  @override
  String toString() => 'PhoneEngineException($code)';
}

/// Authenticated schema-1 identity and the exact commands implemented by daemon.
class PhoneEngineHealth {
  const PhoneEngineHealth({
    required this.profileId,
    required this.engineVersion,
    required this.execution,
    required this.boundary,
    required this.oc2,
    this.oc2Verified = false,
    required this.commandActions,
    this.admission = 'unknown',
    this.chatAuthority = 'unknown',
    String boundaryReason = '',
    this.readinessReason = '',
    this.boundaryTier = 'none',
    this.restartRequired = false,
    this.globalAdmissionAuthority = false,
  }) : _boundaryReason = boundaryReason;
  final String profileId, engineVersion;
  final bool execution, boundary, oc2, oc2Verified;
  final Set<TeamProjectAction> commandActions;

  /// Admission is separate from supported execution capability.
  final String admission, chatAuthority, readinessReason;
  final String _boundaryReason;

  /// Keep older setup callers from reporting a successful attestation as a
  /// failed readiness reason while OpenCode 2 is restarting or unreachable.
  String get boundaryReason =>
      !canExecute && boundary && _boundaryReason == 'boundary_attested'
      ? (readinessReason.isEmpty ? 'protocolUnverified' : readinessReason)
      : _boundaryReason;
  String get boundaryAttestationReason => _boundaryReason;

  /// Signed confinement kind. Older schema-1 engines omit the tier; `none`
  /// then means unreported, while their existing execution flags remain valid.
  final String boundaryTier;
  final bool restartRequired, globalAdmissionAuthority;

  /// Protocol identity alone never proves the engine's permission boundary.
  bool get protocolVerified => oc2 && oc2Verified;
  bool get canExecute => execution && boundary && protocolVerified;

  factory PhoneEngineHealth.fromJson(Object? value, String expectedProfile) {
    if (value is! Map ||
        value['schemaVersion'] is! int ||
        value['schemaVersion'] != 1) {
      throw const PhoneEngineException('schemaUnsupported');
    }
    if (value['profileId'] != expectedProfile) {
      throw const PhoneEngineException('profileMismatch');
    }
    final flags = value['capabilities'];
    final actions = value['commandActions'];
    final version = value['engineVersion'];
    if (flags is! Map ||
        actions is! List ||
        actions.any((v) => v is! String) ||
        version is! String ||
        version.isEmpty ||
        ['execution', 'boundary', 'oc2'].any((k) => flags[k] is! bool) ||
        (flags.containsKey('oc2Verified') && flags['oc2Verified'] is! bool)) {
      throw const PhoneEngineException('payloadInvalid');
    }
    const tiers = {'none', 'landlock', 'proot'};
    final topTier = value['boundaryTier'];
    final capabilityTier = flags['boundaryTier'];
    if ((value.containsKey('boundaryTier') && !tiers.contains(topTier)) ||
        (flags.containsKey('boundaryTier') &&
            !tiers.contains(capabilityTier)) ||
        (value.containsKey('boundaryTier') &&
            flags.containsKey('boundaryTier') &&
            topTier != capabilityTier)) {
      throw const PhoneEngineException('payloadInvalid');
    }
    final tier = (topTier ?? capabilityTier ?? 'none') as String;
    return PhoneEngineHealth(
      profileId: expectedProfile,
      boundaryTier: tier,
      engineVersion: version,
      execution: flags['execution'] as bool,
      boundary: flags['boundary'] as bool,
      oc2: flags['oc2'] as bool,
      oc2Verified: flags['oc2Verified'] == true,
      admission: switch (value['admission']) {
        'idle' ||
        'busy' ||
        'unknown' ||
        'observing' => value['admission'] as String,
        _ => 'unknown',
      },
      chatAuthority: value['chatAuthority'] is String
          ? value['chatAuthority'] as String
          : 'unknown',
      readinessReason: value['readinessReason'] is String
          ? value['readinessReason'] as String
          : '',
      boundaryReason: value['boundaryReason'] is String
          ? value['boundaryReason'] as String
          : '',
      restartRequired: value['restartRequired'] == true,
      globalAdmissionAuthority: value['globalAdmissionAuthority'] == true,
      commandActions: Set.unmodifiable(
        TeamProjectAction.values.where((a) => actions.contains(a.name)),
      ),
    );
  }
}
