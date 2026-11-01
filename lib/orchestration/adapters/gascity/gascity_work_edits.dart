/// The board's bead edits over Gas City (docs/design/team-board-2026-09-26.md
/// §3): an additive adapter beside [GasCityControl], posting through the
/// gateway's public HTTP client with the same headers and receipt rules
/// ([receiptFromFront]).
///
/// | Verb | Route (pinned supervisor spec) |
/// |---|---|
/// | setWorkPriority | `POST /bead/{id}/update {priority}` |
/// | unassignWork | `POST /bead/{id}/update {metadata: {gc.routed_to: ""}}` |
/// | cancelWork | `POST /bead/{id}/update {metadata: {close_reason: cancelled}}`, then `POST /bead/{id}/close` under `<requestId>:close` |
/// | reopenWork | `POST /bead/{id}/reopen` |
///
/// Only where the gateway may write at all: behind a host front that allows
/// this device (with `Idempotency-Key`), or the phone's own loopback
/// supervisor (without). A bare supervisor over the network gets none, and
/// the board stays read-only.
library;

import '../../../domain/orchestration_gateway.dart';
import '../../../domain/orchestration_work_edits.dart';
import '../../client/http.dart';
import 'gascity_control.dart' show receiptFromFront;
import 'gascity_gateway.dart';

class GasCityWorkEdits implements OrchestrationWorkEditGateway {
  GasCityWorkEdits({
    required OrchestrationHttpClient http,
    this.idempotency = true,
  }) : _http = http;

  final OrchestrationHttpClient _http;

  /// Whether writes carry `Idempotency-Key` (a front stores receipts by it).
  final bool idempotency;

  /// The edits for [gateway] when it may write; null otherwise.
  static GasCityWorkEdits? of(GasCityGateway gateway) {
    if (!gateway.front && !gateway.loopbackControl) return null;
    return GasCityWorkEdits(http: gateway.http, idempotency: gateway.front);
  }

  String _bead(String id) =>
      '${_http.cityPath}/bead/${Uri.encodeComponent(id)}';

  @override
  Future<MutationReceipt> setWorkPriority(
    String workId,
    WorkPriority priority, {
    required String requestId,
  }) => _post(
    '${_bead(workId)}/update',
    requestId,
    body: {'priority': priority.value},
  );

  @override
  Future<MutationReceipt> unassignWork(
    String workId, {
    required String requestId,
  }) => _post(
    '${_bead(workId)}/update',
    requestId,
    body: {
      'metadata': {'gc.routed_to': ''},
    },
  );

  @override
  Future<MutationReceipt> cancelWork(
    String workId, {
    required String requestId,
  }) async {
    final marked = await _post(
      '${_bead(workId)}/update',
      requestId,
      body: {
        'metadata': {'close_reason': 'cancelled'},
      },
    );
    if (!marked.isAccepted) return marked;
    return _post(
      '${_bead(workId)}/close',
      requestId,
      idempotencyKey: '$requestId:close',
    );
  }

  @override
  Future<MutationReceipt> reopenWork(
    String workId, {
    required String requestId,
  }) => _post('${_bead(workId)}/reopen', requestId);

  Future<MutationReceipt> _post(
    String path,
    String requestId, {
    Map<String, Object?>? body,
    String? idempotencyKey,
  }) async {
    final OrchestrationHttpResponse response;
    try {
      response = await _http.postForReceipt(
        path,
        requestId: requestId,
        idempotencyKey: idempotency ? (idempotencyKey ?? requestId) : null,
        body: body ?? const {},
      );
    } on OrchestrationTransportException catch (e) {
      return MutationReceipt(
        id: requestId,
        status: MutationReceiptStatus.pending,
        message: e.message,
        raw: {'error': e.toString()},
      );
    }
    return receiptFromFront(requestId, response);
  }
}
