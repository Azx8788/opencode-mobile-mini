import 'session_address_link.dart';
import 'server_gateway.dart' show Session;

/// Local deployment evidence, never inferred from descriptor response fields.
/// All items require host integration verification before production admission.
class SessionAddressDeployment {
  const SessionAddressDeployment({
    this.privateIngress = false,
    this.privateTransportEnforced = false,
    this.requesterIdentityOnEveryRequest = false,
    this.taggedPeerPolicyVerified = false,
    this.noPublicAlternateIngress = false,
    this.scopedSessionAuthorization = false,
    this.sessionIdsAreBearerCredentials = true,
  });

  final bool privateIngress;
  final bool privateTransportEnforced;
  final bool requesterIdentityOnEveryRequest;
  final bool taggedPeerPolicyVerified;
  final bool noPublicAlternateIngress;
  final bool scopedSessionAuthorization;
  final bool sessionIdsAreBearerCredentials;

  bool get verified =>
      privateIngress &&
      privateTransportEnforced &&
      requesterIdentityOnEveryRequest &&
      taggedPeerPolicyVerified &&
      noPublicAlternateIngress &&
      scopedSessionAuthorization &&
      !sessionIdsAreBearerCredentials;
}

class SessionAddressDescriptor {
  const SessionAddressDescriptor._(this.origin, this.instanceId);
  final String origin;
  final String instanceId;

  factory SessionAddressDescriptor.parse(Object? value) {
    const failure = SessionAddressFailure(
      SessionAddressFailureCode.invalidDescriptor,
    );
    if (value is! Map ||
        value.length != 5 ||
        value['schemaVersion'] != 1 ||
        value['canonicalOrigin'] is! String ||
        value['instanceId'] is! String) {
      throw failure;
    }
    final versions = value['linkVersions'];
    final capabilities = value['capabilities'];
    if (versions is! List ||
        versions.length != 1 ||
        versions.single != 2 ||
        capabilities is! Map ||
        capabilities.length != 1 ||
        capabilities['sessionLookupById'] != true) {
      throw failure;
    }
    try {
      final rawOrigin = value['canonicalOrigin'] as String;
      final origin = SessionAddressLink.normalizeOrigin(rawOrigin);
      final instance = value['instanceId'] as String;
      if (origin != rawOrigin || !SessionAddressLink.validInstance(instance)) {
        throw failure;
      }
      // Reuse the complete field secret validation, without disclosing a link.
      SessionAddressLink.build(
        origin: origin,
        instanceId: instance,
        sessionId: 'descriptor',
        includeServerAddress: true,
      );
      return SessionAddressDescriptor._(origin, instance.toLowerCase());
    } catch (_) {
      throw failure;
    }
  }
}

abstract interface class SessionAddressDescriptorReader {
  /// Anonymous, bounded discovery only. Never uses a saved gateway or password.
  Future<SessionAddressDescriptor> discover(String origin);
}

/// A separate integration boundary: ordinary SessionGateway.session(id) is NOT
/// sufficient evidence of scoped authorization and must never be adapted blindly.
abstract interface class SessionAddressLookupGateway {
  SessionAddressDeployment get deployment;
  String get origin;
  String get instanceId;

  /// Read-only resolution across the installation's private project scopes.
  /// Must apply ordinary requester/session authorization, never bearer-ID access.
  /// Missing/denied results throw sessionMissing/accessDenied; never create/resume.
  Future<Session> lookupAuthorizedSession(String sessionId);
}
