/// The Turn Controller (§0, §3): a turn is a transaction.
///
/// 1. assemble context (budgeted)   2. call LLM (tool loop)
/// 3. validate + run engine subsystems (pure, deterministic, seeded)
/// 4. commit events -> recompute projections   5. render narrative +
/// mechanical notifications (+ debug report).
library;

import 'dart:convert';

import '../context/assembler.dart';
import '../cost/cost_log.dart';
import '../debug/report.dart';
import '../llm/llm_client.dart';
import '../model/wiki.dart';
import '../projection/projection.dart';
import '../repo/world_repository.dart';
import '../retrieval/embedding_client.dart';
import 'config.dart';
import 'rendezvous.dart';
import 'turn_engine.dart';

/// What the UI renders after a committed turn (§3.6).
class CommittedTurn {
  const CommittedTurn({
    required this.narrative,
    required this.notifications,
    required this.report,
    required this.projection,
    required this.turnSeq,
    required this.died,
  });

  final String narrative;
  final List<String> notifications;
  final TurnDebugReport report;
  final WorldProjection projection;
  final int turnSeq;
  final bool died;
}

/// Wires the model's tool loop (§2) to live world state:
/// query_wiki / query_relationship / query_inventory.
class RepositoryToolHandler implements LlmToolHandler {
  RepositoryToolHandler(this.repo, this.projection);

  final WorldRepository repo;
  final WorldProjection projection;

  @override
  Future<Object?> handle(LlmToolCall call) async {
    switch (call.name) {
      case 'query_wiki':
        final entries = await repo.structuredWikiQuery(
          title: call.args['title'] as String?,
          category: call.args['category'] as String?,
          freeText: call.args['free_text'] as String?,
        );
        return [
          for (final w in entries)
            {'title': w.title, 'category': w.category, 'body': w.body}
        ];
      case 'query_relationship':
        final a = call.args['char_a'] as String?;
        final b = call.args['char_b'] as String?;
        return [
          for (final e in projection.edges.values)
            if ((a == null || e.fromChar == a || e.toChar == a) &&
                (b == null || e.fromChar == b || e.toChar == b))
              e.toJson()
        ];
      case 'query_inventory':
        final c = projection.characters[call.args['char_id'] as String?];
        if (c == null) return {'error': 'no such character'};
        return [
          for (final i in c.inventory)
            {
              'item': projection.itemDefs[i.defId]?.name ?? i.defId,
              'qty': i.qty,
              'affordances':
                  projection.itemDefs[i.defId]?.affordances ?? const [],
            }
        ];
      default:
        return {'error': 'unknown tool ${call.name}'};
    }
  }
}

class TurnController {
  TurnController({
    required this.repo,
    required this.llm,
    this.embedder,
    this.config = const EngineConfig(),
    this.assembler = const ContextAssembler(),
    this.semanticK = 4,
    CostLog? costLog,
    DateTime Function()? clock,
  })  : costLog = costLog ?? CostLog(),
        _clock = clock ?? DateTime.now;

  final WorldRepository repo;
  final LlmClient llm;
  final EmbeddingClient? embedder;
  final EngineConfig config;
  final ContextAssembler assembler;
  final int semanticK;
  final CostLog costLog;
  final DateTime Function() _clock;

  static const String systemPrompt = '''
You are the narrative engine of a living world. Narrate vividly in second
person. You PROPOSE state changes; a deterministic engine validates them —
never assume a proposal succeeded. Return strict JSON:
{"narrative": "...", "proposed_deltas": {"clock_advance_minutes": int,
"inventory": [{"op":"grant|remove|use","item":"","qty":1,"reason":""}],
"stats": [{"key":"","op":"delta|set","value":0,"reason":""}],
"status": [{"op":"add|remove","key":"","severity":1,"reason":""}],
"relationships": [{"to":"char_id","dim":"","delta":0,"reason":""}],
"quest": [{"quest_id":"","op":"progress|complete|fail","step_id":"","reason":""}]},
"peril": bool, "wiki_candidates": [{"title":"","category":"","body":"","tags":[]}]}
Tools available before finalizing: query_wiki, query_relationship,
query_inventory. peril is a hint; the engine decides deaths.''';

  /// Run one full gameplay turn for [actorId].
  Future<CommittedTurn> playTurn({
    required String actorId,
    required String userInput,
    List<String> presentCharacterIds = const [],
  }) async {
    // 1. Assemble context (budgeted, §6).
    final projection = await repo.projection();
    final rendezvous = RendezvousService(repo, clock: _clock);

    final cameoBlocks = <String>[];
    for (final id in presentCharacterIds) {
      if (id == actorId) continue;
      final snap = await rendezvous.cameoSnapshot(
          projection: projection, viewerId: actorId, cameoId: id);
      cameoBlocks.add(snap.toContextBlock());
    }

    final actor = projection.characters[actorId]!;
    final fixedCanon = rendezvous.fixedCanonFor(
      projection: projection,
      characterId: actorId,
      atClock: actor.subjectiveClock + config.perTurnCapMinutes,
    );

    // Semantic retrieval: embed (recent window + user input) -> top-k (§5.3).
    var semanticEntries = <WikiEntry>[];
    var retrievalDetail = '';
    var embeddingTokens = 0;
    if (embedder != null && projection.wiki.isNotEmpty) {
      final turns = projection.turnsFor(actorId);
      final window = turns.isEmpty
          ? ''
          : turns
              .sublist(turns.length < 3 ? 0 : turns.length - 3)
              .map((t) => t.narrative)
              .join('\n');
      final query = await embedder!.embed('$window\n$userInput');
      embeddingTokens = embedder!.lastTokenCount;
      semanticEntries = await repo.semanticSearch(query, k: semanticK);
      retrievalDetail =
          'query=(recent window + input); hits=${semanticEntries.map((e) => e.title).join(', ')}';
    }

    final assembled = assembler.assemble(
      projection: projection,
      actorId: actorId,
      cameoBlocks: cameoBlocks,
      fixedCanon: fixedCanon,
      semanticEntries: semanticEntries,
      retrievalDetail: retrievalDetail,
    );

    // 2. LLM with tool loop.
    final started = _clock();
    final llmResult = await llm.completeTurn(
      systemPrompt: systemPrompt,
      context: assembled.text,
      userInput: userInput,
      tools: RepositoryToolHandler(repo, projection),
    );
    final latencyMs =
        _clock().difference(started).inMilliseconds + llmResult.usage.latencyMs;

    final usage = LlmUsage(
      model: llmResult.usage.model,
      promptTokens: llmResult.usage.promptTokens,
      completionTokens: llmResult.usage.completionTokens,
      embeddingTokens: llmResult.usage.embeddingTokens + embeddingTokens,
      computedCostUsd: llmResult.usage.computedCostUsd,
      latencyMs: latencyMs,
      cached: llmResult.usage.cached,
    );

    // 3. Validate + run subsystems (pure, deterministic, seeded).
    final engine = TurnEngine(config: config);
    final result = engine.runTurn(
      projection: projection,
      input: TurnInput(
        actorId: actorId,
        userInput: userInput,
        output: llmResult.output,
      ),
      now: _clock(),
      toolExchanges: llmResult.toolExchanges,
      contextSections: assembled.sections,
      usage: usage,
      rawLlmJson: llmResult.rawJson ?? jsonEncode(llmResult.output.toJson()),
    );

    // 4. Commit events (atomic) -> recompute projection.
    await repo.appendEvents(result.events);
    final updated = await repo.projection();

    costLog.record(CostLogEntry(
      worldId: projection.world!.id,
      turnSeq: result.events.first.seq,
      usage: usage,
      at: _clock(),
    ));

    // 5. Render.
    return CommittedTurn(
      narrative: llmResult.output.narrative,
      notifications: result.notifications,
      report: result.report,
      projection: updated,
      turnSeq: result.events.first.seq,
      died: result.died,
    );
  }
}
