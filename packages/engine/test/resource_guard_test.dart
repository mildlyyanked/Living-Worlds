/// Hardened stats (§ hardened stats): resources can't be overspent, and
/// health has no directly-editable stat — it is composite.
library;

import 'package:living_worlds_engine/living_worlds_engine.dart';
import 'package:test/test.dart';

import 'helpers/fixtures.dart';

void main() {
  const engine = TurnEngine();

  Future<TurnResult> run(InMemoryRepository repo, List<StatOp> stats) async {
    final p = await repo.projection();
    return engine.runTurn(
      projection: p,
      input: TurnInput(
        actorId: 'ash',
        userInput: 'act',
        output: TurnOutput(
          narrative: '',
          proposedDeltas: ProposedDeltas(stats: stats),
        ),
      ),
      now: t0,
    );
  }

  test('overspending a resource is rejected, not clamped', () async {
    final repo = await seededRepo(InMemoryRepository()); // ash coin = 10
    final r = await run(
        repo, [const StatOp(key: 'coin', op: StatOpKind.delta, value: -50)]);
    final d = r.report.decisions.firstWhere((d) => d.section == 'stats');
    expect(d.outcome, DeltaOutcome.rejected);
    expect(d.reason, contains('insufficient'));

    await repo.appendEvents(r.events);
    final after = await repo.projection();
    expect(after.characters['ash']!.stats['coin'], 10,
        reason: 'no partial spend — balance untouched');
  });

  test('spending within balance is accepted', () async {
    final repo = await seededRepo(InMemoryRepository());
    final r = await run(
        repo, [const StatOp(key: 'coin', op: StatOpKind.delta, value: -6)]);
    final d = r.report.decisions.firstWhere((d) => d.section == 'stats');
    expect(d.outcome, DeltaOutcome.accepted);
    await repo.appendEvents(r.events);
    final after = await repo.projection();
    expect(after.characters['ash']!.stats['coin'], 4);
  });

  test('there is no directly-editable health/vitality stat', () async {
    final repo = await seededRepo(InMemoryRepository());
    final r = await run(repo,
        [const StatOp(key: 'vitality', op: StatOpKind.delta, value: -30)]);
    final d = r.report.decisions.firstWhere((d) => d.section == 'stats');
    expect(d.outcome, DeltaOutcome.rejected);
    expect(d.reason, contains('no such stat'));
  });

  test('the standard schema exposes vital needs but no vitality/health', () {
    final schema = WorldSchema.standard();
    expect(schema.statDef('vitality'), isNull);
    expect(schema.statDef('health'), isNull);
    expect(schema.statDef('hunger')!.affectsHealth, isTrue);
    expect(schema.statDef('thirst')!.affectsHealth, isTrue);
    expect(schema.statDef('coin')!.resource, isTrue);
  });
}
