/// Rendezvous tests (§11): author an A→B meeting as a SharedEvent, then play
/// B to that timestamp; assert the SharedEvent is injected and immutable,
/// and that first-writer-wins holds on contradiction.
library;

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

  group('cameo snapshot (§4.4)', () {
    test('materializes B at A\'s subjective time from last-committed state',
        () async {
      await advance('ash', 120); // A at 120, B at 0
      final p = await repo.projection();
      final snap = await rendezvous.cameoSnapshot(
          projection: p, viewerId: 'ash', cameoId: 'brynn');
      expect(snap.character.name, 'Brynn');
      expect(snap.viewerClock, 120);
      expect(snap.asOfClock, 0);
      expect(snap.stale, isTrue,
          reason: 'B has not lived to minute 120 yet');
      expect(snap.toContextBlock(), contains('fixed canon'));
    });

    test('includes both relationship directions', () async {
      // Ash trusts Brynn +3.
      final p0 = await repo.projection();
      final r = engine.runTurn(
        projection: p0,
        input: const TurnInput(
          actorId: 'ash',
          userInput: 'reminisce',
          output: TurnOutput(
            narrative: 'Old debts remembered.',
            proposedDeltas: ProposedDeltas(relationships: [
              RelationshipOp(to: 'brynn', dim: 'trust', delta: 3)
            ]),
          ),
        ),
        now: t0,
      );
      await repo.appendEvents(r.events);
      final p = await repo.projection();
      final snap = await rendezvous.cameoSnapshot(
          projection: p, viewerId: 'ash', cameoId: 'brynn');
      expect(snap.outgoingEdge!.dims['trust'], 3);
      expect(snap.incomingEdge, isNull); // Brynn holds no opinion yet
    });
  });

  group('SharedEvent canon (§4.4)', () {
    test('one event lands on both timelines at the writer\'s clock',
        () async {
      await advance('ash', 100);
      final p = await repo.projection();
      final e = await rendezvous.commitSharedEvent(
        projection: p,
        writerId: 'ash',
        participants: ['ash', 'brynn'],
        summary: 'Ash and Brynn split the vault haul at the Gullet.',
      );
      expect(e.payload['at_clock'], 100);

      final p2 = await repo.projection();
      expect(p2.sharedEventsFor('ash'), hasLength(1));
      expect(p2.sharedEventsFor('brynn'), hasLength(1));
      expect(p2.sharedEventsFor('brynn').first.summary,
          contains('split the vault haul'));
    });

    test('immutable: no API mutates a committed SharedEvent; undo is the '
        'only recourse', () async {
      await advance('ash', 100);
      var p = await repo.projection();
      final before = await repo.lastSeq();
      await rendezvous.commitSharedEvent(
        projection: p,
        writerId: 'ash',
        participants: ['ash', 'brynn'],
        summary: 'Canon A.',
      );
      // The projection exposes SharedEventRecord (read-only) and the log is
      // append-only; the only way it disappears is a revert marker.
      await repo.revertAfter(before);
      p = await repo.projection();
      expect(p.sharedEventsFor('brynn'), isEmpty);
      await repo.unrevertUpTo(1 << 60);
      p = await repo.projection();
      expect(p.sharedEventsFor('brynn'), hasLength(1));
    });

    test('unknown participants and non-participating writers are rejected',
        () async {
      final p = await repo.projection();
      expect(
        () => rendezvous.commitSharedEvent(
            projection: p,
            writerId: 'ash',
            participants: ['ash', 'ghost'],
            summary: 'x'),
        throwsArgumentError,
      );
      expect(
        () => rendezvous.commitSharedEvent(
            projection: p,
            writerId: 'ash',
            participants: ['brynn'],
            summary: 'x'),
        throwsArgumentError,
      );
    });
  });

  group('first-writer-wins (§4.4)', () {
    test('when B reaches the timestamp, canon is injected as fixed context',
        () async {
      // A plays to 100 and writes canon involving B.
      await advance('ash', 100);
      var p = await repo.projection();
      await rendezvous.commitSharedEvent(
        projection: p,
        writerId: 'ash',
        participants: ['ash', 'brynn'],
        summary: 'Brynn agreed to smuggle the map north.',
      );

      // B is played toward/past minute 100.
      await advance('brynn', 90);
      p = await repo.projection();

      final canon = rendezvous.fixedCanonFor(
          projection: p, characterId: 'brynn', atClock: 100);
      expect(canon, hasLength(1));

      // And the context assembler renders it as non-negotiable.
      final assembled = const ContextAssembler().assemble(
        projection: p,
        actorId: 'brynn',
        fixedCanon: canon,
      );
      expect(assembled.text, contains('FIXED CANON'));
      expect(assembled.text, contains('smuggle the map north'));
      expect(
          assembled.sections
              .firstWhere((s) => s.section == 'fixed_canon')
              .included,
          isTrue,
          reason: 'canon must never be dropped by the budget');
    });

    test('contradiction: second writer cannot overwrite existing canon — '
        'the first SharedEvent stands', () async {
      await advance('ash', 100);
      var p = await repo.projection();
      final first = await rendezvous.commitSharedEvent(
        projection: p,
        writerId: 'ash',
        participants: ['ash', 'brynn'],
        summary: 'They parted as allies.',
      );

      // Later, B's session writes new canon about the same moment. It gets
      // its own event; the first record is untouched, and ordering by seq
      // makes the earlier writer's canon primary for that timestamp.
      await advance('brynn', 100);
      p = await repo.projection();
      final second = await rendezvous.commitSharedEvent(
        projection: p,
        writerId: 'brynn',
        participants: ['ash', 'brynn'],
        summary: 'They parted as enemies.',
      );

      p = await repo.projection();
      final canon = p.sharedEventsFor('brynn');
      expect(canon, hasLength(2));
      expect(canon.first.seq, first.seq,
          reason: 'first writer is first in canon order');
      expect(canon.first.summary, 'They parted as allies.');
      // Both remain: the log never silently edits (§4.4). Fixing bad canon
      // is an undo of the offending event, which restores the first record.
      await repo.revertAfter(second.seq - 1);
      p = await repo.projection();
      expect(p.sharedEventsFor('brynn'), hasLength(1));
      expect(p.sharedEventsFor('brynn').first.summary,
          'They parted as allies.');
    });
  });
}
