/// TurnDebugReport (§9): a first-class object attached to the TurnCommitted
/// event's `cause`, so bugs are inspectable after the fact.
library;

import '../engine/validation.dart';
import '../llm/llm_client.dart';

class DeathEvalReport {
  const DeathEvalReport({
    required this.health,
    required this.probability,
    required this.seedTurn,
    required this.draw,
    required this.outcome,
    this.perilDeltaApplied = false,
    this.perilHint = false,
    this.instantTrigger,
    this.skippedNonLethal = false,
  });

  final double health;
  final double probability;
  final int seedTurn;
  final double draw;
  final bool outcome;

  /// Engine-observed: a harmful status was actually applied this turn.
  final bool perilDeltaApplied;

  /// The LLM's hint flag, recorded for comparison with what the engine saw.
  final bool perilHint;

  /// Set when death came from an engine instant trigger (lethal stack).
  final String? instantTrigger;

  /// True when the roll was skipped because the context is non-lethal
  /// (time-skips, §4.6).
  final bool skippedNonLethal;

  Map<String, Object?> toJson() => {
        'health': health,
        'p': probability,
        'seed_turn': seedTurn,
        'draw': draw,
        'outcome': outcome,
        'peril_delta_applied': perilDeltaApplied,
        'peril_hint': perilHint,
        'instant_trigger': instantTrigger,
        'skipped_non_lethal': skippedNonLethal,
      };

  factory DeathEvalReport.fromJson(Map<String, Object?> json) =>
      DeathEvalReport(
        health: (json['health'] as num).toDouble(),
        probability: (json['p'] as num).toDouble(),
        seedTurn: json['seed_turn'] as int,
        draw: (json['draw'] as num).toDouble(),
        outcome: json['outcome'] as bool,
        perilDeltaApplied: json['peril_delta_applied'] as bool? ?? false,
        perilHint: json['peril_hint'] as bool? ?? false,
        instantTrigger: json['instant_trigger'] as String?,
        skippedNonLethal: json['skipped_non_lethal'] as bool? ?? false,
      );
}

/// Per-section token counts from context assembly (§6, §9).
class ContextSectionReport {
  const ContextSectionReport({
    required this.section,
    required this.tokens,
    this.included = true,
    this.detail = '',
  });

  final String section;
  final int tokens;
  final bool included;

  /// e.g. which wiki entries were retrieved and why.
  final String detail;

  Map<String, Object?> toJson() => {
        'section': section,
        'tokens': tokens,
        'included': included,
        'detail': detail,
      };

  factory ContextSectionReport.fromJson(Map<String, Object?> json) =>
      ContextSectionReport(
        section: json['section'] as String,
        tokens: json['tokens'] as int,
        included: json['included'] as bool? ?? true,
        detail: json['detail'] as String? ?? '',
      );
}

class TurnDebugReport {
  const TurnDebugReport({
    this.rawLlmJson,
    this.decisions = const [],
    this.toolExchanges = const [],
    this.deathEval,
    this.contextSections = const [],
    this.usage = const LlmUsage(),
    this.notes = const [],
    this.contextText,
    this.narrativePrompt,
    this.narrativeText,
  });

  /// Raw LLM structured output pre-validation. In a two-step turn this is the
  /// phase-1 "consequences" JSON (deltas only).
  final String? rawLlmJson;

  /// Each delta: accepted / clamped(from->to) / rejected(reason).
  final List<DeltaDecision> decisions;
  final List<LlmToolExchange> toolExchanges;
  final DeathEvalReport? deathEval;
  final List<ContextSectionReport> contextSections;
  final LlmUsage usage;
  final List<String> notes;

  /// The full assembled context string sent to the model (phase 1). Lets the
  /// debug panel show exactly what the model saw (§ two-step turns debug).
  final String? contextText;

  /// The phase-2 prompt (action + resolved changes) sent to the narrator.
  final String? narrativePrompt;

  /// The phase-2 narrative the model returned.
  final String? narrativeText;

  TurnDebugReport copyWith({
    LlmUsage? usage,
    String? contextText,
    String? narrativePrompt,
    String? narrativeText,
  }) =>
      TurnDebugReport(
        rawLlmJson: rawLlmJson,
        decisions: decisions,
        toolExchanges: toolExchanges,
        deathEval: deathEval,
        contextSections: contextSections,
        usage: usage ?? this.usage,
        notes: notes,
        contextText: contextText ?? this.contextText,
        narrativePrompt: narrativePrompt ?? this.narrativePrompt,
        narrativeText: narrativeText ?? this.narrativeText,
      );

  Map<String, Object?> toJson() => {
        'raw_llm_json': rawLlmJson,
        'decisions': [for (final d in decisions) d.toJson()],
        'tool_exchanges': [for (final t in toolExchanges) t.toJson()],
        'death_eval': deathEval?.toJson(),
        'context_sections': [for (final c in contextSections) c.toJson()],
        'usage': usage.toJson(),
        'notes': notes,
        'context_text': contextText,
        'narrative_prompt': narrativePrompt,
        'narrative_text': narrativeText,
      };

  factory TurnDebugReport.fromJson(Map<String, Object?> json) =>
      TurnDebugReport(
        rawLlmJson: json['raw_llm_json'] as String?,
        decisions: [
          for (final d in json['decisions'] as List<Object?>? ?? <Object?>[])
            DeltaDecision.fromJson(d! as Map<String, Object?>)
        ],
        deathEval: json['death_eval'] == null
            ? null
            : DeathEvalReport.fromJson(
                json['death_eval'] as Map<String, Object?>),
        contextSections: [
          for (final c
              in json['context_sections'] as List<Object?>? ?? <Object?>[])
            ContextSectionReport.fromJson(c! as Map<String, Object?>)
        ],
        usage: json['usage'] == null
            ? const LlmUsage()
            : LlmUsage.fromJson(json['usage'] as Map<String, Object?>),
        notes: [
          for (final n in json['notes'] as List<Object?>? ?? <Object?>[])
            n! as String
        ],
        contextText: json['context_text'] as String?,
        narrativePrompt: json['narrative_prompt'] as String?,
        narrativeText: json['narrative_text'] as String?,
      );
}
