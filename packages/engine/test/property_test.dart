/// Property tests (§11): random-but-seeded turn streams through the real
/// engine, asserting the invariants that must hold for ANY input:
///  - health always in [0, 100]
///  - apply-then-revert returns the identical projection
///  - replay of the log always equals the live fold
///  - the engine never emits a non-idempotent event
library;

import 'dart:convert';

import 'package:living_worlds_engine/living_worlds_engine.dart';
import 'package:test/test.dart';

import 'helpers/fixtures.dart';

String snap(WorldProjection p) => jsonEncode(p.toJson());

/// Generates arbitrary (often illegal) proposals — the engine must cope.
TurnOutput randomOutput(SplitMix64 rng) {
  T pick<T>(List<T> xs) =>
      xs[(rng.nextInt64() & 0x7FFFFFFFFFFFFFFF) % xs.length];
  double range(double lo, double hi) => lo + rng.nextDouble() * (hi - lo);

  return TurnOutput(
    narrative: 'chaos ${rng.nextInt64() & 0xFFFF}',
    peril: rng.nextDouble() < 0.3,
    proposedDeltas: ProposedDeltas(
      clockAdvanceMinutes: (range(-100, 500)).round(),
      inventory: [
        if (rng.nextDouble() < 0.5)
          InventoryOp(
            op: pick(InventoryOpKind.values),
            item: pick(
                ['rusty key', 'healing potion', 'vorpal sword', 'item-potion']),
            qty: (range(0, 3)).round(),
          ),
      ],
      stats: [
        if (rng.nextDouble() < 0.7)
          StatOp(
            key: pick(['hunger', 'fatigue', 'coin', 'charisma']),
            op: pick(StatOpKind.values),
            value: range(-200, 200),
          ),
      ],
      status: [
        if (rng.nextDouble() < 0.6)
          StatusOp(
            op: pick(StatusOpKind.values),
            key: pick(['bleeding', 'injured', 'poisoned', 'rested', 'x']),
            severity: range(0, 8),
          ),
      ],
      relationships: [
        if (rng.nextDouble() < 0.4)
          RelationshipOp(
            to: pick(['brynn', 'ghost']),
            dim: pick(['trust', 'fear', 'envy']),
            delta: range(-30, 30),
          ),
      ],
      quest: [
        if (rng.nextDouble() < 0.3)
          QuestOp(
            questId: pick(['q-map', 'q-nope']),
            op: pick(QuestOpKind.values),
            stepId: pick(['s1', 's2', 's9']),
          ),
      ],
    ),
  );
}

void main() {
  const engine = TurnEngine();
  const trials = 40;
  const turnsPerTrial = 12;

  test('invariants hold across $trials random seeded playthroughs', () async {
    for (var trial = 0; trial < trials; trial++) {
      final rng = SplitMix64(1000 + trial);
      final repo = await seededRepo(InMemoryRepository());
      final checkpoints = <int, String>{};

      for (var turn = 0; turn < turnsPerTrial; turn++) {
        final p = await repo.projection();
        final actor = p.characters['ash']!;
        if (!actor.alive) break;

        checkpoints[await repo.lastSeq()] = snap(p);

        final r = engine.runTurn(
          projection: p,
          input: TurnInput(
              actorId: 'ash',
              userInput: 'chaos',
              output: randomOutput(rng)),
          now: t0,
        );
        await repo.appendEvents(r.events);

        final after = await repo.projection();
        final world = after.world!;

        // Health invariant.
        for (final c in after.characters.values) {
          final h = healthOf(c, world.schema, const EngineConfig());
          expect(h, inInclusiveRange(0, 100),
              reason: 'trial $trial turn $turn: health out of range');
        }

        // Stats stay inside schema ranges.
        for (final c in after.characters.values) {
          for (final e in c.stats.entries) {
            final def = world.schema.statDef(e.key);
            if (def != null) {
              expect(e.value, inInclusiveRange(def.min, def.max),
                  reason: 'trial $trial turn $turn: stat ${e.key}');
            }
          }
        }

        // Relationship dims stay clamped.
        for (final edge in after.edges.values) {
          for (final v in edge.dims.values) {
            expect(
                v,
                inInclusiveRange(world.schema.relationshipDimMin,
                    world.schema.relationshipDimMax));
          }
        }

        // Clock never regresses and respects the cap.
        final a2 = after.characters['ash']!;
        expect(a2.subjectiveClock, greaterThanOrEqualTo(actor.subjectiveClock));
        expect(
            a2.subjectiveClock - actor.subjectiveClock,
            lessThanOrEqualTo(const EngineConfig().perTurnCapMinutes));

        // Live fold == full replay.
        final events = await repo.eventsUpTo(-1);
        expect(snap(WorldProjection.replay(events)), snap(after),
            reason: 'trial $trial turn $turn: replay != live');

        // Idempotency: re-applying this turn's events changes nothing.
        final again = WorldProjection.replay(events);
        for (final e in r.events) {
          again.applyEvent(e);
        }
        expect(snap(again), snap(after),
            reason: 'trial $trial turn $turn: non-idempotent event');
      }

      // Apply-then-revert: undoing back to every checkpoint reproduces it.
      for (final entry in checkpoints.entries) {
        await repo.revertAfter(entry.key);
        expect(snap(await repo.projection()), entry.value,
            reason: 'trial $trial: undo to seq ${entry.key} diverged');
        await repo.unrevertUpTo(1 << 60); // redo all for next checkpoint
      }
    }
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('death outcomes are identical for identical logs (determinism)',
      () async {
    for (var trial = 0; trial < 10; trial++) {
      Future<List<bool>> playthrough() async {
        final rng = SplitMix64(4242 + trial);
        final repo = await seededRepo(InMemoryRepository());
        final deaths = <bool>[];
        for (var turn = 0; turn < 10; turn++) {
          final p = await repo.projection();
          if (!p.characters['ash']!.alive) break;
          final r = engine.runTurn(
            projection: p,
            input: TurnInput(
                actorId: 'ash',
                userInput: 'chaos',
                output: randomOutput(rng)),
            now: t0,
          );
          deaths.add(r.died);
          await repo.appendEvents(r.events);
        }
        return deaths;
      }

      expect(await playthrough(), await playthrough());
    }
  });
}
