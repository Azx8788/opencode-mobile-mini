import '../../domain/orchestration_gateway.dart';

/// The gateway used when orchestration is off for a profile: no
/// capabilities, empty reads, a stream that ends at once, and controls that
/// answer with a rejected receipt. Never throws.
class NullOrchestrationGateway implements OrchestrationGateway {
  const NullOrchestrationGateway();

  static const _rejectedMessage = 'Orchestration is not enabled';

  @override
  OrchestrationCapabilities get capabilities => OrchestrationCapabilities.none;

  @override
  OrchestrationHostIdentity? get host => null;

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}

  @override
  Future<List<OrchestrationProject>> projects() async => const [];

  @override
  Future<List<OrchestrationRun>> runs({String? projectId}) async => const [];

  @override
  Future<OrchestrationRun?> run(String id) async => null;

  @override
  Future<List<WorkItem>> work({String? projectId}) async => const [];

  @override
  Future<List<WorkItem>> readyWork({String? projectId}) async => const [];

  @override
  Future<WorkItem?> workItem(String id) async => null;

  @override
  Future<List<OrchestrationAgent>> agents() async => const [];

  @override
  Future<OrchestrationAgent?> agent(String id) async => null;

  @override
  Future<List<OrchestrationGate>> gates() async => const [];

  @override
  Future<OrchestrationUsage?> usage() async => null;

  @override
  Future<List<ActivityEvent>> activity({
    int? afterSeq,
    int limit = 100,
  }) async => const [];

  @override
  Stream<OrchestrationEvent> events({
    EventCursor resumeFrom = EventCursor.none,
  }) => const Stream.empty();

  @override
  Future<MutationReceipt> respond(
    String gateId,
    GateResponse response, {
    required String requestId,
  }) async => MutationReceipt.rejected(requestId, _rejectedMessage);

  @override
  Future<MutationReceipt> message(
    String agentId,
    String text, {
    required String requestId,
  }) async => MutationReceipt.rejected(requestId, _rejectedMessage);

  @override
  Future<MutationReceipt> controlAgent(
    String agentId,
    AgentControlAction action, {
    required String requestId,
  }) async => MutationReceipt.rejected(requestId, _rejectedMessage);

  @override
  Future<MutationReceipt> cancelRun(
    String runId, {
    required String requestId,
  }) async => MutationReceipt.rejected(requestId, _rejectedMessage);

  @override
  Future<MutationReceipt> assign(
    String workId, {
    required String agentId,
    required String requestId,
  }) async => MutationReceipt.rejected(requestId, _rejectedMessage);

  @override
  Future<MutationReceipt> createWork({
    required String title,
    String? description,
    String? projectId,
    required String requestId,
  }) async => MutationReceipt.rejected(requestId, _rejectedMessage);
}
