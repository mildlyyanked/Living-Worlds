/// Repository parity (§11): the SAME suite runs against every
/// WorldRepository implementation — identical results prove the seam.
///
/// Targets here: InMemoryRepository and LocalRepository (SQLite, both
/// in-memory and on-disk). RemoteRepository joins via
/// remote_repository_test.dart when SUPABASE_URL is set.
library;

import 'dart:convert';
import 'dart:io';

import 'package:living_worlds_engine/living_worlds_engine.dart';
import 'package:test/test.dart';

import 'helpers/fixtures.dart';
import 'helpers/repository_suite.dart';

void main() {
  runRepositorySuite('InMemoryRepository', () async => InMemoryRepository());

  runRepositorySuite(
      'LocalRepository(sqlite, memory)', () async => LocalRepository.inMemory());

  runRepositorySuite('LocalRepository(sqlite, file)', () async {
    final dir = await Directory.systemTemp.createTemp('lw_repo_test');
    addTearDown(() => dir.delete(recursive: true));
    return LocalRepository.open('${dir.path}/world.db');
  });

  test('cross-implementation parity: identical playthrough, identical '
      'projections', () async {
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
      await repo.close();
      return jsonEncode(p.toJson());
    }

    final mem = await playthrough(InMemoryRepository());
    final sqlite = await playthrough(LocalRepository.inMemory());
    expect(sqlite, mem);
  });
}
