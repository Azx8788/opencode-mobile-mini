import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/agent_error_text.dart';
import 'package:opencode_mobile/domain/provider_parameter.dart';

/// Providers word a refused setting differently, and those words are what
/// the chat has to read before it can offer "Switch back" instead of
/// repeating a JSON error.
void main() {
  group('reads the setting a provider refused', () {
    test('OpenAI unsupported temperature', () {
      final issue = ProviderParameterIssue.read(
        '{"error":{"message":"Unsupported parameter: \'temperature\' is not '
        'supported with this model.","type":"invalid_request_error",'
        '"param":"temperature","code":"unsupported_parameter"}}',
      );
      expect(issue?.parameter, ProviderParameter.temperature);
    });

    test('Anthropic max_tokens above the model limit', () {
      final issue = ProviderParameterIssue.read(
        'max_tokens: 8192 > 4096, which is the maximum allowed number of '
        'output tokens for claude-3-haiku-20240307',
      );
      expect(issue?.parameter, ProviderParameter.maxOutputTokens);
    });

    test('reasoning budget rejected', () {
      final issue = ProviderParameterIssue.read(
        "thinking.budget_tokens: Input should be greater than or equal to 1024",
      );
      expect(issue?.parameter, ProviderParameter.reasoning);
    });

    test('tool choice not implemented', () {
      final issue = ProviderParameterIssue.read(
        "tool_choice is not supported for this model",
      );
      expect(issue?.parameter, ProviderParameter.toolChoice);
    });

    test('tools refused', () {
      final issue = ProviderParameterIssue.read(
        'This model does not support tools.',
      );
      expect(issue?.parameter, ProviderParameter.tools);
    });

    test('response format refused', () {
      final issue = ProviderParameterIssue.read(
        "Unsupported parameter: 'response_format'",
      );
      expect(issue?.parameter, ProviderParameter.responseFormat);
    });

    test('image input refused', () {
      final issue = ProviderParameterIssue.read(
        'This model does not support image input.',
      );
      expect(issue?.parameter, ProviderParameter.images);
    });

    test('top_p out of range', () {
      final issue = ProviderParameterIssue.read(
        "Invalid value for 'top_p': must be <= 1",
      );
      expect(issue?.parameter, ProviderParameter.topP);
    });

    test('an unnamed parameter is still a parameter refusal', () {
      final issue = ProviderParameterIssue.read(
        'invalid_request_error: Unsupported parameter: seed',
      );
      expect(issue?.parameter, ProviderParameter.unknown);
    });
  });

  group('leaves other failures alone', () {
    test('a model that does not exist', () {
      expect(
        ProviderParameterIssue.read(
          'ProviderModelNotFoundError: Model not found: openai/gpt-9. '
          'Did you mean: gpt-5?',
        ),
        isNull,
      );
    });

    test('a dropped connection', () {
      expect(
        ProviderParameterIssue.read('ECONNRESET: socket hang up'),
        isNull,
      );
    });

    test('a rate limit', () {
      expect(
        ProviderParameterIssue.read('429 Too Many Requests: rate limit'),
        isNull,
      );
    });

    test('a context overflow', () {
      expect(
        ProviderParameterIssue.read(
          "This model's maximum context length is 128000 tokens",
        ),
        isNull,
      );
    });

    test('an empty message', () {
      expect(ProviderParameterIssue.read('   '), isNull);
    });
  });

  group('classifies as a refused setting', () {
    test('provider parameter wins over the generic HTTP rules', () {
      expect(
        classifyAgentError(
          "Unsupported parameter: 'temperature' is not supported with this "
          'model.',
        ),
        AgentErrorCause.providerParameter,
      );
    });

    test('a rate limit is still a rate limit', () {
      expect(
        classifyAgentError('429 Too Many Requests'),
        AgentErrorCause.rateLimited,
      );
    });

    test('an unknown failure stays unknown', () {
      expect(
        classifyAgentError('The agent stopped because of an error.'),
        isNull,
      );
    });
  });
}
