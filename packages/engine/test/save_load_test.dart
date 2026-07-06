import 'dart:convert';

import 'package:living_worlds_engine/living_worlds_engine.dart';
import 'package:test/test.dart';

import 'helpers/fixtures.dart';

void main() {
  const codec = SaveCodec();
  const engine = TurnEngine();

  Future<InMemoryRepository> playedRepo() async {
    final repo = await seededRepo(InMemoryRepository());
    final outputs = [
      const TurnOutput(
        narrative: 'Wounded but richer.',
        proposedDeltas: ProposedDeltas(
          clockAdvanceMinutes: 45,
          status: [
            StatusOp(op: StatusOpKind.add, key: 'bleeding', severity: 1)
          ],
          inventory: [
            InventoryOp(op: InventoryOpKind.grant, item: 'rusty key')
          ],
          relationships: [
            RelationshipOp(to: 'brynn', dim: 'respect', delta: 1)
          ],
        ),
        peril: true,
      ),
      calmTurn(minutes: 30),
    ];
    for (final o in outputs) {
      final p = await repo.projection();
      final r = engine.runTurn(
          projection: p,
          input: TurnInput(actorId: 'ash', userInput: 'go', output: o),
          now: t0);
      await repo.appendEvents(r.events);
    }
    return repo;
  }

  test('save format is text/JSON with log + schema + markers + cache (§8)',
      () async {
    final repo = await playedRepo();
    final blob = await codec.exportWorld(repo);
    final json = jsonDecode(blob) as Map<String, Object?>;
    expect(json['format_version'], 1);
    expect(json['events'], isNotEmpty);
    expect(json['schema'], isNotNull);
    expect((json['world'] as Map<String, Object?>)['name'], 'Testhaven');
    expect(json['projection_cache'], isNotNull);
  });

  test('export -> import round-trip: projections identical', () async {
    final repo = await playedRepo();
    final blob = await codec.exportWorld(repo);
    final original = await repo.projection();

    final restoredRepo = InMemoryRepository();
    final restored = await codec.importWorld(restoredRepo, blob);
    expect(jsonEncode(restored.toJson()), jsonEncode(original.toJson()));

    // The restored world continues playing deterministically.
    final r = engine.runTurn(
      projection: restored,
      input:
          TurnInput(actorId: 'ash', userInput: 'go', output: calmTurn()),
      now: t0,
    );
    expect(r.events.first.seq, await restoredRepo.lastSeq() + 1);
  });

  test('round-trip preserves undo state (revert markers)', () async {
    final repo = await playedRepo();
    final events = await repo.eventsUpTo(-1);
    final lastTurnSeq = events
        .lastWhere((e) => e.type == EventType.turnCommitted)
        .seq;
    await repo.revertAfter(lastTurnSeq - 1); // undo last turn
    final undoneSnap = jsonEncode((await repo.projection()).toJson());

    final blob = await codec.exportWorld(repo);
    final restoredRepo = InMemoryRepository();
    final restored = await codec.importWorld(restoredRepo, blob);
    expect(jsonEncode(restored.toJson()), undoneSnap);

    // Redo still works after the round-trip.
    await restoredRepo.unrevertUpTo(1 << 60);
    final redone = await restoredRepo.projection();
    expect(redone.characters['ash']!.subjectiveClock, 75);
  });

  test('tampered cache is detected on import ("trust cache + verify")',
      () async {
    final repo = await playedRepo();
    final blob = await codec.exportWorld(repo);
    final json = jsonDecode(blob) as Map<String, Object?>;
    final cache = json['projection_cache'] as Map<String, Object?>;
    ((cache['characters'] as Map<String, Object?>)['ash']
        as Map<String, Object?>)['subjective_clock'] = 99999;
    final tampered = jsonEncode(json);

    await expectLater(
      codec.importWorld(InMemoryRepository(), tampered),
      throwsA(isA<WorldRepositoryException>()),
    );
  });

  test('newer format versions are refused, non-empty targets are refused',
      () async {
    final repo = await playedRepo();
    final blob = await codec.exportWorld(repo);
    final json = jsonDecode(blob) as Map<String, Object?>;
    json['format_version'] = 99;
    expect(() => codec.decode(jsonEncode(json)),
        throwsA(isA<WorldRepositoryException>()));

    await expectLater(
      codec.importWorld(repo, blob), // repo already has events
      throwsA(isA<WorldRepositoryException>()),
    );
  });

  test('snapshot storage integrates with repository save slots', () async {
    final repo = await playedRepo();
    final blob = await codec.exportWorld(repo);
    await repo.saveWorldSnapshot('slot-1', blob);
    final loaded = await repo.loadWorldSnapshot('slot-1');
    final restored =
        await codec.importWorld(InMemoryRepository(), loaded);
    expect(restored.characters['ash']!.subjectiveClock, 75);
  });
}
