/// The shared conformance suite every WorldRepository implementation must
/// pass (§7, §11). Call [runRepositorySuite] with a factory per target.
library;

import 'dart:convert';

import 'package:living_worlds_engine/living_worlds_engine.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void runRepositorySuite(String name, Future<WorldRepository> Function() make) {
  group('repository conformance: $name', () {
    late WorldRepository repo;

    setUp(() async {
      repo = await make();
    });

    tearDown(() => repo.close());

    test('starts empty', () async {
      expect(await repo.lastSeq(), -1);
      expect(await repo.eventsUpTo(-1), isEmpty);
      expect(await repo.revertedSeqs(), isEmpty);
    });

    test('append + read round-trips events exactly', () async {
      await seededRepo(repo);
      final events = await repo.eventsUpTo(-1);
      expect(events, isNotEmpty);
      expect(events.first.type, EventType.worldCreated);
      // Payload fidelity through storage.
      final world =
          World.fromJson(events.first.payload['world'] as Map<String, Object?>);
      expect(world.name, 'Testhaven');
      expect(world.seed, 42);
      // Seq are dense and ordered.
      for (var i = 0; i < events.length; i++) {
        expect(events[i].seq, i);
      }
    });

    test('rejects seq gaps', () async {
      await seededRepo(repo);
      final last = await repo.lastSeq();
      final bad = Event(
        id: 'evt-bad',
        worldId: 'world-1',
        seq: last + 2,
        timeline: worldTimeline,
        subjectiveClock: 0,
        type: EventType.summaryCached,
        payload: const {'timeline': 'ash', 'upto_seq': 0, 'summary': ''},
        createdAt: t0,
      );
      await expectLater(
          repo.appendEvent(bad), throwsA(isA<WorldRepositoryException>()));
    });

    test('atomic batch: partial failure commits nothing', () async {
      await seededRepo(repo);
      final last = await repo.lastSeq();
      Event mk(int seq) => Event(
            id: 'evt-$seq',
            worldId: 'world-1',
            seq: seq,
            timeline: worldTimeline,
            subjectiveClock: 0,
            type: EventType.summaryCached,
            payload: const {'timeline': 'ash', 'upto_seq': 0, 'summary': ''},
            createdAt: t0,
          );
      await expectLater(repo.appendEvents([mk(last + 1), mk(last + 9)]),
          throwsA(isA<WorldRepositoryException>()));
      expect(await repo.lastSeq(), last);
    });

    test('projection rebuild honors atSeq and revert markers', () async {
      await seededRepo(repo);
      const engine = TurnEngine();
      final p0 = await repo.projection();
      final r = engine.runTurn(
        projection: p0,
        input: TurnInput(
            actorId: 'ash', userInput: 'walk', output: calmTurn(minutes: 45)),
        now: t0,
      );
      await repo.appendEvents(r.events);

      final before = await repo.projection(atSeq: r.events.first.seq - 1);
      expect(before.characters['ash']!.subjectiveClock, 0);

      final after = await repo.projection();
      expect(after.characters['ash']!.subjectiveClock, 45);

      await repo.revertAfter(r.events.first.seq - 1);
      final undone = await repo.projection();
      expect(undone.characters['ash']!.subjectiveClock, 0);
      expect(jsonEncode(undone.toJson()), jsonEncode(before.toJson()));

      await repo.unrevertUpTo(1 << 60);
      final redone = await repo.projection();
      expect(jsonEncode(redone.toJson()), jsonEncode(after.toJson()));
    });

    test('setRevertMarkers replaces the marker set', () async {
      await seededRepo(repo);
      await repo.setRevertMarkers({2, 3});
      expect(await repo.revertedSeqs(), {2, 3});
      await repo.setRevertMarkers({});
      expect(await repo.revertedSeqs(), isEmpty);
    });

    test('embeddings persist and drive semantic search', () async {
      await seededRepo(repo);
      final service = WorldService(repo, clock: fixedClock());
      final entries = [
        WikiEntry(
            id: 'wiki-gullet',
            worldId: 'world-1',
            title: 'The Gullet',
            category: 'Places',
            body: 'A drowned smuggling tunnel beneath the harbor.'),
        WikiEntry(
            id: 'wiki-ledger',
            worldId: 'world-1',
            title: 'The Salt Ledger',
            category: 'Lore',
            body: 'A cipher of debts kept by harbor smugglers.'),
        WikiEntry(
            id: 'wiki-peaks',
            worldId: 'world-1',
            title: 'Frostfang Peaks',
            category: 'Places',
            body: 'Glacial mountains far inland, home to goat herders.'),
      ];
      final embedder = FixtureEmbeddingClient();
      for (final e in entries) {
        await service.createWikiEntry(e);
        await repo.saveEmbedding(e.id, await embedder.embed(e.body));
      }

      final q = await embedder.embed('smuggling tunnel under the harbor');
      final hits = await repo.semanticSearch(q, k: 2);
      expect(hits.first.id, 'wiki-gullet');
      expect(hits.map((h) => h.id), isNot(contains('wiki-peaks')));
    });

    test('structured wiki query: title, category, free text', () async {
      await seededRepo(repo);
      final service = WorldService(repo, clock: fixedClock());
      await service.createWikiEntry(WikiEntry(
          id: 'wiki-gullet',
          worldId: 'world-1',
          title: 'The Gullet',
          category: 'Places',
          body: 'A drowned smuggling tunnel.',
          tags: const ['harbor', 'smuggling']));
      await service.createWikiEntry(WikiEntry(
          id: 'wiki-brynn',
          worldId: 'world-1',
          title: 'Brynn',
          category: 'Characters',
          body: 'A smuggler with a code.'));

      expect(await repo.structuredWikiQuery(title: 'the gullet'), hasLength(1));
      expect(await repo.structuredWikiQuery(category: 'Places'), hasLength(1));
      expect(await repo.structuredWikiQuery(freeText: 'smug'), hasLength(2));
      expect(await repo.structuredWikiQuery(title: 'nope'), isEmpty);
    });

    test('snapshots save and load; missing id throws', () async {
      await repo.saveWorldSnapshot('save-1', '{"hello":"world"}');
      expect(await repo.loadWorldSnapshot('save-1'), '{"hello":"world"}');
      await repo.saveWorldSnapshot('save-1', '{"hello":"again"}');
      expect(await repo.loadWorldSnapshot('save-1'), '{"hello":"again"}');
      await expectLater(repo.loadWorldSnapshot('nope'),
          throwsA(isA<WorldRepositoryException>()));
    });
  });
}
