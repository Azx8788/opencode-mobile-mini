/// Tests a provider model by making the server actually use it.
///
/// A request from the phone proves the address answers *that client*. It does
/// not prove the provider works in this app, and on gateways that gate access
/// by client it proves the opposite: the phone gets a 200 carrying a sentence
/// saying only OpenCode, Codex or Claude Code may use the site, which reads as
/// a pass and is a refusal.
///
/// So the test is a real turn: the server opens a session pinned to the
/// provider and model, sends one short message, waits for the agent loop to go
/// idle, and reads what came back. The session is deleted afterwards, so the
/// test leaves nothing in the person's history.
library;

import 'dart:async';

import 'package:dio/dio.dart' show DioException;

import 'client.dart';
import 'models.dart';
import 'transport.dart';

/// How a provider test ended.
enum ProviderSessionOutcome {
  /// A reply came back with text in it.
  passed,

  /// The server is not answering, so nothing ran. Never retried from the
  /// phone: a fallback would hide exactly the failure this test exists for.
  unavailable,

  /// The server has not loaded this provider (a config that has not been
  /// reloaded, or an entry it refused).
  notLoaded,

  /// The server refused to open or use the session.
  rejected,

  /// The model did not answer in time.
  timeout,

  /// The turn finished without any text — usually the provider's error
  /// surfaced as a message rather than a reply.
  emptyReply,

  /// Anything else, with its text.
  failed,
}

class ProviderSessionResult {
  const ProviderSessionResult({
    required this.outcome,
    this.reply,
    this.detail,
    this.model,
    this.elapsed = Duration.zero,
  });

  final ProviderSessionOutcome outcome;

  /// What the model said, trimmed for a row. Null when there was no text.
  final String? reply;

  /// Why it failed, in the server's own words where it gave any.
  final String? detail;

  /// The model the server reports it used, which a gateway may have
  /// substituted for the one that was asked for.
  final String? model;

  final Duration elapsed;

  bool get passed => outcome == ProviderSessionOutcome.passed;
}

/// Reads the verdict out of a finished turn.
///
/// Pure, so the wording of every outcome is testable without a server: the
/// last assistant message decides — its error first, then its text.
ProviderSessionResult judgeProviderSession(
  List<Api2Message> messages, {
  required Duration elapsed,
}) {
  Api2AssistantMessage? last;
  for (final message in messages) {
    if (message is Api2AssistantMessage) last = message;
  }
  if (last == null) {
    return ProviderSessionResult(
      outcome: ProviderSessionOutcome.emptyReply,
      elapsed: elapsed,
    );
  }
  final model = last.model?.id;
  final error = last.error;
  final errorText = (error?.message ?? '').trim();
  if (errorText.isNotEmpty) {
    return ProviderSessionResult(
      outcome: ProviderSessionOutcome.failed,
      detail: errorText,
      model: model,
      elapsed: elapsed,
    );
  }
  final text = [
    for (final part in last.content)
      if (part is Api2TextContent) part.text,
  ].join().trim();
  if (text.isEmpty) {
    return ProviderSessionResult(
      outcome: ProviderSessionOutcome.emptyReply,
      detail: last.finish,
      model: model,
      elapsed: elapsed,
    );
  }
  return ProviderSessionResult(
    outcome: ProviderSessionOutcome.passed,
    reply: text.length <= 300 ? text : '${text.substring(0, 297)}…',
    model: model,
    elapsed: elapsed,
  );
}

class ProviderSessionProbe {
  ProviderSessionProbe({
    required this.baseUrl,
    required this.password,
    this.username = 'opencode',
    this.cleartextConfirmedOrigin,
    this.certificatePinSha256,
    this.timeout = const Duration(seconds: 120),
    Api2Client? client,
  }) : _client = client;

  final String baseUrl;
  final String password;
  final String username;
  final String? cleartextConfirmedOrigin;
  final String? certificatePinSha256;

  /// The whole turn, not one request: a model that is slow to start still
  /// deserves an answer rather than a stopwatch.
  final Duration timeout;

  final Api2Client? _client;

  /// What the test asks. Short, free of the person's data, and answerable
  /// without tools — a turn that stops to ask permission would prove nothing
  /// about the provider.
  static const promptText =
      'Reply with the single word OK. Do not use any tools.';

  /// Runs one real turn against [providerID]/[model].
  Future<ProviderSessionResult> run({
    required String providerID,
    required String model,
  }) async {
    final started = DateTime.now();
    final client =
        _client ??
        Api2Client.connect(
          baseUrl: baseUrl,
          password: password,
          username: username,
          cleartextConfirmedOrigin: cleartextConfirmedOrigin,
          certificatePinSha256: certificatePinSha256,
        );
    final owned = _client == null;
    String? sessionID;
    try {
      try {
        await client.health().timeout(const Duration(seconds: 15));
      } catch (error) {
        return ProviderSessionResult(
          outcome: ProviderSessionOutcome.unavailable,
          detail: '$error',
          elapsed: DateTime.now().difference(started),
        );
      }

      // The provider has to be in the server's runtime, or the session fails
      // with a message about an unknown model instead of the truth: the
      // config was written but never loaded.
      final providers = await client.providers();
      if (!providers.any((provider) => provider.id == providerID)) {
        return ProviderSessionResult(
          outcome: ProviderSessionOutcome.notLoaded,
          detail: providerID,
          elapsed: DateTime.now().difference(started),
        );
      }

      final session = await client.createSession(
        title: 'Provider test',
        model: Api2ModelRef(id: model, providerID: providerID),
      );
      sessionID = session.id;
      await client.prompt(sessionID, text: promptText);
      try {
        await client.wait(sessionID).timeout(timeout);
      } on Object catch (error) {
        final slow = error is TimeoutException || error is DioException;
        return ProviderSessionResult(
          outcome: slow
              ? ProviderSessionOutcome.timeout
              : ProviderSessionOutcome.failed,
          detail: '$error',
          elapsed: DateTime.now().difference(started),
        );
      }
      final page = await client.messages(sessionID, limit: 20);
      return judgeProviderSession(
        page.data,
        elapsed: DateTime.now().difference(started),
      );
    } on Api2AuthRequired catch (error) {
      return ProviderSessionResult(
        outcome: ProviderSessionOutcome.unavailable,
        detail: error.message,
        elapsed: DateTime.now().difference(started),
      );
    } on Api2Error catch (error) {
      return ProviderSessionResult(
        outcome: ProviderSessionOutcome.rejected,
        detail: error.message,
        elapsed: DateTime.now().difference(started),
      );
    } catch (error) {
      return ProviderSessionResult(
        outcome: ProviderSessionOutcome.failed,
        detail: '$error',
        elapsed: DateTime.now().difference(started),
      );
    } finally {
      if (sessionID != null) {
        // Best effort: a session that cannot be deleted must not turn a
        // passing test into a failing one, but it must be tried.
        try {
          await client.deleteSession(sessionID);
        } catch (_) {}
      }
      if (owned) client.close();
    }
  }
}
