/// Which request setting a provider refused, when its refusal can be read.
///
/// Switching a conversation to another provider mid-way sends the same
/// messages through a different wire format. Most differences are the
/// server's to reconcile, but a handful are settings the provider itself
/// rejects (`temperature` on a reasoning model, `max_tokens` above a limit,
/// a tool choice it does not implement). Naming the setting lets the chat
/// say something a person can act on instead of repeating the provider's
/// JSON error.
library;

/// One kind of request setting a provider can refuse.
enum ProviderParameter {
  temperature,
  topP,
  maxOutputTokens,
  reasoning,
  tools,
  toolChoice,
  responseFormat,
  images,
  unknown;

  /// The words a person sees for this setting, in the app's own voice.
  /// Kept short: it completes "This provider does not accept …".
  String get englishLabel => switch (this) {
    ProviderParameter.temperature => 'temperature',
    ProviderParameter.topP => 'top_p',
    ProviderParameter.maxOutputTokens => 'the output token limit',
    ProviderParameter.reasoning => 'the reasoning setting',
    ProviderParameter.tools => 'tool definitions',
    ProviderParameter.toolChoice => 'the tool choice',
    ProviderParameter.responseFormat => 'the response format',
    ProviderParameter.images => 'image input',
    ProviderParameter.unknown => 'a request setting',
  };
}

/// A refusal read out of a provider's error text: which setting, if any.
///
/// Conservative on purpose. A message only counts when it both names a
/// setting and carries a refusal signal, so an ordinary "model not found"
/// or a dropped connection never lands here. [read] returns null when the
/// text is not a parameter refusal.
class ProviderParameterIssue {
  const ProviderParameterIssue(this.parameter);

  final ProviderParameter parameter;

  /// Reads [raw] as a refused setting, or null.
  static ProviderParameterIssue? read(String raw) {
    final text = raw.trim().toLowerCase();
    if (text.isEmpty) return null;
    // A refusal signal: the words providers use when a field is not
    // accepted, not merely a request that failed for another reason.
    final refuses = _refusal.hasMatch(text);
    if (!refuses) return null;
    for (final (pattern, parameter) in _settings) {
      if (pattern.hasMatch(text)) return ProviderParameterIssue(parameter);
    }
    // "unsupported parameter: foo" names a setting this file does not
    // model; still a parameter refusal, so the person is told to switch
    // rather than to retry the same request.
    if (_unnamed.hasMatch(text)) {
      return const ProviderParameterIssue(ProviderParameter.unknown);
    }
    return null;
  }

  static final _refusal = RegExp(
    r'unsupported|not supported|does not support|doesn.t support'
    r'|unknown|unrecognized|unrecognised|invalid|out of range'
    r'|must be|exceeds|too large|not allowed|rejected',
    caseSensitive: false,
  );

  static final _unnamed = RegExp(
    r'unsupported (?:parameter|param|property|field)'
    r'|unknown (?:parameter|field|argument)'
    r'|unrecognized (?:request )?(?:argument|parameter)'
    r'|invalid_request_error',
    caseSensitive: false,
  );

  static final List<(RegExp, ProviderParameter)> _settings = [
    (RegExp(r'\bimages?\b|image input|vision|modality'), ProviderParameter.images),
    (RegExp(r'tool_choice'), ProviderParameter.toolChoice),
    (RegExp(r'response_format|json_schema|response format'), ProviderParameter.responseFormat),
    (RegExp(r'reasoning_effort|reasoning\b|thinking budget|budget_tokens'), ProviderParameter.reasoning),
    (RegExp(r'max_tokens|max_completion_tokens|max output tokens|output token limit'), ProviderParameter.maxOutputTokens),
    (RegExp(r'\btop_p\b|\btopP\b'), ProviderParameter.topP),
    (RegExp(r'\btemperature\b'), ProviderParameter.temperature),
    (RegExp(r'tool definition|tool schema|\btools\b|function calling'), ProviderParameter.tools),
  ];
}
