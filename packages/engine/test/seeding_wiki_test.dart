import 'dart:convert';

import 'package:living_worlds_engine/living_worlds_engine.dart';
import 'package:test/test.dart';

import 'helpers/fixtures.dart';

void main() {
  late InMemoryRepository repo;
  late WorldService service;

  setUp(() async {
    repo = await seededRepo(InMemoryRepository());
    service = WorldService(repo, clock: fixedClock());
  });

  group('wiki CRUD as events (§5.1)', () {
    test('create -> update bumps version; change log preserved', () async {
      await service.createWikiEntry(WikiEntry(
          id: 'wiki-gullet',
          worldId: 'world-1',
          title: 'The Gullet',
          category: 'Places',
          body: 'v1 body'));
      await service.updateWikiEntry(WikiEntry(
          id: 'wiki-gullet',
          worldId: 'world-1',
          title: 'The Gullet',
          category: 'Places',
          body: 'v2 body — now with tide schedule'));

      final p = await repo.projection();
      expect(p.wiki['wiki-gullet']!.version, 2);
      expect(p.wiki['wiki-gullet']!.body, contains('tide schedule'));

      final events = await repo.eventsUpTo(-1);
      expect(events.where((e) => e.type == EventType.wikiCreated),
          hasLength(1));
      expect(events.where((e) => e.type == EventType.wikiUpdated),
          hasLength(1));

      // Undo the update -> v1 body restored.
      final updateSeq =
          events.firstWhere((e) => e.type == EventType.wikiUpdated).seq;
      await service.undoTo(updateSeq - 1);
      final undone = await repo.projection();
      expect(undone.wiki['wiki-gullet']!.body, 'v1 body');
      expect(undone.wiki['wiki-gullet']!.version, 1);
      await service.redoTo(updateSeq);
      expect((await repo.projection()).wiki['wiki-gullet']!.version, 2);
    });

    test('invalid category is refused (schema-driven)', () async {
      await expectLater(
        service.createWikiEntry(WikiEntry(
            id: 'wiki-x',
            worldId: 'world-1',
            title: 'X',
            category: 'Recipes',
            body: '')),
        throwsA(isA<WorldRepositoryException>()),
      );
    });

    test('duplicate create and phantom update are refused', () async {
      await service.createWikiEntry(WikiEntry(
          id: 'wiki-a',
          worldId: 'world-1',
          title: 'A',
          category: 'Lore',
          body: ''));
      await expectLater(
        service.createWikiEntry(WikiEntry(
            id: 'wiki-a',
            worldId: 'world-1',
            title: 'A again',
            category: 'Lore',
            body: '')),
        throwsA(isA<WorldRepositoryException>()),
      );
      await expectLater(
        service.updateWikiEntry(WikiEntry(
            id: 'wiki-ghost',
            worldId: 'world-1',
            title: 'Ghost',
            category: 'Lore',
            body: '')),
        throwsA(isA<WorldRepositoryException>()),
      );
    });
  });

  group('candidate review queue (§5.2)', () {
    Future<String> queueCandidate() async {
      const engine = TurnEngine();
      final p = await repo.projection();
      final r = engine.runTurn(
        projection: p,
        input: const TurnInput(
          actorId: 'ash',
          userInput: 'explore',
          output: TurnOutput(
            narrative: 'You find the Gullet.',
            wikiCandidates: [
              WikiCandidate(
                  id: '',
                  title: 'The Gullet',
                  category: 'Places',
                  body: 'A drowned smuggling tunnel.')
            ],
          ),
        ),
        now: t0,
      );
      await repo.appendEvents(r.events);
      final queued = await repo.projection();
      return queued.pendingCandidates.keys.single;
    }

    test('promotion converts a candidate into a wiki entry (as an event)',
        () async {
      final candId = await queueCandidate();
      final p = await repo.projection();
      final cand = p.pendingCandidates[candId]!;

      await service.promoteCandidate(
          candId,
          WikiEntry(
              id: 'wiki-gullet',
              worldId: 'world-1',
              title: cand.title,
              category: cand.category,
              body: '${cand.body} (edited by the player)'));

      final after = await repo.projection();
      expect(after.pendingCandidates, isEmpty);
      expect(after.wiki['wiki-gullet']!.body, contains('edited by the player'));
    });

    test('rejection clears the candidate without touching the wiki',
        () async {
      final candId = await queueCandidate();
      await service.rejectCandidate('world-1', candId);
      final after = await repo.projection();
      expect(after.pendingCandidates, isEmpty);
      expect(after.wiki, isEmpty);
    });

    test('promoting a nonexistent candidate throws', () async {
      await expectLater(
        service.promoteCandidate(
            'cand-nope',
            WikiEntry(
                id: 'wiki-x',
                worldId: 'world-1',
                title: 'X',
                category: 'Lore',
                body: '')),
        throwsA(isA<WorldRepositoryException>()),
      );
    });
  });

  group('seeding session (§5.1)', () {
    test('clarify -> propose -> accept writes through to the change log',
        () async {
      final llm = FixtureLlmClient(completions: [
        jsonEncode({
          'action': 'clarify',
          'message': 'Is the Gullet natural or dug by smugglers?'
        }),
        jsonEncode({
          'action': 'propose_create',
          'entry': {
            'title': 'The Gullet',
            'category': 'Places',
            'body': 'A hand-dug smuggling tunnel, flooded at high tide.',
            'tags': ['harbor'],
            'clock_ref': null,
          }
        }),
      ]);
      final session = SeedingSession(
          repo: repo, llm: llm, worldId: 'world-1', clock: fixedClock());

      final q = await session.send('Add a smuggling tunnel location');
      expect(q.kind, SeedingActionKind.clarify);
      expect(q.message, contains('natural or dug'));

      final proposal = await session.send('Dug by smugglers, floods daily');
      expect(proposal.kind, SeedingActionKind.proposeCreate);
      expect(proposal.entry!.title, 'The Gullet');

      final event = await session.accept(proposal);
      expect(event.type, EventType.wikiCreated);

      final p = await repo.projection();
      expect(p.wiki.values.single.body, contains('high tide'));
      // No gameplay side effects: no clock advance, no character changes.
      expect(p.characters['ash']!.subjectiveClock, 0);
      expect(p.worldClock, 0);
    });

    test('accepting a proposed update bumps the existing entry', () async {
      await service.createWikiEntry(WikiEntry(
          id: 'wiki-gullet',
          worldId: 'world-1',
          title: 'The Gullet',
          category: 'Places',
          body: 'v1'));
      final llm = FixtureLlmClient(completions: [
        jsonEncode({
          'action': 'propose_update',
          'entry': {
            'id': 'wiki-gullet',
            'title': 'The Gullet',
            'category': 'Places',
            'body': 'v2 with a guard rotation',
            'tags': <String>[],
          }
        }),
      ]);
      final session = SeedingSession(
          repo: repo, llm: llm, worldId: 'world-1', clock: fixedClock());
      final proposal = await session.send('Add the guard rotation');
      expect(proposal.kind, SeedingActionKind.proposeUpdate);
      await session.accept(proposal);
      final p = await repo.projection();
      expect(p.wiki['wiki-gullet']!.version, 2);
    });

    test('accepting a non-proposal throws', () async {
      final llm = FixtureLlmClient(completions: [
        jsonEncode(<String, Object?>{'action': 'chat', 'message': 'hi'})
      ]);
      final session = SeedingSession(
          repo: repo, llm: llm, worldId: 'world-1', clock: fixedClock());
      final chat = await session.send('hello');
      expect(chat.kind, SeedingActionKind.chat);
      expect(() => session.accept(chat), throwsArgumentError);
    });
  });
}
