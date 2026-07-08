/// Tests for the feature batch: observation turns, prose-fallback monitoring,
/// character generation, and world-bio designation.
library;

import 'dart:convert';

import 'package:living_worlds_engine/living_worlds_engine.dart';
import 'package:test/test.dart';

import 'helpers/fixtures.dart';

void main() {
  group('observation turns are non-consequential', () {
    test('engine discards deltas, holds the clock, queues candidates', () {
      const engine = TurnEngine();
      final projection = WorldProjection.replay([
        Event(
          id: 'e0',
          worldId: 'world-1',
          seq: 0,
          timeline: worldTimeline,
          subjectiveClock: 0,
          type: EventType.worldCreated,
          payload: {'world': testWorld().toJson()},
          createdAt: t0,
        ),
        Event(
          id: 'e1',
          worldId: 'world-1',
          seq: 1,
          timeline: 'ash',
          subjectiveClock: 0,
          type: EventType.characterCreated,
          payload: {
            'character': ash().copyWith(subjectiveClock: 120).toJson(),
          },
          createdAt: t0,
        ),
      ]);

      final result = engine.runTurn(
        projection: projection,
        input: const TurnInput(
          actorId: 'ash',
          userInput: 'study the mural',
          observationOnly: true,
          output: TurnOutput(
            narrative: 'The mural shows a drowned city.',
            // These would normally apply; observation must ignore them all.
            proposedDeltas: ProposedDeltas(
              clockAdvanceMinutes: 60,
              stats: [StatOp(key: 'coin', op: StatOpKind.delta, value: 5)],
            ),
            wikiCandidates: [
              WikiCandidate(
                  id: '',
                  title: 'Mural',
                  category: 'Lore',
                  body: 'A drowned city.')
            ],
          ),
        ),
        now: t0,
      );

      expect(result.died, isFalse);
      expect(result.clockFrom, 120);
      expect(result.clockTo, 120, reason: 'observation advances no clock');
      // Only a TurnCommitted (observation) + the queued candidate; no stat event.
      expect(result.events.map((e) => e.type), [
        EventType.turnCommitted,
        EventType.wikiCandidateQueued,
      ]);
      final committed = result.events.first;
      expect(committed.payload['observation'], isTrue);
      expect(committed.payload['clock_to'], 120);
    });

    test('projection records the observation but does not count it as a turn',
        () async {
      final repo = await seededRepo(InMemoryRepository());
      final llm = FixtureLlmClient(turnOutputs: [
        const TurnOutput(narrative: 'You peer into the fog.'),
      ]);
      final controller = TurnController(
          repo: repo, llm: llm, embedder: FixtureEmbeddingClient());
      await controller.playTurn(
          actorId: 'ash', userInput: 'look around', observe: true);

      final p = await repo.projection();
      expect(p.characters['ash']!.subjectiveClock, 0);
      expect(p.turnsFor('ash').single.observation, isTrue);
      expect(p.turnCount, 0,
          reason: 'observations are not consequential turns');
    });
  });

  group('prose fallback is logged and monitored', () {
    test('a prose reply flags TurnOutput and increments the counter', () async {
      final prose = OpenRouterLlmClient.parseTurnOutput(
          'You stand at the heart of Beanabona.');
      expect(prose.narratedInProse, isTrue);

      final repo = await seededRepo(InMemoryRepository());
      final llm = FixtureLlmClient(turnOutputs: [prose, calmTurn()]);
      final controller = TurnController(
          repo: repo, llm: llm, embedder: FixtureEmbeddingClient());

      await controller.playTurn(actorId: 'ash', userInput: 'go');
      var p = await repo.projection();
      expect(p.turnCount, 1);
      expect(p.proseFallbackTurns, 1);

      // A well-formed turn does not bump the prose counter.
      await controller.playTurn(actorId: 'ash', userInput: 'again');
      p = await repo.projection();
      expect(p.turnCount, 2);
      expect(p.proseFallbackTurns, 1);
    });
  });

  group('character generation', () {
    test('structured bio + scenario + starting quest from the model', () async {
      final llm = FixtureLlmClient(completions: [
        jsonEncode({
          'bio': {
            'appearance': 'Weathered, salt-scarred hands.',
            'personality': 'Wary but fair.',
            'status': 'Dockside smuggler.',
            'background': 'Owes a debt to the Brine Guild.',
          },
          'opening_scenario': 'You crouch on a rain-slick pier as a Guild '
              'lantern sweeps the water.',
          'starting_quest': {
            'title': 'Clear the Guild debt',
            'steps': ['Find the ledger', 'Pay or burn it'],
          },
        }),
      ]);
      final c = await CharacterGenerator(llm: llm).generate(
        name: 'Mara',
        seedParagraph: 'A smuggler who owes the Guild.',
        worldName: 'Harborfall',
        worldBio: 'A drowned port city.',
      );
      expect(c.bio, contains('Appearance:'));
      expect(c.bio, contains('Background:'));
      expect(c.openingScenario, contains('pier'));
      expect(c.startingQuest, isNotNull);
      expect(c.startingQuest!.title, 'Clear the Guild debt');
      expect(c.startingQuest!.steps, hasLength(2));
      expect(c.startingQuest!.state, QuestState.active);
    });

    test('a prose (non-JSON) reply degrades to a usable fallback', () async {
      final llm = FixtureLlmClient(completions: [
        'Sure! Mara is a wary dockside smuggler with salt-scarred hands.',
      ]);
      final c = await CharacterGenerator(llm: llm).generate(
        name: 'Mara',
        seedParagraph: 'A smuggler who owes the Guild.',
        worldName: 'Harborfall',
        worldBio: '',
      );
      expect(c.bio, isNotEmpty);
      expect(c.openingScenario, contains('Mara'));
      expect(c.startingQuest, isNull);
    });
  });

  group('world bio designation', () {
    test('designate a wiki entry as the world overview and read it back',
        () async {
      final repo = await seededRepo(InMemoryRepository());
      final service = WorldService(repo, clock: fixedClock());
      await service.createWikiEntry(WikiEntry(
        id: 'wiki-overview',
        worldId: 'world-1',
        title: 'Harborfall',
        category: 'Lore',
        body: 'A drowned port ruled by tides and guilds.',
      ));
      await service.designateWorldBio('world-1', 'wiki-overview');

      final p = await repo.projection();
      expect(p.worldBioEntryId, 'wiki-overview');
      expect(p.worldBioText(), contains('drowned port'));

      await service.designateWorldBio('world-1', null);
      final cleared = await repo.projection();
      expect(cleared.worldBioEntryId, isNull);
    });
  });
}
