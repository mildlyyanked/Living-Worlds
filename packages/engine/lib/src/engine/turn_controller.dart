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
import '../llm/contract.dart';
import '../llm/llm_client.dart';
import '../model/event.dart';
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

  /// Observation prompt: the player looks/examines to learn, not to act. The
  /// engine discards any deltas regardless, but we also ask the model to keep
  /// the turn purely descriptive so the narrative reads as an observation.
  static const String observeSystemPrompt = '''
You are the narrative engine of a living world. The player is OBSERVING, not
acting: they examine their surroundings, someone, or something to gain
information. Describe vividly in second person what the character perceives —
details, clues, atmosphere, what can be inferred. Do NOT advance time and do
NOT change any state. Return strict JSON:
{"narrative": "...", "proposed_deltas": {}, "peril": false,
"wiki_candidates": [{"title":"","category":"","body":"","tags":[]}]}
You may surface wiki_candidates for notable facts you reveal. Tools available:
query_wiki, query_relationship, query_inventory.''';

  /// Phase 1 of a two-step turn: resolve ONLY the mechanical consequences of
  /// the action — no prose. Keeps output tiny and grounds the later narrative
  /// in real numbers.
  static const String consequencesSystemPrompt = '''
You are the deterministic consequence resolver of a living world. The player
attempts an action. Decide ONLY its concrete consequences and return strict
JSON — NO narrative, NO prose:
{"proposed_deltas": {"clock_advance_minutes": int,
"inventory": [{"op":"grant|remove|use","item":"","qty":1,"reason":""}],
"stats": [{"key":"","op":"delta|set","value":0,"reason":""}],
"status": [{"op":"add|remove","key":"","severity":1,"reason":""}],
"relationships": [{"to":"char_id","dim":"","delta":0,"reason":""}],
"quest": [{"quest_id":"","op":"progress|complete|fail","step_id":"","reason":""}]},
"peril": bool, "wiki_candidates": [{"title":"","category":"","body":"","tags":[]}]}
Be realistic and restrained: most actions take a few minutes and change little.
Only propose changes the action actually causes; leave arrays empty otherwise.
You PROPOSE — the engine validates and may clamp or reject. peril is a hint.
Tools available first: query_wiki, query_relationship, query_inventory.''';

  /// Phase 2 of a two-step turn: given the action and the engine-RESOLVED
  /// changes, write the account. Deliberately terse.
  static const String narrativeSystemPrompt = '''
You are the narrator of a living world. Given the player's action and the
RESOLVED outcome, write a SHORT, direct, second-person account of what happens
— at most 1-3 sentences. Ground it strictly in the listed changes; do NOT
invent new items, injuries, time, or outcomes beyond them. Include dialogue
only when a character actually speaks, in double quotes. Plain and concrete,
never florid or padded. If nothing material changed, say so briefly.''';

  /// Run one full gameplay turn for [actorId]. When [observe] is true the turn
  /// is a non-consequential observation: no clock advance, no deltas, no death.
  Future<CommittedTurn> playTurn({
    required String actorId,
    required String userInput,
    List<String> presentCharacterIds = const [],
    bool observe = false,
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

    final engine = TurnEngine(config: config);
    final tools = RepositoryToolHandler(repo, projection);

    // 2. Phase 1 — get consequences (deltas only for actions; a descriptive
    // pass for observations, which have none).
    final started = _clock();
    final phase1 = await llm.completeTurn(
      systemPrompt: observe ? observeSystemPrompt : consequencesSystemPrompt,
      context: assembled.text,
      userInput: userInput,
      tools: tools,
    );
    var latencyMs =
        _clock().difference(started).inMilliseconds + phase1.usage.latencyMs;

    // 3. Validate + run subsystems (pure, deterministic, seeded). For actions
    // we strip any narrative the resolver leaked — the narrative is phase 2.
    final phase1Output = observe
        ? phase1.output
        : TurnOutput(
            narrative: '',
            proposedDeltas: phase1.output.proposedDeltas,
            peril: phase1.output.peril,
            wikiCandidates: phase1.output.wikiCandidates,
            narratedInProse: phase1.output.narratedInProse,
          );

    var phase1Usage = LlmUsage(
      model: phase1.usage.model,
      promptTokens: phase1.usage.promptTokens,
      completionTokens: phase1.usage.completionTokens,
      embeddingTokens: phase1.usage.embeddingTokens + embeddingTokens,
      computedCostUsd: phase1.usage.computedCostUsd,
      latencyMs: latencyMs,
      cached: phase1.usage.cached,
    );

    final result = engine.runTurn(
      projection: projection,
      input: TurnInput(
        actorId: actorId,
        userInput: userInput,
        output: phase1Output,
        observationOnly: observe,
      ),
      now: _clock(),
      toolExchanges: phase1.toolExchanges,
      contextSections: assembled.sections,
      usage: phase1Usage,
      rawLlmJson: phase1.rawJson ?? jsonEncode(phase1Output.toJson()),
      contextText: assembled.text,
    );

    // For observations there is no phase 2: the descriptive text came from
    // phase 1. For actions, phase 2 narrates strictly from the resolved
    // changes so the story never claims something the engine rejected.
    var events = result.events;
    var narrativeOut = phase1.output.narrative;
    var report = result.report;
    var totalUsage = phase1Usage;

    if (!observe) {
      final changes = _changesDigest(result);
      final narrativePrompt = _narrativePrompt(actor, userInput, changes);
      final startedNarr = _clock();
      final narration = await llm.narrate(
        systemPrompt: narrativeSystemPrompt,
        context: _liteContext(actor, projection, presentCharacterIds),
        action: userInput,
        changes: changes,
      );
      latencyMs += _clock().difference(startedNarr).inMilliseconds +
          narration.usage.latencyMs;
      narrativeOut = narration.text.isEmpty
          ? (changes.isEmpty ? 'Nothing changes.' : changes)
          : narration.text;

      totalUsage = LlmUsage(
        model: phase1Usage.model,
        promptTokens: phase1Usage.promptTokens + narration.usage.promptTokens,
        completionTokens:
            phase1Usage.completionTokens + narration.usage.completionTokens,
        embeddingTokens: phase1Usage.embeddingTokens,
        computedCostUsd:
            phase1Usage.computedCostUsd + narration.usage.computedCostUsd,
        latencyMs: latencyMs,
        cached: phase1Usage.cached && narration.usage.cached,
      );
      report = result.report.copyWith(
        usage: totalUsage,
        narrativePrompt: narrativePrompt,
        narrativeText: narrativeOut,
      );

      // Rebuild the TurnCommitted event (events.first) with the phase-2
      // narrative and the augmented debug report.
      final committed = events.first;
      final payload = Map<String, Object?>.of(committed.payload)
        ..['narrative'] = narrativeOut;
      final cause = Map<String, Object?>.of(committed.cause)
        ..['debug_report'] = report.toJson();
      events = [
        Event(
          id: committed.id,
          worldId: committed.worldId,
          seq: committed.seq,
          timeline: committed.timeline,
          subjectiveClock: committed.subjectiveClock,
          type: committed.type,
          payload: payload,
          cause: cause,
          createdAt: committed.createdAt,
        ),
        ...events.skip(1),
      ];
    }

    // 4. Commit events (atomic) -> recompute projection.
    await repo.appendEvents(events);

    // Meetings write canon (§4.4): when other characters were present, the
    // turn's outcome becomes a SharedEvent on every participant's timeline,
    // stamped with the actor's post-turn subjective time. First-writer-wins.
    final others = [
      for (final id in presentCharacterIds)
        if (id != actorId && projection.characters.containsKey(id)) id
    ];
    // Observations write no canon: nothing happened that others must narrate
    // around.
    if (!observe && others.isNotEmpty) {
      final afterTurn = await repo.projection();
      await rendezvous.commitSharedEvent(
        projection: afterTurn,
        writerId: actorId,
        participants: [actorId, ...others],
        summary: narrativeOut.length <= 240
            ? narrativeOut
            : '${narrativeOut.substring(0, 237)}...',
        detail: 'user input: $userInput',
        cause: {'turn_id': 'turn-${events.first.seq}'},
      );
    }
    final updated = await repo.projection();

    costLog.record(CostLogEntry(
      worldId: projection.world!.id,
      turnSeq: events.first.seq,
      usage: totalUsage,
      at: _clock(),
    ));

    // 5. Render.
    return CommittedTurn(
      narrative: narrativeOut,
      notifications: result.notifications,
      report: report,
      projection: updated,
      turnSeq: events.first.seq,
      died: result.died,
    );
  }

  /// Compact, human-readable digest of what the engine actually committed —
  /// fed to the narrator so the prose matches the numbers.
  String _changesDigest(TurnResult r) {
    final notes = r.notifications.where((n) => n.trim().isNotEmpty).toList();
    return notes.join('; ');
  }

  /// Minimal grounding context for the narrator (kept tiny to hold cost down):
  /// who the character is, who is present, and their most recent beat.
  String _liteContext(
    dynamic actor,
    WorldProjection projection,
    List<String> presentIds,
  ) {
    final b = StringBuffer()..writeln('CHARACTER: ${actor.name}');
    final bio = actor.bio as String;
    if (bio.isNotEmpty) {
      b.writeln(bio.length <= 200 ? bio : '${bio.substring(0, 200)}…');
    }
    final present = [
      for (final id in presentIds)
        if (id != actor.id && projection.characters[id] != null)
          projection.characters[id]!.name
    ];
    if (present.isNotEmpty) b.writeln('PRESENT: ${present.join(', ')}');
    final turns = projection.turnsFor(actor.id as String);
    if (turns.isNotEmpty) {
      final last = turns.last.narrative;
      b.writeln(
          'PREVIOUSLY: ${last.length <= 200 ? last : '${last.substring(0, 200)}…'}');
    }
    return b.toString().trimRight();
  }

  String _narrativePrompt(dynamic actor, String action, String changes) =>
      'ACTION: $action\nRESOLVED CHANGES: ${changes.isEmpty ? 'none' : changes}';
}
