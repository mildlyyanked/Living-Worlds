import 'package:living_worlds_engine/living_worlds_engine.dart';
import 'package:test/test.dart';

import 'helpers/fixtures.dart';

void main() {
  const engine = TurnEngine();

  Future<WorldProjection> freshProjection() async =>
      (await seededRepo(InMemoryRepository())).projection();

  TurnResult run(WorldProjection p, TurnOutput output,
          {String actor = 'ash', bool nonLethal = false}) =>
      engine.runTurn(
        projection: p,
        input: TurnInput(
            actorId: actor,
            userInput: 'do it',
            output: output,
            nonLethal: nonLethal),
        now: t0,
      );

  DeltaDecision decisionFor(TurnResult r, String section, {int index = 0}) =>
      r.report.decisions.where((d) => d.section == section).elementAt(index);

  group('inventory legality (§4.1)', () {
    test('granting a defined item is accepted and emits ItemGranted', () async {
      final p = await freshProjection();
      final r = run(
          p,
          const TurnOutput(
            narrative: 'You pry the key from the lock.',
            proposedDeltas: ProposedDeltas(inventory: [
              InventoryOp(op: InventoryOpKind.grant, item: 'rusty key')
            ]),
          ));
      expect(decisionFor(r, 'inventory').outcome, DeltaOutcome.accepted);
      expect(r.events.any((e) => e.type == EventType.itemGranted), isTrue);
      expect(r.notifications, contains('Acquired: rusty key'));
    });

    test('granting a nonexistent def is rejected', () async {
      final p = await freshProjection();
      final r = run(
          p,
          const TurnOutput(
            narrative: 'A sword appears!',
            proposedDeltas: ProposedDeltas(inventory: [
              InventoryOp(op: InventoryOpKind.grant, item: 'vorpal sword')
            ]),
          ));
      final d = decisionFor(r, 'inventory');
      expect(d.outcome, DeltaOutcome.rejected);
      expect(d.reason, contains('no such item'));
      expect(r.events.any((e) => e.type == EventType.itemGranted), isFalse);
    });

    test('using an unheld item is rejected', () async {
      final p = await freshProjection();
      final r = run(
          p,
          const TurnOutput(
            narrative: 'You drink a potion you do not have.',
            proposedDeltas: ProposedDeltas(inventory: [
              InventoryOp(op: InventoryOpKind.use, item: 'healing potion')
            ]),
          ));
      expect(decisionFor(r, 'inventory').outcome, DeltaOutcome.rejected);
      expect(decisionFor(r, 'inventory').reason, contains('not held'));
    });

    test('removing more than held is rejected', () async {
      final p = await freshProjection();
      final r = run(
          p,
          const TurnOutput(
            narrative: 'You give away keys.',
            proposedDeltas: ProposedDeltas(inventory: [
              InventoryOp(
                  op: InventoryOpKind.remove, item: 'rusty key', qty: 2)
            ]),
          ));
      expect(decisionFor(r, 'inventory').outcome, DeltaOutcome.rejected);
    });

    test('use applies effects and consumes consumables', () async {
      // Grant a potion + bleeding first, then use it.
      final repo = await seededRepo(InMemoryRepository());
      var p = await repo.projection();
      final setup = run(
          p,
          const TurnOutput(
            narrative: 'Wounded, you loot a potion.',
            proposedDeltas: ProposedDeltas(
              inventory: [
                InventoryOp(op: InventoryOpKind.grant, item: 'healing potion')
              ],
              status: [
                StatusOp(op: StatusOpKind.add, key: 'bleeding', severity: 2)
              ],
              stats: [
                StatOp(key: 'fatigue', op: StatOpKind.set, value: 50)
              ],
            ),
            peril: true,
          ));
      await repo.appendEvents(setup.events);
      p = await repo.projection();
      expect(p.characters['ash']!.qtyOfDef('item-potion'), 1);
      expect(p.characters['ash']!.statusByKey('bleeding'), isNotNull);

      final r = run(
          p,
          const TurnOutput(
            narrative: 'You drink deep.',
            proposedDeltas: ProposedDeltas(inventory: [
              InventoryOp(op: InventoryOpKind.use, item: 'healing potion')
            ]),
          ));
      expect(decisionFor(r, 'inventory').outcome, DeltaOutcome.accepted);
      // Effects: bleeding removed, fatigue -20, potion consumed.
      expect(
          r.events.any((e) =>
              e.type == EventType.statusChanged &&
              e.payload['op'] == 'remove' &&
              e.payload['key'] == 'bleeding'),
          isTrue);
      expect(
          r.events.any((e) =>
              e.type == EventType.statChanged &&
              e.payload['key'] == 'fatigue' &&
              (e.payload['to'] as num) == 30),
          isTrue);
      expect(
          r.events.any((e) =>
              e.type == EventType.itemRemoved &&
              (e.payload['resulting_qty'] as num) == 0),
          isTrue);
    });
  });

  group('stat validation', () {
    test('unknown stat key is rejected', () async {
      final p = await freshProjection();
      final r = run(
          p,
          const TurnOutput(
            narrative: 'x',
            proposedDeltas: ProposedDeltas(
                stats: [StatOp(key: 'charisma', op: StatOpKind.delta, value: 5)]),
          ));
      expect(decisionFor(r, 'stats').outcome, DeltaOutcome.rejected);
    });

    test('delta beyond range is clamped and recorded from->to', () async {
      final p = await freshProjection();
      final r = run(
          p,
          const TurnOutput(
            narrative: 'x',
            proposedDeltas: ProposedDeltas(stats: [
              StatOp(key: 'hunger', op: StatOpKind.delta, value: 250)
            ]),
          ));
      final d = decisionFor(r, 'stats');
      expect(d.outcome, DeltaOutcome.clamped);
      expect(d.from, 250);
      expect(d.to, 100);
    });

    test('set op sets absolute value', () async {
      final p = await freshProjection();
      final r = run(
          p,
          const TurnOutput(
            narrative: 'x',
            proposedDeltas: ProposedDeltas(
                stats: [StatOp(key: 'coin', op: StatOpKind.set, value: 3)]),
          ));
      final e = r.events.firstWhere((e) => e.type == EventType.statChanged);
      expect(e.payload['from'], 10);
      expect(e.payload['to'], 3);
    });
  });

  group('status validation', () {
    test('unknown status is rejected; removing absent status is rejected',
        () async {
      final p = await freshProjection();
      final r = run(
          p,
          const TurnOutput(
            narrative: 'x',
            proposedDeltas: ProposedDeltas(status: [
              StatusOp(op: StatusOpKind.add, key: 'petrified'),
              StatusOp(op: StatusOpKind.remove, key: 'bleeding'),
            ]),
          ));
      expect(decisionFor(r, 'status', index: 0).outcome,
          DeltaOutcome.rejected);
      expect(decisionFor(r, 'status', index: 1).outcome,
          DeltaOutcome.rejected);
    });

    test('harmful status add marks peril_delta_applied', () async {
      final p = await freshProjection();
      final r = run(
          p,
          const TurnOutput(
            narrative: 'The blade bites.',
            proposedDeltas: ProposedDeltas(status: [
              StatusOp(op: StatusOpKind.add, key: 'bleeding', severity: 1)
            ]),
          ));
      expect(r.report.deathEval!.perilDeltaApplied, isTrue);
    });

    test('buff status add does NOT mark peril', () async {
      final p = await freshProjection();
      final r = run(
          p,
          const TurnOutput(
            narrative: 'You rest.',
            proposedDeltas: ProposedDeltas(status: [
              StatusOp(op: StatusOpKind.add, key: 'rested', severity: 2)
            ]),
          ));
      expect(r.report.deathEval!.perilDeltaApplied, isFalse);
      expect(r.report.deathEval!.probability, 0);
    });
  });

  group('clock (§4.4)', () {
    test('advance within cap is accepted', () async {
      final p = await freshProjection();
      final r = run(p, calmTurn(minutes: 45));
      expect(r.clockTo, 45);
      expect(r.notifications, contains('+45 min'));
    });

    test('advance beyond PER_TURN_CAP is clamped', () async {
      final p = await freshProjection();
      final r = run(p, calmTurn(minutes: 999));
      expect(r.clockTo, 240);
      expect(decisionFor(r, 'clock').outcome, DeltaOutcome.clamped);
    });

    test('negative advance is clamped to 0', () async {
      final p = await freshProjection();
      final r = run(p, calmTurn(minutes: -10));
      expect(r.clockTo, 0);
    });

    test('statuses fully decayed by the advance are expired', () async {
      final repo = await seededRepo(InMemoryRepository());
      var p = await repo.projection();
      final wound = run(
          p,
          const TurnOutput(
            narrative: 'Nicked.',
            proposedDeltas: ProposedDeltas(status: [
              StatusOp(op: StatusOpKind.add, key: 'bleeding', severity: 0.5)
            ]),
          ));
      await repo.appendEvents(wound.events);
      p = await repo.projection();
      // 0.5 severity decays at 0.02/min => gone in 25 min.
      final later = run(p, calmTurn(minutes: 60));
      expect(
          later.events.any((e) =>
              e.type == EventType.statusChanged &&
              e.payload['op'] == 'remove' &&
              e.payload['key'] == 'bleeding'),
          isTrue);
    });
  });

  group('quests', () {
    test('progress marks step done; final step auto-completes with rewards',
        () async {
      final repo = await seededRepo(InMemoryRepository());
      var p = await repo.projection();
      final r1 = run(
          p,
          const TurnOutput(
            narrative: 'You find the entrance.',
            proposedDeltas: ProposedDeltas(quest: [
              QuestOp(questId: 'q-map', op: QuestOpKind.progress, stepId: 's1')
            ]),
          ));
      expect(decisionFor(r1, 'quest').outcome, DeltaOutcome.accepted);
      await repo.appendEvents(r1.events);
      p = await repo.projection();
      expect(
          p.characters['ash']!.questById('q-map')!.steps.first.done, isTrue);

      final r2 = run(
          p,
          const TurnOutput(
            narrative: 'You sketch the chambers.',
            proposedDeltas: ProposedDeltas(quest: [
              QuestOp(questId: 'q-map', op: QuestOpKind.progress, stepId: 's2')
            ]),
          ));
      await repo.appendEvents(r2.events);
      p = await repo.projection();
      final quest = p.characters['ash']!.questById('q-map')!;
      expect(quest.state, QuestState.complete);
      // Rewards: lantern + 25 coin.
      expect(p.characters['ash']!.qtyOfDef('item-lantern'), 1);
      expect(p.characters['ash']!.stats['coin'], 35);
      expect(r2.notifications,
          contains('Quest complete: Map the Sunken Vault'));
    });

    test('complete with steps undone is rejected', () async {
      final p = await freshProjection();
      final r = run(
          p,
          const TurnOutput(
            narrative: 'Done, surely?',
            proposedDeltas: ProposedDeltas(quest: [
              QuestOp(questId: 'q-map', op: QuestOpKind.complete)
            ]),
          ));
      expect(decisionFor(r, 'quest').outcome, DeltaOutcome.rejected);
      expect(decisionFor(r, 'quest').reason, contains('steps remain'));
    });

    test('unknown quest / step rejected; done step re-progress rejected',
        () async {
      final repo = await seededRepo(InMemoryRepository());
      var p = await repo.projection();
      final r0 = run(
          p,
          const TurnOutput(
            narrative: 'x',
            proposedDeltas: ProposedDeltas(quest: [
              QuestOp(questId: 'q-map', op: QuestOpKind.progress, stepId: 's1')
            ]),
          ));
      await repo.appendEvents(r0.events);
      p = await repo.projection();

      final r = run(
          p,
          const TurnOutput(
            narrative: 'x',
            proposedDeltas: ProposedDeltas(quest: [
              QuestOp(questId: 'q-nope', op: QuestOpKind.progress, stepId: 's1'),
              QuestOp(questId: 'q-map', op: QuestOpKind.progress, stepId: 's9'),
              QuestOp(questId: 'q-map', op: QuestOpKind.progress, stepId: 's1'),
            ]),
          ));
      expect(decisionFor(r, 'quest', index: 0).outcome, DeltaOutcome.rejected);
      expect(decisionFor(r, 'quest', index: 1).outcome, DeltaOutcome.rejected);
      expect(decisionFor(r, 'quest', index: 2).outcome, DeltaOutcome.rejected);
      expect(decisionFor(r, 'quest', index: 2).reason, contains('already'));
    });
  });

  group('relationships (§4.5)', () {
    test('delta applies to directed edge and clamps to schema range',
        () async {
      final p = await freshProjection();
      final r = run(
          p,
          const TurnOutput(
            narrative: 'You save Brynn\'s cargo.',
            proposedDeltas: ProposedDeltas(relationships: [
              RelationshipOp(to: 'brynn', dim: 'trust', delta: 99)
            ]),
          ));
      final d = decisionFor(r, 'relationships');
      expect(d.outcome, DeltaOutcome.clamped);
      expect(d.to, 10); // schema max
      final e = r.events
          .firstWhere((e) => e.type == EventType.relationshipChanged);
      expect(e.payload['from_char'], 'ash');
      expect(e.payload['to_char'], 'brynn');
      expect(e.payload['to'], 10);
    });

    test('unknown dim and unknown target are rejected', () async {
      final p = await freshProjection();
      final r = run(
          p,
          const TurnOutput(
            narrative: 'x',
            proposedDeltas: ProposedDeltas(relationships: [
              RelationshipOp(to: 'brynn', dim: 'envy', delta: 1),
              RelationshipOp(to: 'ghost', dim: 'trust', delta: 1),
            ]),
          ));
      expect(decisionFor(r, 'relationships', index: 0).outcome,
          DeltaOutcome.rejected);
      expect(decisionFor(r, 'relationships', index: 1).outcome,
          DeltaOutcome.rejected);
    });
  });

  group('death integration', () {
    test('massive injury forces a roll; deterministic across replays',
        () async {
      final p1 = await freshProjection();
      final wound = const TurnOutput(
        narrative: 'The floor gives way.',
        proposedDeltas: ProposedDeltas(status: [
          StatusOp(op: StatusOpKind.add, key: 'injured', severity: 9)
        ]),
        peril: true,
      );
      final a = run(p1, wound);
      final p2 = await freshProjection();
      final b = run(p2, wound);
      expect(a.report.deathEval!.draw, b.report.deathEval!.draw);
      expect(a.died, b.died);
      expect(a.report.deathEval!.probability, greaterThan(0));
    });

    test('lethal poison stack is an instant engine trigger', () async {
      final p = await freshProjection();
      final r = run(
          p,
          const TurnOutput(
            narrative: 'The venom overwhelms you.',
            proposedDeltas: ProposedDeltas(status: [
              StatusOp(op: StatusOpKind.add, key: 'poisoned', severity: 12)
            ]),
          ));
      expect(r.died, isTrue);
      expect(r.report.deathEval!.instantTrigger, contains('poisoned'));
      expect(r.events.last.type, EventType.characterDied);
    });

    test('non-lethal mode suppresses instant trigger, keeps status',
        () async {
      final p = await freshProjection();
      final r = run(
          p,
          const TurnOutput(
            narrative: 'Bad weeks.',
            proposedDeltas: ProposedDeltas(status: [
              StatusOp(op: StatusOpKind.add, key: 'poisoned', severity: 12)
            ]),
          ),
          nonLethal: true);
      expect(r.died, isFalse);
      expect(r.report.deathEval!.skippedNonLethal, isTrue);
      expect(
          r.events.any((e) =>
              e.type == EventType.statusChanged &&
              e.payload['key'] == 'poisoned'),
          isTrue);
      expect(r.report.notes.single, contains('suppressed'));
    });

    test('dead characters cannot take turns (timeline frozen)', () async {
      final repo = await seededRepo(InMemoryRepository());
      var p = await repo.projection();
      final killer = run(
          p,
          const TurnOutput(
            narrative: 'The venom overwhelms you.',
            proposedDeltas: ProposedDeltas(status: [
              StatusOp(op: StatusOpKind.add, key: 'poisoned', severity: 12)
            ]),
          ));
      expect(killer.died, isTrue);
      await repo.appendEvents(killer.events);
      p = await repo.projection();
      expect(p.characters['ash']!.alive, isFalse);
      expect(() => run(p, calmTurn()), throwsStateError);
    });
  });

  group('turn mechanics', () {
    test('TurnCommitted leads, carries debug report, clock from/to',
        () async {
      final p = await freshProjection();
      final r = run(p, calmTurn(minutes: 45));
      final first = r.events.first;
      expect(first.type, EventType.turnCommitted);
      expect(first.payload['clock_from'], 0);
      expect(first.payload['clock_to'], 45);
      expect(first.cause['debug_report'], isNotNull);
      expect(first.cause['turn_id'], 'turn-${first.seq}');
    });

    test('wiki candidates are queued as events', () async {
      final p = await freshProjection();
      final r = run(
          p,
          const TurnOutput(
            narrative: 'You discover the Gullet.',
            wikiCandidates: [
              WikiCandidate(
                  id: '',
                  title: 'The Gullet',
                  category: 'Places',
                  body: 'A drowned smuggling tunnel.')
            ],
          ));
      final e = r.events
          .firstWhere((e) => e.type == EventType.wikiCandidateQueued);
      final cand =
          WikiCandidate.fromJson(e.payload['candidate'] as Map<String, Object?>);
      expect(cand.title, 'The Gullet');
      expect(cand.sourceTurnSeq, r.events.first.seq);
      expect(cand.id, isNotEmpty);
    });

    test('unknown actor throws', () async {
      final p = await freshProjection();
      expect(
        () => engine.runTurn(
          projection: p,
          input: TurnInput(
              actorId: 'nobody', userInput: 'x', output: calmTurn()),
          now: t0,
        ),
        throwsArgumentError,
      );
    });
  });
}
