import '../domain/server_gateway.dart';
import '../domain/sv3_skill_capabilities.dart';
import '../ui/kit/kit_redact.dart';

enum SkillConversationStatus {
  ready,
  unsupported,
  invalidInput,
  changed,
  alreadyStarted,
  creationUncertain,
  activationUncertain,
  promptUncertain,
}

/// Acknowledgement of preparation/dispatch, never proof an agent wrote a file.
class SkillConversationResult {
  const SkillConversationResult(this.status, {this.session});

  final SkillConversationStatus status;

  /// Retained after second-step failures so the caller can open/reconcile it.
  /// Never automatically delete this session or repeat an uncertain request.
  final Session? session;
}

/// One explicitly requested new-conversation action, bound to a connection.
///
/// Construct once per user-confirmed action. Repeated calls cannot create a
/// second session, even after an ambiguous network failure. This service keeps
/// no durable state and never logs transport exceptions or skill content.
class SkillConversationController {
  SkillConversationController({
    required this.gateway,
    required this.operations,
    required this.isCurrent,
    this.selection = const SessionSelection(),
  });

  final ServerGateway gateway;
  final ServerOperationsGateway operations;

  /// Checks captured profile/location revision and both gateway identities.
  /// The owner must invalidate this binding on deletion or disconnection.
  final bool Function() isCurrent;

  /// Captured picker selection: applied on creation where supported, and on
  /// prompts for gateways whose selections are per-message. Null uses server
  /// defaults. The owner refreshes its session inventory after this action.
  final SessionSelection selection;
  bool _started = false;

  SessionSkillGateway? get _skills => operations is SessionSkillGateway
      ? operations as SessionSkillGateway
      : null;

  bool get canUseSkill =>
      gateway.capabilities.canStartSkillConversation(_skills);
  bool get canAskForSkill => gateway.capabilities.skillAuthoringRequests;

  /// Creates a session, stages the exact catalog ID, and leaves the agent idle.
  /// A display name is never substituted for a missing protocol identifier.
  Future<SkillConversationResult> useInNewConversation(SkillInfo skill) async {
    if (!canUseSkill) return _result(SkillConversationStatus.unsupported);
    final id = skill.id;
    if (id == null || !_safeIdentifier(id)) {
      return _result(SkillConversationStatus.invalidInput);
    }
    return _start(
      action: (session) =>
          _skills!.activateSessionSkill(session.id, id, resume: false),
      failure: SkillConversationStatus.activationUncertain,
    );
  }

  /// Asks the agent for a SKILL.md draft via the existing prompt endpoint.
  /// Server-persisted prompt text is redacted before dispatch. Installation is
  /// deliberately not requested or inferred from the prompt acknowledgement.
  Future<SkillConversationResult> askAgentToWriteSkill(String requirements) {
    if (!canAskForSkill) {
      return Future.value(_result(SkillConversationStatus.unsupported));
    }
    final brief = KitRedact.text(requirements.trim());
    if (brief.isEmpty) {
      return Future.value(_result(SkillConversationStatus.invalidInput));
    }
    return _start(
      action: (session) => gateway.promptAsync(
        session.id,
        model: selection.model,
        agent: selection.agent,
        variant: selection.variant.isEmpty ? null : selection.variant,
        text:
            'Draft a reusable SKILL.md for the following requirements. '
            'Return the draft in this conversation for review. '
            'Do not install it or modify files.\n\n$brief',
      ),
      failure: SkillConversationStatus.promptUncertain,
    );
  }

  Future<SkillConversationResult> _start({
    required Future<void> Function(Session session) action,
    required SkillConversationStatus failure,
  }) async {
    if (_started) return _result(SkillConversationStatus.alreadyStarted);
    if (!_current) return _result(SkillConversationStatus.changed);
    _started = true;
    final Session session;
    try {
      session = gateway is SessionSelectionGateway
          ? await (gateway as SessionSelectionGateway).createSelectedSession(
              selection,
            )
          : await gateway.createSession();
    } catch (_) {
      // Creation may have reached the server. There is no idempotency promise.
      return _result(SkillConversationStatus.creationUncertain);
    }
    if (!_current) return _result(SkillConversationStatus.changed, session);
    try {
      await action(session);
    } catch (_) {
      // Do not surface server error strings: they may contain credentials.
      return _result(failure, session);
    }
    return _result(
      _current
          ? SkillConversationStatus.ready
          : SkillConversationStatus.changed,
      session,
    );
  }

  bool get _current => !gateway.isClosed && isCurrent();

  static bool _safeIdentifier(String id) =>
      id.isNotEmpty &&
      id == id.trim() &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(id) &&
      !KitRedact.containsSecret(id);

  static SkillConversationResult _result(
    SkillConversationStatus status, [
    Session? session,
  ]) => SkillConversationResult(status, session: session);
}
