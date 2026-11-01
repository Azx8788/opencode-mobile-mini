/// What the node's milestone supports for a client (`api/capabilities.json`).
/// The app shows a feature only where the matrix says it is supported, and
/// says "not available yet" for the rest: a disabled capability is never
/// faked. `test/factsbook/factsbook_contract_test.dart` compares this with
/// the node's own file, so a change to the matrix breaks a test.
class FactsBookCapabilities {
  const FactsBookCapabilities({
    required this.milestone,
    required this.supported,
    required this.disabled,
    this.triggerTemplates = const {},
  });

  final String milestone;
  final Set<String> supported;

  /// capability -> the node's reason, in its words (kept for Details only).
  final Map<String, String> disabled;

  /// The template ids rules may use (`trigger_templates_v1`).
  final Set<String> triggerTemplates;

  bool supports(String capability) => supported.contains(capability);

  /// True for a capability the node lists as disabled.
  bool isDisabled(String capability) => disabled.containsKey(capability);

  static const localCapture = 'local_capture';
  static const captureReview = 'capture_review_with_immutable_evidence';
  static const ownerReview = 'owner_review_and_correction';
  static const search = 'normal_fts_search';
  static const encryptedExport = 'encrypted_unsaved_export';
  static const queueRepair = 'local_console_queue_identity_repair';
  static const clientRevocation = 'client_revocation';
  static const controlMaterial = 'signed_control_verification_material';
  static const localRestore = 'local_export_and_fresh_restore';
  static const reminders = 'reminder_parse_confirm_pause';
  static const triggers = 'local_trigger_slice';
  static const conversationOffers = 'explicit_conversation_offers';
  static const draftRuleTest = 'nonpersistent_draft_rule_test';
  static const proposalEdit = 'reminder_proposal_edit';
  static const ownerClassifiedCapture = 'owner_classified_trigger_capture';
  static const senderClaim = 'sender_claim_condition';
  static const capabilityDiscovery = 'capability_discovery';
  static const automaticConversationStart = 'automatic_conversation_start';
  static const notificationCapture = 'notification_capture';

  static const cloudTransport = 'cloud_transport';
  static const safeInCloud = 'safe_in_cloud';
  static const sensitiveUnlock = 'sensitive_unlock';
  static const phoneAlarms = 'phone_alarm_delivery';

  /// The B5 matrix as shipped, used until the node's own answer to
  /// `GET /v1/capabilities` replaces it, and for tests. The node's answer
  /// wins: anything it does not list is unavailable.
  static const b5 = FactsBookCapabilities(
    milestone: "B5",
    supported: {
      "local_capture",
      "capture_review_with_immutable_evidence",
      "owner_review_and_correction",
      "normal_fts_search",
      "encrypted_unsaved_export",
      "local_console_queue_identity_repair",
      "client_revocation",
      "signed_control_verification_material",
      "local_export_and_fresh_restore",
      "reminder_parse_confirm_pause",
      "authorized_source_retrieval",
      "immutable_owner_decisions",
      "permanent_tombstones",
      "local_trigger_slice",
      "owner_classified_trigger_capture",
      "source_authorization_revalidation",
      "stable_source_storm_summary",
      "sender_claim_condition",
      "nonpersistent_draft_rule_test",
      "reminder_proposal_edit",
      "client_reported_first_message",
      "capability_discovery",
      "explicit_conversation_offers",
    },
    disabled: {
      "cloud_transport": "qualification not started",
      "safe_in_cloud": "no checkpoint upload/readback",
      "sensitive_unlock": "key lifetime and recovery gates unresolved",
      "phone_alarm_delivery": "host gate unresolved",
      "external_edit_application": "preserved proposals only",
      "outward_actions": "synthetic simulator only",
      "automatic_failover": "excluded",
      "ai_models_embeddings_watches": "excluded",
      "untrusted_capture_promotion":
          "uncertain share/import/chat-selection captures are retained encrypted; no automatic promotion",
      "automatic_conversation_start":
          "Unavailable: no qualified client/budget/tool enforcement",
      "notification_capture": "v1.1 G-NL unresolved",
      "bill_due_template": "Sensitive money storage is not qualified",
      "per_job_agent_roles":
          "D36 is future work; no agent role or adapter is selected by this node",
    },
    triggerTemplates: {"appointment", "delivery", "booking", "subscription"},
  );

  /// Reads the node's `capabilities.json` shape.
  factory FactsBookCapabilities.fromJson(Map<String, Object?> json) =>
      FactsBookCapabilities(
        milestone: (json['milestone'] as String?) ?? '',
        supported: {
          for (final e in (json['supported'] as Map? ?? const {}).entries)
            if (e.value == true) '${e.key}',
        },
        disabled: {
          for (final e in (json['disabled'] as Map? ?? const {}).entries)
            '${e.key}': '${e.value}',
        },
        triggerTemplates: {
          for (final t in json['trigger_templates_v1'] as List? ?? const [])
            '$t',
        },
      );
}
