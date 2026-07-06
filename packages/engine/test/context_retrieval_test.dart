import 'package:living_worlds_engine/living_worlds_engine.dart';
import 'package:test/test.dart';

import 'helpers/fixtures.dart';

void main() {
  group('context assembler (§6)', () {
    late InMemoryRepository repo;

    setUp(() async {
      repo = await seededRepo(InMemoryRepository());
    });

    Future<WorldProjection> play(int turns) async {
      const engine = TurnEngine();
      for (var i = 0; i < turns; i++) {
        final p = await repo.projection();
        final r = engine.runTurn(
          projection: p,
          input: TurnInput(
              actorId: 'ash',
              userInput: 'step $i',
              output:
                  calmTurn(narrative: 'Narrative for step $i.', minutes: 10)),
          now: t0,
        );
        await repo.appendEvents(r.events);
      }
      return repo.projection();
    }

    test('sheet and vitals are always included, even over budget', () async {
      final p = await play(1);
      final tiny = const ContextAssembler(budgetTokens: 1).assemble(
        projection: p,
        actorId: 'ash',
      );
      final byName = {for (final s in tiny.sections) s.section: s};
      expect(byName['character_sheet']!.included, isTrue);
      expect(byName['clock_status_inventory']!.included, isTrue);
      expect(tiny.text, contains('CHARACTER: Ash'));
      expect(tiny.text, contains('inventory'));
    });

    test('sections report token counts and inclusion for the debug panel',
        () async {
      final p = await play(3);
      final assembled =
          const ContextAssembler().assemble(projection: p, actorId: 'ash');
      expect(assembled.sections, isNotEmpty);
      for (final s in assembled.sections) {
        expect(s.tokens, greaterThan(0));
      }
      expect(assembled.sections.map((s) => s.section),
          containsAll(['character_sheet', 'active_quests', 'recent_turns']));
    });

    test('lower-priority sections are dropped first under pressure', () async {
      final service = WorldService(repo, clock: fixedClock());
      for (var i = 0; i < 30; i++) {
        await service.createWikiEntry(WikiEntry(
          id: 'wiki-$i',
          worldId: 'world-1',
          title: 'Entry $i',
          category: 'Lore',
          body: 'Body of entry $i. ' * 40,
        ));
      }
      final p = await play(6);
      final squeezed = const ContextAssembler(budgetTokens: 400)
          .assemble(projection: p, actorId: 'ash', semanticEntries: [
        p.wiki['wiki-0']!,
        p.wiki['wiki-1']!,
      ]);
      final byName = {for (final s in squeezed.sections) s.section: s};
      expect(byName['character_sheet']!.included, isTrue);
      expect(byName['wiki_index']!.included, isFalse,
          reason: '30 long index lines blow the small budget');
      expect(byName['semantic_wiki']!.included, isFalse,
          reason: 'semantic bodies are low priority and huge');
      expect(squeezed.totalTokens, lessThanOrEqualTo(400));
    });

    test('verbatim slice keeps the most recent turns', () async {
      final p = await play(12);
      final assembled = const ContextAssembler(recentTurnsVerbatim: 4)
          .assemble(projection: p, actorId: 'ash');
      expect(assembled.text, contains('Narrative for step 11.'));
      expect(assembled.text, isNot(contains('Narrative for step 3.')));
    });

    test('affordances of held items are surfaced to the model (§4.1)',
        () async {
      const engine = TurnEngine();
      var p = await repo.projection();
      final r = engine.runTurn(
        projection: p,
        input: const TurnInput(
          actorId: 'ash',
          userInput: 'take key',
          output: TurnOutput(
            narrative: 'Key acquired.',
            proposedDeltas: ProposedDeltas(inventory: [
              InventoryOp(op: InventoryOpKind.grant, item: 'rusty key')
            ]),
          ),
        ),
        now: t0,
      );
      await repo.appendEvents(r.events);
      p = await repo.projection();
      final assembled =
          const ContextAssembler().assemble(projection: p, actorId: 'ash');
      expect(assembled.text, contains('[enables: unlock]'));
    });
  });

  group('retrieval (§5.3)', () {
    test('cosine similarity basics', () {
      expect(cosineSimilarity([1, 0], [1, 0]), closeTo(1, 1e-12));
      expect(cosineSimilarity([1, 0], [0, 1]), closeTo(0, 1e-12));
      expect(cosineSimilarity([1, 1], [-1, -1]), closeTo(-1, 1e-12));
      expect(cosineSimilarity([], []), 0);
      expect(cosineSimilarity([1], [1, 2]), 0, reason: 'dim mismatch');
    });

    test('topK is deterministic under ties', () {
      final items = ['a', 'b', 'c'];
      final picked = topKByCosine([1.0, 0.0], items, (s) => [1.0, 0.0], k: 2);
      expect(picked, ['a', 'b']);
    });

    test('fixture embeddings rank overlapping text higher', () async {
      final e = FixtureEmbeddingClient();
      final tunnel =
          await e.embed('a drowned smuggling tunnel beneath the harbor');
      final query = await e.embed('the smuggling tunnel under the harbor');
      final peaks = await e.embed('glacial mountains and goat herders');
      expect(cosineSimilarity(query, tunnel),
          greaterThan(cosineSimilarity(query, peaks)));
    });
  });

  group('rolling summarizer (§6)', () {
    test('folds old turns into a cached summary event', () async {
      final repo = await seededRepo(InMemoryRepository());
      const engine = TurnEngine();
      for (var i = 0; i < 10; i++) {
        final p = await repo.projection();
        final r = engine.runTurn(
          projection: p,
          input: TurnInput(
              actorId: 'ash',
              userInput: 'step $i',
              output: calmTurn(narrative: 'Narrative $i.', minutes: 5)),
          now: t0,
        );
        await repo.appendEvents(r.events);
      }

      final llm = FixtureLlmClient(
          completions: ['Ash walked ten steps, uneventfully.']);
      final summarizer = RollingSummarizer(
          repo: repo, llm: llm, keepVerbatim: 4, clock: fixedClock());
      expect(await summarizer.needsSummarization('ash'), isTrue);
      final event = await summarizer.summarize('ash');
      expect(event!.type, EventType.summaryCached);

      final p = await repo.projection();
      expect(p.summaries['ash']!.summary, contains('ten steps'));
      expect(await summarizer.needsSummarization('ash'), isFalse,
          reason: 'cache is fresh now');

      // The assembler now offers the summary section.
      final assembled = const ContextAssembler(recentTurnsVerbatim: 4)
          .assemble(projection: p, actorId: 'ash');
      expect(assembled.text, contains('EARLIER (summarized)'));
    });

    test('below threshold, no summarization happens', () async {
      final repo = await seededRepo(InMemoryRepository());
      final llm = FixtureLlmClient();
      final summarizer = RollingSummarizer(
          repo: repo, llm: llm, keepVerbatim: 8, clock: fixedClock());
      expect(await summarizer.needsSummarization('ash'), isFalse);
      expect(await summarizer.summarize('ash'), isNull);
    });
  });
}
