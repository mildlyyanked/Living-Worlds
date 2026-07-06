/// Cost & latency logging (§10): per turn
/// `{model, prompt_tokens, completion_tokens, embedding_tokens,
///   computed_cost, latency_ms, cached}` aggregated per session/world.
library;

import '../llm/llm_client.dart';

class CostLogEntry {
  const CostLogEntry({
    required this.worldId,
    required this.turnSeq,
    required this.usage,
    required this.at,
  });

  final String worldId;
  final int turnSeq;
  final LlmUsage usage;
  final DateTime at;

  Map<String, Object?> toJson() => {
        'world_id': worldId,
        'turn_seq': turnSeq,
        'usage': usage.toJson(),
        'at': at.toIso8601String(),
      };

  factory CostLogEntry.fromJson(Map<String, Object?> json) => CostLogEntry(
        worldId: json['world_id'] as String,
        turnSeq: json['turn_seq'] as int,
        usage: LlmUsage.fromJson(json['usage'] as Map<String, Object?>),
        at: DateTime.parse(json['at'] as String),
      );
}

class CostAggregate {
  const CostAggregate({
    required this.turns,
    required this.promptTokens,
    required this.completionTokens,
    required this.embeddingTokens,
    required this.totalCostUsd,
    required this.totalLatencyMs,
  });

  final int turns;
  final int promptTokens;
  final int completionTokens;
  final int embeddingTokens;
  final double totalCostUsd;
  final int totalLatencyMs;

  double get avgLatencyMs => turns == 0 ? 0 : totalLatencyMs / turns;

  Map<String, Object?> toJson() => {
        'turns': turns,
        'prompt_tokens': promptTokens,
        'completion_tokens': completionTokens,
        'embedding_tokens': embeddingTokens,
        'total_cost_usd': totalCostUsd,
        'total_latency_ms': totalLatencyMs,
        'avg_latency_ms': avgLatencyMs,
      };
}

class CostLog {
  final List<CostLogEntry> entries = [];

  void record(CostLogEntry entry) => entries.add(entry);

  CostAggregate aggregate({String? worldId}) {
    var turns = 0, prompt = 0, completion = 0, embedding = 0, latency = 0;
    var cost = 0.0;
    for (final e in entries) {
      if (worldId != null && e.worldId != worldId) continue;
      turns++;
      prompt += e.usage.promptTokens;
      completion += e.usage.completionTokens;
      embedding += e.usage.embeddingTokens;
      latency += e.usage.latencyMs;
      cost += e.usage.computedCostUsd;
    }
    return CostAggregate(
      turns: turns,
      promptTokens: prompt,
      completionTokens: completion,
      embeddingTokens: embedding,
      totalCostUsd: cost,
      totalLatencyMs: latency,
    );
  }
}
