/// Golden / integration tests (§11): canned structured outputs through the
/// REAL engine via the REAL turn controller with a FixtureLlmClient —
/// one fixture per scenario, asserting resulting events + projections.
library;

import 'package:living_worlds_engine/living_worlds_engine.dart';
import 'package:test/test.dart';

import 'helpers/fixtures.dart';

void main() {
  Future<(TurnController, InMemoryRepository, FixtureLlmClient)> harness(
      List<TurnOutput> outputs,
      {List<LlmToolCall> toolCalls = const []}) async {
    final repo = await seededRepo(InMemoryRepository());
    final llm =
        FixtureLlmClient(turnOutputs: outputs, scriptedToolCalls: toolCalls);
    final controller = TurnController(
      repo: repo,
      llm: llm,
      embedder: FixtureEmbeddingClient(),
      clock: fixedClock(),
    );
    return (controller, repo, llm);
  }

  test('scenario: peril turn — injury applied, gate opens, survivor plays on',
      () async {
    final (controller, repo, _) = await harness([
      const TurnOutput(
        narrative: 'The rope snaps; you catch a ledge, wrist screaming.',
        proposedDeltas: ProposedDeltas(
          clockAdvanceMinutes: 20,
          status: [StatusOp(op: StatusOpKind.add, key: 'injured', severity: 2)],
        ),
        peril: true,
      ),
    ]);
    final turn = await controller.playTurn(
        actorId: 'ash', userInput: 'climb down the shaft');
    final eval = turn.report.deathEval!;
    expect(eval.perilDeltaApplied, isTrue);
    expect(eval.probability, greaterThan(0));
    // Health 80 (100 - 2*10) with world seed 42: recorded outcome=survive.
    expect(turn.died, isFalse);
    final p = await repo.projection();
    expect(p.characters['ash']!.statusByKey('injured'), isNotNull);
    expect(p.characters['ash']!.subjectiveClock, 20);
  });

  test('scenario: item-gated branch — key grants unlock affordance', () async {
    final (controller, repo, llm) = await harness(
      [
        const TurnOutput(
          narrative: 'Wedged in the silt: a rusty key.',
          proposedDeltas: ProposedDeltas(
            clockAdvanceMinutes: 10,
            inventory: [
              InventoryOp(op: InventoryOpKind.grant, item: 'rusty key')
            ],
          ),
        ),
        const TurnOutput(
          narrative: 'The key turns; the vault door grinds open.',
          proposedDeltas: ProposedDeltas(
            clockAdvanceMinutes: 5,
            inventory: [
              InventoryOp(op: InventoryOpKind.use, item: 'rusty key')
            ],
            quest: [
              QuestOp(questId: 'q-map', op: QuestOpKind.progress, stepId: 's1')
            ],
          ),
        ),
      ],
      toolCalls: [
        const LlmToolCall(name: 'query_inventory', args: {'char_id': 'ash'})
      ],
    );

    await controller.playTurn(actorId: 'ash', userInput: 'search the silt');
    // The model's tool loop sees the affordance before the second turn.
    final inv = llm.observedExchanges.last.result as List<Object?>;
    // First turn's exchange ran before the grant; run turn 2 and check.
    final turn2 = await controller.playTurn(
        actorId: 'ash', userInput: 'unlock the vault');
    final inv2 = llm.observedExchanges.last.result! as List<Object?>;
    expect(
        inv2.any((i) =>
            (i! as Map<String, Object?>)['item'] == 'rusty key' &&
            ((i as Map<String, Object?>)['affordances']! as List<Object?>)
                .contains('unlock')),
        isTrue,
        reason: 'affordances are injected so the model knows what is possible');
    expect(inv, isA<List<Object?>>());
    expect(turn2.died, isFalse);
    final p = await repo.projection();
    expect(p.characters['ash']!.questById('q-map')!.steps.first.done, isTrue);
    // Key is not consumable — still held.
    expect(p.characters['ash']!.qtyOfDef('item-rusty-key'), 1);
  });

  test('scenario: quest completion — rewards granted through the engine',
      () async {
    final (controller, repo, _) = await harness([
      const TurnOutput(
        narrative: 'You chart the last chamber.',
        proposedDeltas: ProposedDeltas(
          clockAdvanceMinutes: 90,
          quest: [
            QuestOp(questId: 'q-map', op: QuestOpKind.progress, stepId: 's1'),
            QuestOp(questId: 'q-map', op: QuestOpKind.progress, stepId: 's2'),
          ],
        ),
      ),
    ]);
    final turn = await controller.playTurn(
        actorId: 'ash', userInput: 'finish the survey');
    expect(
        turn.notifications, contains('Quest complete: Map the Sunken Vault'));
    final p = await repo.projection();
    final a = p.characters['ash']!;
    expect(a.questById('q-map')!.state, QuestState.complete);
    expect(a.qtyOfDef('item-lantern'), 1);
    expect(a.stats['coin'], 35);
  });

  test(
      'scenario: meeting/cameo — playing with B present writes a '
      'SharedEvent both timelines must honor (§4.4)', () async {
    final (controller, repo, _) = await harness([
      const TurnOutput(
        narrative: 'You find Brynn at the tavern and split the vault haul.',
        proposedDeltas: ProposedDeltas(
          clockAdvanceMinutes: 60,
          relationships: [RelationshipOp(to: 'brynn', dim: 'trust', delta: 2)],
        ),
      ),
    ]);
    final turn = await controller.playTurn(
      actorId: 'ash',
      userInput: 'meet brynn at the tavern',
      presentCharacterIds: const ['brynn'],
    );
    expect(turn.died, isFalse);

    final p = await repo.projection();
    final ashCanon = p.sharedEventsFor('ash');
    final brynnCanon = p.sharedEventsFor('brynn');
    expect(ashCanon, hasLength(1));
    expect(brynnCanon, hasLength(1));
    expect(brynnCanon.single.summary, contains('split the vault haul'));
    expect(brynnCanon.single.atClock, 60,
        reason: 'stamped with the writer\'s post-turn subjective time');

    // When B is later played to that timestamp, the canon is injected as
    // fixed context (first-writer-wins).
    final rendezvous = RendezvousService(repo, clock: fixedClock());
    final canon = rendezvous.fixedCanonFor(
        projection: p, characterId: 'brynn', atClock: 60);
    expect(canon, hasLength(1));
  });

  test('scenario: death — lethal stack, timeline frozen, event trail intact',
      () async {
    final (controller, repo, _) = await harness([
      const TurnOutput(
        narrative: 'The serpent strikes twice. The world goes quiet.',
        proposedDeltas: ProposedDeltas(
          clockAdvanceMinutes: 3,
          status: [
            StatusOp(op: StatusOpKind.add, key: 'poisoned', severity: 15)
          ],
        ),
        peril: true,
      ),
    ]);
    final turn = await controller.playTurn(
        actorId: 'ash', userInput: 'grab the serpent');
    expect(turn.died, isTrue);

    final p = await repo.projection();
    expect(p.characters['ash']!.alive, isFalse);
    final events = await repo.eventsUpTo(-1);
    final died = events.where((e) => e.type == EventType.characterDied);
    expect(died, hasLength(1));
    // The death eval is fully reconstructible from the log (§9).
    final report = TurnDebugReport.fromJson((events.firstWhere((e) =>
            e.type == EventType.turnCommitted &&
            e.payload['narrative'] ==
                'The serpent strikes twice. The world goes quiet.'))
        .cause['debug_report'] as Map<String, Object?>);
    expect(report.deathEval!.instantTrigger, contains('poisoned'));

    await expectLater(
      controller.playTurn(actorId: 'ash', userInput: 'get up'),
      throwsStateError,
    );
  });

  test('scenario: turn is a transaction — engine failure commits nothing',
      () async {
    final repo = await seededRepo(InMemoryRepository());
    final before = await repo.lastSeq();
    final llm = _ExplodingLlm();
    final controller =
        TurnController(repo: repo, llm: llm, clock: fixedClock());
    await expectLater(
      controller.playTurn(actorId: 'ash', userInput: 'anything'),
      throwsA(isA<StateError>()),
    );
    expect(await repo.lastSeq(), before,
        reason: 'failed turn must not commit events');
  });

  test('cost log records fixture usage per turn (§10)', () async {
    final (controller, _, _) = await harness([calmTurn(), calmTurn()]);
    await controller.playTurn(actorId: 'ash', userInput: 'a');
    await controller.playTurn(actorId: 'ash', userInput: 'b');
    final agg = controller.costLog.aggregate(worldId: 'world-1');
    expect(agg.turns, 2);
    expect(controller.costLog.entries.first.usage.model, 'fixture');
  });
}

class _ExplodingLlm implements LlmClient {
  @override
  Future<LlmTurnResult> completeTurn({
    required String systemPrompt,
    required String context,
    required String userInput,
    required LlmToolHandler tools,
  }) async {
    throw StateError('LLM unavailable');
  }

  @override
  Future<String> complete(
      {required String systemPrompt,
      required String prompt,
      bool expectJson = false}) async {
    throw StateError('LLM unavailable');
  }
}
