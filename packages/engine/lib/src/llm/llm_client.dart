/// LLM client seam (§11): `LlmClient` interface with a fixture implementation
/// for tests and an OpenRouter implementation for production.
library;

import 'dart:convert';

import 'contract.dart';

/// A tool invocation the model makes during its pre-finalization tool loop
/// (§2): query_wiki / query_relationship / query_inventory.
class LlmToolCall {
  const LlmToolCall({required this.name, required this.args});

  final String name;
  final Map<String, Object?> args;

  Map<String, Object?> toJson() => {'name': name, 'args': args};
}

/// Record of one tool round-trip, kept for the debug report (§9).
class LlmToolExchange {
  const LlmToolExchange({required this.call, required this.result});

  final LlmToolCall call;
  final Object? result;

  Map<String, Object?> toJson() => {
        'call': call.toJson(),
        'result': result,
      };
}

/// Token/cost accounting for one completion (§10).
class LlmUsage {
  const LlmUsage({
    this.model = '',
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.embeddingTokens = 0,
    this.computedCostUsd = 0,
    this.latencyMs = 0,
    this.cached = false,
  });

  final String model;
  final int promptTokens;
  final int completionTokens;
  final int embeddingTokens;
  final double computedCostUsd;
  final int latencyMs;
  final bool cached;

  Map<String, Object?> toJson() => {
        'model': model,
        'prompt_tokens': promptTokens,
        'completion_tokens': completionTokens,
        'embedding_tokens': embeddingTokens,
        'computed_cost': computedCostUsd,
        'latency_ms': latencyMs,
        'cached': cached,
      };

  factory LlmUsage.fromJson(Map<String, Object?> json) => LlmUsage(
        model: json['model'] as String? ?? '',
        promptTokens: json['prompt_tokens'] as int? ?? 0,
        completionTokens: json['completion_tokens'] as int? ?? 0,
        embeddingTokens: json['embedding_tokens'] as int? ?? 0,
        computedCostUsd: (json['computed_cost'] as num? ?? 0).toDouble(),
        latencyMs: json['latency_ms'] as int? ?? 0,
        cached: json['cached'] as bool? ?? false,
      );
}

/// Result of one full turn call: structured output + tool transcript + usage.
class LlmTurnResult {
  const LlmTurnResult({
    required this.output,
    this.toolExchanges = const [],
    this.usage = const LlmUsage(),
    this.rawJson,
  });

  final TurnOutput output;
  final List<LlmToolExchange> toolExchanges;
  final LlmUsage usage;

  /// Raw pre-validation model output for the debug report (§9).
  final String? rawJson;
}

/// Result of the phase-2 "narrate" call in a two-step turn: the concise
/// narrative text plus usage for cost accounting.
class LlmNarration {
  const LlmNarration({required this.text, this.usage = const LlmUsage()});

  final String text;
  final LlmUsage usage;
}

/// Answers the model's tool-loop queries against current world state.
/// The turn controller wires this to the repository/projection.
abstract class LlmToolHandler {
  Future<Object?> handle(LlmToolCall call);
}

/// The seam between game and model. Production: OpenRouter. Tests: fixtures.
abstract class LlmClient {
  /// Run one gameplay turn: the model may call tools via [tools] before
  /// returning its final structured output.
  Future<LlmTurnResult> completeTurn({
    required String systemPrompt,
    required String context,
    required String userInput,
    required LlmToolHandler tools,
  });

  /// Free-form completion used by seeding sessions, time-skip retrospectives
  /// and rolling summarization. Expected to return strict JSON when
  /// [expectJson] is true.
  Future<String> complete({
    required String systemPrompt,
    required String prompt,
    bool expectJson = false,
  });

  /// Phase 2 of a two-step turn (§ two-step turns): given the player's [action]
  /// and the engine-RESOLVED mechanical [changes], write a concise, direct
  /// narrative. No JSON, no proposed state — description grounded in [changes].
  Future<LlmNarration> narrate({
    required String systemPrompt,
    required String context,
    required String action,
    required String changes,
  });
}

/// Deterministic fixture client for tests and the CLI harness (§11).
///
/// Feed it a queue of canned [TurnOutput]s (or raw JSON strings). Optionally
/// script tool calls to exercise the tool loop against the real handler.
class FixtureLlmClient implements LlmClient {
  FixtureLlmClient({
    List<TurnOutput>? turnOutputs,
    List<String>? completions,
    List<String>? narrations,
    this.scriptedToolCalls = const [],
  })  : _turnQueue = List.of(turnOutputs ?? const []),
        _completionQueue = List.of(completions ?? const []),
        _narrationQueue = List.of(narrations ?? const []);

  final List<TurnOutput> _turnQueue;
  final List<String> _completionQueue;

  /// Optional scripted phase-2 narratives; when empty, [narrate] echoes the
  /// action + resolved changes deterministically (no queue consumed).
  final List<String> _narrationQueue;

  /// Tool calls the fixture "model" makes before finalizing each turn.
  final List<LlmToolCall> scriptedToolCalls;

  /// Every tool exchange observed, for assertions.
  final List<LlmToolExchange> observedExchanges = [];

  void enqueueTurn(TurnOutput output) => _turnQueue.add(output);
  void enqueueCompletion(String text) => _completionQueue.add(text);

  @override
  Future<LlmTurnResult> completeTurn({
    required String systemPrompt,
    required String context,
    required String userInput,
    required LlmToolHandler tools,
  }) async {
    if (_turnQueue.isEmpty) {
      throw StateError('FixtureLlmClient: no more canned turn outputs');
    }
    final exchanges = <LlmToolExchange>[];
    for (final call in scriptedToolCalls) {
      final result = await tools.handle(call);
      final exchange = LlmToolExchange(call: call, result: result);
      exchanges.add(exchange);
      observedExchanges.add(exchange);
    }
    final output = _turnQueue.removeAt(0);
    return LlmTurnResult(
      output: output,
      toolExchanges: exchanges,
      usage: const LlmUsage(model: 'fixture', cached: true),
      rawJson: jsonEncode(output.toJson()),
    );
  }

  @override
  Future<String> complete({
    required String systemPrompt,
    required String prompt,
    bool expectJson = false,
  }) async {
    if (_completionQueue.isEmpty) {
      throw StateError('FixtureLlmClient: no more canned completions');
    }
    return _completionQueue.removeAt(0);
  }

  @override
  Future<LlmNarration> narrate({
    required String systemPrompt,
    required String context,
    required String action,
    required String changes,
  }) async {
    final text = _narrationQueue.isNotEmpty
        ? _narrationQueue.removeAt(0)
        : 'You $action.${changes.isEmpty ? '' : ' $changes'}';
    return LlmNarration(
      text: text,
      usage: const LlmUsage(model: 'fixture', cached: true),
    );
  }
}
