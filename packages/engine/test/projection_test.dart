import 'dart:convert';

import 'package:living_worlds_engine/living_worlds_engine.dart';
import 'package:test/test.dart';

import 'helpers/fixtures.dart';

/// Deep-equality via canonical JSON.
String snap(WorldProjection p) => jsonEncode(p.toJson());

Future<InMemoryRepository> playScript(InMemoryRepository repo) async {
  const engine = TurnEngine();
  final outputs = [
    const TurnOutput(
      narrative: 'You wake and eat.',
      proposedDeltas: ProposedDeltas(
        clockAdvanceMinutes: 30,
        stats: [StatOp(key: 'hunger', op: StatOpKind.set, value: 10)],
      ),
    ),
    const TurnOutput(
      narrative: 'A cutpurse nicks you.',
      proposedDeltas: ProposedDeltas(
        clockAdvanceMinutes: 15,
        status: [StatusOp(op: StatusOpKind.add, key: 'bleeding', severity: 1)],
        stats: [StatOp(key: 'coin', op: StatOpKind.delta, value: -5)],
        relationships: [RelationshipOp(to: 'brynn', dim: 'trust', delta: 2)],
      ),
      peril: true,
    ),
    const TurnOutput(
      narrative: 'You loot a potion and find the vault.',
      proposedDeltas: ProposedDeltas(
        clockAdvanceMinutes: 60,
        inventory: [
          InventoryOp(op: InventoryOpKind.grant, item: 'healing potion'),
          InventoryOp(op: InventoryOpKind.grant, item: 'rusty key'),
        ],
        quest: [
          QuestOp(questId: 'q-map', op: QuestOpKind.progress, stepId: 's1')
        ],
      ),
    ),
  ];
  for (final output in outputs) {
    final p = await repo.projection();
    final r = engine.runTurn(
      projection: p,
      input: TurnInput(actorId: 'ash', userInput: 'go', output: output),
      now: t0,
    );
    await repo.appendEvents(r.events);
  }
  return repo;
}

void main() {
  group('replay == live projection', () {
    test('folding events one-by-one equals full replay', () async {
      final repo = await playScript(await seededRepo(InMemoryRepository()));
      final events = await repo.eventsUpTo(-1);

      final incremental = WorldProjection();
      for (final e in events) {
        incremental.applyEvent(e);
      }
      final replayed = WorldProjection.replay(events);
      expect(snap(incremental), snap(replayed));
    });

    test('replaying a shuffled-but-seq-sorted log is stable', () async {
      final repo = await playScript(await seededRepo(InMemoryRepository()));
      final events = await repo.eventsUpTo(-1);
      final shuffled = List.of(events)..shuffle();
      // replay() sorts by seq internally — causal order restored.
      expect(snap(WorldProjection.replay(shuffled)),
          snap(WorldProjection.replay(events)));
    });
  });

  group('delta idempotency (§0)', () {
    test('applying every event twice changes nothing', () async {
      final repo = await playScript(await seededRepo(InMemoryRepository()));
      final events = await repo.eventsUpTo(-1);

      final once = WorldProjection.replay(events);
      final twice = WorldProjection.replay(events);
      for (final e in events) {
        twice.applyEvent(e); // second application
      }
      expect(snap(twice), snap(once));
    });
  });

  group('undo / redo (§1.1)', () {
    test('undo rebuilds to seq N; redo restores; markers not deletions',
        () async {
      final repo = await playScript(await seededRepo(InMemoryRepository()));
      final fullSnap = snap(await repo.projection());
      final events = await repo.eventsUpTo(-1);

      // Find the seq just before the second turn's TurnCommitted.
      final turnSeqs = [
        for (final e in events)
          if (e.type == EventType.turnCommitted) e.seq
      ];
      final undoPoint = turnSeqs[1] - 1;

      final before = snap(await repo.projection(atSeq: undoPoint));
      await repo.revertAfter(undoPoint);
      expect(snap(await repo.projection()), before,
          reason: 'undo == rebuild up to seq N');

      // History still fully present (soft revert).
      expect((await repo.eventsUpTo(-1)).length, events.length);

      // Redo everything.
      await repo.unrevertUpTo(events.last.seq);
      expect(snap(await repo.projection()), fullSnap);
    });

    test('undo of a death un-freezes the timeline', () async {
      final repo = await seededRepo(InMemoryRepository());
      const engine = TurnEngine();
      var p = await repo.projection();
      final preDeath = await repo.lastSeq();
      final killer = engine.runTurn(
        projection: p,
        input: const TurnInput(
          actorId: 'ash',
          userInput: 'lick the frog',
          output: TurnOutput(
            narrative: 'Lethal.',
            proposedDeltas: ProposedDeltas(status: [
              StatusOp(op: StatusOpKind.add, key: 'poisoned', severity: 12)
            ]),
          ),
        ),
        now: t0,
      );
      await repo.appendEvents(killer.events);
      p = await repo.projection();
      expect(p.characters['ash']!.alive, isFalse);

      await repo.revertAfter(preDeath);
      p = await repo.projection();
      expect(p.characters['ash']!.alive, isTrue);
      expect(p.characters['ash']!.status, isEmpty);
    });
  });

  group('world clock projection (§1.2)', () {
    test('display clock is max over living characters', () async {
      final repo = await playScript(await seededRepo(InMemoryRepository()));
      final p = await repo.projection();
      // Ash advanced 105 min; Brynn 0.
      expect(p.characters['ash']!.subjectiveClock, 105);
      expect(p.worldClock, 105);
    });

    test('dead characters do not hold the clock forward', () {
      final p = WorldProjection();
      final world = testWorld();
      p.applyEvent(Event(
        id: 'evt-0',
        worldId: world.id,
        seq: 0,
        timeline: worldTimeline,
        subjectiveClock: 0,
        type: EventType.worldCreated,
        payload: {'world': world.toJson()},
        createdAt: t0,
      ));
      p.applyEvent(Event(
        id: 'evt-1',
        worldId: world.id,
        seq: 1,
        timeline: 'ash',
        subjectiveClock: 500,
        type: EventType.characterCreated,
        payload: {
          'character': ash().copyWith(subjectiveClock: 500).toJson()
        },
        createdAt: t0,
      ));
      p.applyEvent(Event(
        id: 'evt-2',
        worldId: world.id,
        seq: 2,
        timeline: 'brynn',
        subjectiveClock: 100,
        type: EventType.characterCreated,
        payload: {
          'character': brynn().copyWith(subjectiveClock: 100).toJson()
        },
        createdAt: t0,
      ));
      expect(p.worldClock, 500);
      p.applyEvent(Event(
        id: 'evt-3',
        worldId: world.id,
        seq: 3,
        timeline: 'ash',
        subjectiveClock: 500,
        type: EventType.characterDied,
        payload: {'char_id': 'ash', 'at_clock': 500},
        createdAt: t0,
      ));
      expect(p.worldClock, 100);
    });
  });

  group('event log discipline', () {
    test('appendEvent rejects seq gaps and duplicates', () async {
      final repo = await seededRepo(InMemoryRepository());
      final last = await repo.lastSeq();
      final bad = Event(
        id: 'evt-x',
        worldId: 'world-1',
        seq: last + 5,
        timeline: worldTimeline,
        subjectiveClock: 0,
        type: EventType.summaryCached,
        payload: const {'timeline': 'ash', 'upto_seq': 0, 'summary': ''},
        createdAt: t0,
      );
      expect(() => repo.appendEvent(bad),
          throwsA(isA<WorldRepositoryException>()));
    });

    test('appendEvents is atomic: bad batch commits nothing', () async {
      final repo = await seededRepo(InMemoryRepository());
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
      expect(
        () => repo.appendEvents([mk(last + 1), mk(last + 3)]),
        throwsA(isA<WorldRepositoryException>()),
      );
      expect(await repo.lastSeq(), last);
    });
  });
}
