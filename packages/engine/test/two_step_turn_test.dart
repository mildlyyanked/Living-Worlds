/// Two-step turns (§ two-step turns): phase 1 resolves consequences (deltas
/// only), the engine disposes, then phase 2 narrates strictly from the
/// resolved changes. Plus per-turn debug capture and whole-turn undo.
library;

import 'package:living_worlds_engine/living_worlds_engine.dart';
import 'package:test/test.dart';

import 'helpers/fixtures.dart';

/// Records the `changes` digest handed to phase 2 so we can prove the
/// narration is grounded in what the engine actually committed.
class _RecordingLlm implements LlmClient {
  _RecordingLlm(this.output);

  final TurnOutput output;
  String? seenChanges;
  String? seenAction;

  @override
  Future<LlmTurnResult> completeTurn({
    required String systemPrompt,
    required String context,
    required String userInput,
    required LlmToolHandler tools,
  }) async =>
      LlmTurnResult(output: output, usage: const LlmUsage(model: 'rec'));

  @override
  Future<String> complete({
    required String systemPrompt,
    required String prompt,
    bool expectJson = false,
  }) async =>
      throw StateError('unused');

  @override
  Future<LlmNarration> narrate({
    required String systemPrompt,
    required String context,
    required String action,
    required String changes,
  }) async {
    seenChanges = changes;
    seenAction = action;
    return const LlmNarration(text: 'A short, grounded line.');
  }
}

void main() {
  test('phase-1 deltas are applied; phase-2 text is what gets committed',
      () async {
    final repo = await seededRepo(InMemoryRepository());
    final llm = FixtureLlmClient(
      turnOutputs: [
        const TurnOutput(
          // Any prose the resolver leaks here must be ignored.
          narrative: 'LEAKED PROSE THAT MUST NOT BE COMMITTED',
          proposedDeltas: ProposedDeltas(
            clockAdvanceMinutes: 25,
            stats: [StatOp(key: 'coin', op: StatOpKind.delta, value: 5)],
          ),
        ),
      ],
      narrations: ['You haggle; five coin heavier.'],
    );
    final controller = TurnController(
        repo: repo, llm: llm, embedder: FixtureEmbeddingClient());
    final turn = await controller.playTurn(actorId: 'ash', userInput: 'haggle');

    // The committed narrative is phase 2, not the leaked phase-1 prose.
    expect(turn.narrative, 'You haggle; five coin heavier.');
    expect(turn.narrative, isNot(contains('LEAKED')));

    final p = await repo.projection();
    expect(p.characters['ash']!.subjectiveClock, 25);
    expect(p.characters['ash']!.stats['coin'], 15);
  });

  test('phase 2 is grounded in the engine-resolved changes', () async {
    final repo = await seededRepo(InMemoryRepository());
    final llm = _RecordingLlm(const TurnOutput(
      narrative: '',
      proposedDeltas: ProposedDeltas(
        clockAdvanceMinutes: 25,
        stats: [StatOp(key: 'coin', op: StatOpKind.delta, value: 5)],
      ),
    ));
    final controller = TurnController(repo: repo, llm: llm);
    await controller.playTurn(actorId: 'ash', userInput: 'haggle');

    // The narrator saw the resolved deltas (chips), not raw model claims.
    expect(llm.seenAction, 'haggle');
    expect(llm.seenChanges, contains('+25 min'));
    expect(llm.seenChanges, contains('COIN'));
  });

  test('debug report captures context + both passes', () async {
    final repo = await seededRepo(InMemoryRepository());
    final llm = FixtureLlmClient(
      turnOutputs: [calmTurn(minutes: 15)],
      narrations: ['You walk on a while.'],
    );
    final controller = TurnController(
        repo: repo, llm: llm, embedder: FixtureEmbeddingClient());
    final turn = await controller.playTurn(actorId: 'ash', userInput: 'walk');

    final r = turn.report;
    expect(r.contextText, isNotNull);
    expect(r.contextText, contains('CHARACTER: Ash'));
    expect(r.rawLlmJson, isNotNull); // phase-1 consequences JSON
    expect(r.narrativeText, 'You walk on a while.');
    expect(r.narrativePrompt, contains('ACTION: walk'));
    // Usage is summed across both passes.
    expect(r.usage.model, isNotEmpty);
  });

  test('undo reverts every state change of the most recent turn', () async {
    final repo = await seededRepo(InMemoryRepository());
    final llm = FixtureLlmClient(
      turnOutputs: [
        const TurnOutput(
          narrative: '',
          proposedDeltas: ProposedDeltas(
            clockAdvanceMinutes: 30,
            stats: [StatOp(key: 'coin', op: StatOpKind.delta, value: 7)],
          ),
        ),
      ],
      narrations: ['done'],
    );
    final controller = TurnController(
        repo: repo, llm: llm, embedder: FixtureEmbeddingClient());
    await controller.playTurn(actorId: 'ash', userInput: 'trade');

    var p = await repo.projection();
    expect(p.characters['ash']!.subjectiveClock, 30);
    expect(p.characters['ash']!.stats['coin'], 17);

    // Revert everything after the turn's TurnCommitted seq - 1.
    final events = await repo.eventsUpTo(-1);
    final turnSeq =
        events.lastWhere((e) => e.type == EventType.turnCommitted).seq;
    await repo.revertAfter(turnSeq - 1);

    p = await repo.projection();
    expect(p.characters['ash']!.subjectiveClock, 0);
    expect(p.characters['ash']!.stats['coin'], 10, reason: 'coin delta undone');
  });
}
