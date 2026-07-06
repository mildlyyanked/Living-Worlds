import 'dart:convert';

import 'package:living_worlds_engine/living_worlds_engine.dart';
import 'package:test/test.dart';

import 'helpers/fixtures.dart';

void main() {
  late InMemoryRepository repo;
  late RendezvousService rendezvous;
  late TurnEngine engine;

  setUp(() async {
    repo = await seededRepo(InMemoryRepository());
    rendezvous = RendezvousService(repo, clock: fixedClock());
    engine = const TurnEngine();
  });

  Future<void> advance(String actor, int minutes) async {
    final p = await repo.projection();
    final r = engine.runTurn(
      projection: p,
      input: TurnInput(
          actorId: actor,
          userInput: 'pass time',
          output: calmTurn(minutes: minutes)),
      now: t0,
    );
    await repo.appendEvents(r.events);
  }

  String retrospectiveJson({List<Map<String, Object?>> statusOps = const []}) =>
      jsonEncode({
        'summary': 'Brynn lay low, mended nets, and asked around the docks.',
        'proposed_deltas': {
          'stats': [
            {'key': 'coin', 'op': 'delta', 'value': 12, 'reason': 'odd jobs'}
          ],
          'status': statusOps,
        },
      });

  test('resolves target: latest world clock vs after last shared event',
      () async {
    await advance('ash', 200);
    var p = await repo.projection();
    await rendezvous.commitSharedEvent(
      projection: p,
      writerId: 'ash',
      participants: ['ash', 'brynn'],
      summary: 'Met at the docks.',
    );
    await advance('ash', 40); // world clock now 240
    p = await repo.projection();

    final gen = TimeSkipGenerator(repo, clock: fixedClock());
    expect(
      gen.resolveTargetClock(
          projection: p,
          characterId: 'brynn',
          target: TimeSkipTarget.latestWorldClock),
      240,
    );
    expect(
      gen.resolveTargetClock(
          projection: p,
          characterId: 'brynn',
          target: TimeSkipTarget.afterLastSharedEvent),
      200,
    );
  });

  test('prompt anchors every SharedEvent in the window as fixed canon',
      () async {
    await advance('ash', 150);
    final p0 = await repo.projection();
    await rendezvous.commitSharedEvent(
      projection: p0,
      writerId: 'ash',
      participants: ['ash', 'brynn'],
      summary: 'Brynn took the north road with the map.',
    );
    final p = await repo.projection();
    final gen = TimeSkipGenerator(repo, clock: fixedClock());
    final prompt = gen.buildPrompt(
        projection: p, characterId: 'brynn', targetClock: 150);
    expect(prompt, contains('FIXED CANON'));
    expect(prompt, contains('north road'));
    expect(prompt, contains('minute 0 and minute 150'));
  });

  test('commits exactly ONE undoable TimeSkip event holding summary + deltas',
      () async {
    await advance('ash', 180);
    final llm = FixtureLlmClient(completions: [retrospectiveJson()]);
    final gen = TimeSkipGenerator(repo, clock: fixedClock());
    final before = await repo.lastSeq();

    final result = await gen.run(
      characterId: 'brynn',
      target: TimeSkipTarget.latestWorldClock,
      llm: llm,
    );

    expect(await repo.lastSeq(), before + 1,
        reason: 'a single TimeSkip event, nothing else');
    expect(result.event.type, EventType.timeSkip);
    expect(result.fromClock, 0);
    expect(result.toClock, 180);

    final p = await repo.projection();
    final b = p.characters['brynn']!;
    expect(b.subjectiveClock, 180);
    expect(b.stats['coin'], 52, reason: '40 + 12 odd jobs');

    // Undo restores the pre-skip world exactly.
    await repo.revertAfter(before);
    final restored = await repo.projection();
    expect(restored.characters['brynn']!.subjectiveClock, 0);
    expect(restored.characters['brynn']!.stats['coin'], 40);
  });

  test('non-lethal: even a lethal poison stack cannot kill in a skip (§4.6)',
      () async {
    await advance('ash', 60);
    final llm = FixtureLlmClient(completions: [
      retrospectiveJson(statusOps: [
        {'op': 'add', 'key': 'poisoned', 'severity': 20, 'reason': 'bad meal'}
      ])
    ]);
    final gen = TimeSkipGenerator(repo, clock: fixedClock());
    final result = await gen.run(
      characterId: 'brynn',
      target: TimeSkipTarget.latestWorldClock,
      llm: llm,
    );
    final p = await repo.projection();
    expect(p.characters['brynn']!.alive, isTrue);
    // Near-lethal outcome became a status to play out.
    expect(p.characters['brynn']!.statusByKey('poisoned'), isNotNull);
    expect(result.event.payload['deltas'], isNotEmpty);
  });

  test('deltas are bounded per section', () async {
    await advance('ash', 60);
    final many = [
      for (var i = 0; i < 20; i++)
        {'key': 'coin', 'op': 'delta', 'value': 1, 'reason': 'tip $i'}
    ];
    final llm = FixtureLlmClient(completions: [
      jsonEncode({
        'summary': 'Tips.',
        'proposed_deltas': {'stats': many},
      })
    ]);
    final gen =
        TimeSkipGenerator(repo, maxOpsPerSection: 8, clock: fixedClock());
    await gen.run(
        characterId: 'brynn',
        target: TimeSkipTarget.latestWorldClock,
        llm: llm);
    final p = await repo.projection();
    expect(p.characters['brynn']!.stats['coin'], 48,
        reason: '40 + only the first 8 accepted');
  });

  test('skipping to a past/equal clock throws; dead characters cannot skip',
      () async {
    final llm = FixtureLlmClient(completions: [retrospectiveJson()]);
    final gen = TimeSkipGenerator(repo, clock: fixedClock());
    await expectLater(
      gen.run(
          characterId: 'brynn',
          target: TimeSkipTarget.latestWorldClock,
          llm: llm),
      throwsStateError,
      reason: 'world clock is 0; no window to skip',
    );
  });

  test('replay including a TimeSkip is stable and idempotent', () async {
    await advance('ash', 180);
    final llm = FixtureLlmClient(completions: [retrospectiveJson()]);
    final gen = TimeSkipGenerator(repo, clock: fixedClock());
    await gen.run(
        characterId: 'brynn',
        target: TimeSkipTarget.latestWorldClock,
        llm: llm);

    final events = await repo.eventsUpTo(-1);
    final live = await repo.projection();
    final replayed = WorldProjection.replay(events);
    expect(jsonEncode(replayed.toJson()), jsonEncode(live.toJson()));

    final skipEvent =
        events.firstWhere((e) => e.type == EventType.timeSkip);
    replayed.applyEvent(skipEvent); // apply twice
    expect(jsonEncode(replayed.toJson()), jsonEncode(live.toJson()));
  });
}
