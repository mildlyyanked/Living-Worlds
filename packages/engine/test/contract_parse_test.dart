/// Regression + robustness tests for parsing untrusted model output.
///
/// A real model follows the system prompt loosely: it emits wiki_candidates
/// WITHOUT an `id` (the engine assigns one) and may drop fields from delta
/// ops. Parsing must never hard-cast null — a single bad cast fails the whole
/// turn ("type 'Null' is not a subtype of type 'String'"). These lock that in.
library;

import 'dart:convert';

import 'package:living_worlds_engine/living_worlds_engine.dart';
import 'package:test/test.dart';

import 'helpers/fixtures.dart';

void main() {
  group('TurnOutput.fromJson tolerates model-shaped JSON', () {
    test('wiki_candidate without an id does not throw (the reported crash)',
        () {
      // Exactly the shape the system prompt asks for: no "id".
      final raw = jsonEncode({
        'narrative': 'You discover a drowned tunnel.',
        'proposed_deltas': {'clock_advance_minutes': 20},
        'peril': false,
        'wiki_candidates': [
          {
            'title': 'The Gullet',
            'category': 'Places',
            'body': 'A flooded smuggling tunnel.',
            'tags': ['harbor'],
          }
        ],
      });
      final out = OpenRouterLlmClient.parseTurnOutput(raw);
      expect(out.wikiCandidates, hasLength(1));
      expect(out.wikiCandidates.single.id, isEmpty);
      expect(out.wikiCandidates.single.title, 'The Gullet');
    });

    test('delta ops with missing fields parse without throwing', () {
      final raw = jsonEncode({
        'narrative': 'x',
        'proposed_deltas': {
          // Each op omits something a strict cast would choke on.
          'inventory': [
            {'item': 'rusty key'}, // no op
            {'op': 'grant'}, // no item
          ],
          'stats': [
            {'key': 'fatigue'}, // no op/value
            {'op': 'delta', 'value': 5}, // no key
          ],
          'status': [
            {'key': 'bleeding'}, // no op
          ],
          'relationships': [
            {'dim': 'trust'}, // no target/delta
          ],
          'quest': [
            {'step_id': 's1'}, // no quest_id/op
          ],
        },
      });
      expect(() => OpenRouterLlmClient.parseTurnOutput(raw), returnsNormally);
    });

    test('fenced ```json blocks are still parsed', () {
      const raw = '```json\n{"narrative":"hi","peril":false}\n```';
      expect(OpenRouterLlmClient.parseTurnOutput(raw).narrative, 'hi');
    });
  });

  test('engine assigns ids to id-less candidates and commits the turn',
      () async {
    final repo = await seededRepo(InMemoryRepository());
    final llm = FixtureLlmClient(turnOutputs: [
      OpenRouterLlmClient.parseTurnOutput(jsonEncode({
        'narrative': 'You find the Gullet.',
        'proposed_deltas': {'clock_advance_minutes': 10},
        'wiki_candidates': [
          {'title': 'The Gullet', 'category': 'Places', 'body': 'A tunnel.'}
        ],
      })),
    ]);
    final controller = TurnController(
        repo: repo, llm: llm, embedder: FixtureEmbeddingClient());
    final turn = await controller.playTurn(actorId: 'ash', userInput: 'look');
    expect(turn.died, isFalse);

    final p = await repo.projection();
    expect(p.pendingCandidates, hasLength(1));
    // Engine-assigned id, non-empty, so it can be promoted/rejected later.
    final cand = p.pendingCandidates.values.single;
    expect(cand.id, isNotEmpty);
    expect(cand.title, 'The Gullet');
  });
}
