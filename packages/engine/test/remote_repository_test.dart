/// Remote parity (§7, §11): the SAME conformance suite + a full engine
/// playthrough, against a real Supabase stack.
///
/// Gated on environment so CI without infrastructure skips cleanly:
///   SUPABASE_URL=http://127.0.0.1:54321 \
///   SUPABASE_KEY=`<anon or service key>` \
///   dart test test/remote_repository_test.dart
///
/// Bring the stack up with `supabase start` (migrations in
/// supabase/migrations apply automatically).
library;

import 'dart:convert';
import 'dart:io';

import 'package:living_worlds_engine/living_worlds_engine.dart';
import 'package:test/test.dart';

import 'helpers/fixtures.dart';
import 'helpers/repository_suite.dart';

void main() {
  final url = Platform.environment['SUPABASE_URL'];
  final key = Platform.environment['SUPABASE_KEY'];

  if (url == null || key == null) {
    test('remote parity (SKIPPED: set SUPABASE_URL + SUPABASE_KEY)', () {},
        skip: 'no Supabase stack configured');
    return;
  }

  var scopeCounter = 0;
  final runId = DateTime.now().millisecondsSinceEpoch;
  final created = <RemoteRepository>[];

  Future<WorldRepository> make() async {
    final repo = RemoteRepository(
      url: url,
      apiKey: key,
      scope: 'test-$runId-${scopeCounter++}',
    );
    created.add(repo);
    return repo;
  }

  tearDownAll(() async {
    for (final repo in created) {
      await repo.deleteScope();
    }
  });

  runRepositorySuite('RemoteRepository(supabase)', make);

  test('cross-implementation parity: remote == in-memory playthrough',
      () async {
    Future<String> playthrough(WorldRepository repo) async {
      await seededRepo(repo);
      final llm = FixtureLlmClient(turnOutputs: [
        const TurnOutput(
          narrative: 'You take a wound and a key.',
          proposedDeltas: ProposedDeltas(
            clockAdvanceMinutes: 30,
            status: [
              StatusOp(op: StatusOpKind.add, key: 'bleeding', severity: 1)
            ],
            inventory: [
              InventoryOp(op: InventoryOpKind.grant, item: 'rusty key')
            ],
          ),
          peril: true,
        ),
        calmTurn(minutes: 60),
      ]);
      final controller = TurnController(
          repo: repo,
          llm: llm,
          embedder: FixtureEmbeddingClient(),
          clock: fixedClock());
      await controller.playTurn(actorId: 'ash', userInput: 'explore');
      await controller.playTurn(actorId: 'ash', userInput: 'walk on');
      final p = await repo.projection();
      return jsonEncode(p.toJson());
    }

    final mem = await playthrough(InMemoryRepository());
    final remote = await playthrough(await make());
    expect(remote, mem);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('cloud saves round-trip through Supabase Storage', () async {
    final repo = await make() as RemoteRepository;
    await seededRepo(repo);
    const codec = SaveCodec();
    final blob = await codec.exportWorld(repo);
    await repo.saveWorldSnapshot('slot-1', blob);
    final loaded = await repo.loadWorldSnapshot('slot-1');
    final restored = await codec.importWorld(InMemoryRepository(), loaded);
    expect(restored.characters.keys, containsAll(['ash', 'brynn']));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
