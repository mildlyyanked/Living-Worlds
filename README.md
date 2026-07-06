# Living Worlds

An LLM-narrated life-sim where **the LLM proposes and the deterministic
engine disposes**: every gameplay turn returns narrative plus proposed state
deltas; a pure, seeded engine validates, clamps, or rejects each delta
independently and commits the result to an append-only event log. The LLM
never owns a number.

Built to the spec in [`docs/DESIGN.md`](docs/DESIGN.md); implementation notes
in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Layout

| Path | What it is |
|---|---|
| `packages/engine/` | Pure Dart engine: event log, projections, subsystems, LLM contract, repositories (in-memory / SQLite / Supabase), retrieval, save/load, cost log. **Zero Flutter dependencies.** |
| `packages/engine/bin/lw.dart` | Headless CLI harness: scripted demo playthrough, DB inspection, replay verification, interactive play. |
| `app/` | Flutter client (iOS + Android): world select, gameplay chat, wiki + seeding workshop, relationship graph, save/load, debug panel. |
| `supabase/` | SQL migrations (event log, pgvector, storage bucket) and the `llm-proxy` Edge Function key vault. |

## Quick start (no network, no keys)

```bash
# Engine test suite: 142 tests — unit, property, golden, parity, rendezvous.
cd packages/engine
dart pub get && dart test

# Watch the whole engine play a scripted story with full debug output:
dart run living_worlds_engine:lw demo --verbose

# Persist it and poke at the event log:
dart run living_worlds_engine:lw demo --db /tmp/world.db
dart run living_worlds_engine:lw inspect /tmp/world.db --events
dart run living_worlds_engine:lw inspect /tmp/world.db --turn 7   # debug report
dart run living_worlds_engine:lw replay /tmp/world.db             # replay == live?

# The app (11 widget tests, then run it):
cd ../../app
flutter test
flutter run
```

The app ships with an **offline narrator** (deterministic canned prose) so
the full loop — turns, clamps, death eval, wiki candidates, time-skips —
works with no API key. Switch to OpenRouter (dev key) or the Supabase
key-vault proxy in Settings.

## The one idea

```
user input ─► context assembler (budgeted §6)
           ─► LLM (tool loop: query_wiki / query_relationship / query_inventory)
           ─► strict-JSON proposals (§2)
           ─► TurnEngine: validate → clamp/reject per delta →
              inventory → stats/status → health → clock → death → quests → rels (§4)
           ─► events (absolute values, idempotent) appended to the log
           ─► projections rebuilt (sheet, wiki, graph, clock)
           ─► narrative + mechanical chips + TurnDebugReport (§9)
```

Determinism: `seed_turn = hash(world.seed, event.seq)`; same log ⇒ same
world, same death rolls, forever. Undo is a revert marker, never a deletion.

## Testing (the point of the whole architecture)

- `dart test` in `packages/engine`: health/death/inventory/clock/status
  unit tests, **property tests** that run randomized playthroughs asserting
  invariants (health ∈ [0,100], replay == live, idempotency, undo
  round-trips), **golden fixtures** for peril / item-gate / meeting /
  time-skip / quest / death scenarios, repository conformance + parity.
- `flutter test` in `app`: full UI flows on in-memory repos + fixture LLMs,
  including "engine rejects what the LLM invents" surfaced in the debug
  panel.
- Remote parity: `supabase start`, then
  `SUPABASE_URL=... SUPABASE_KEY=... dart test test/remote_repository_test.dart`
  runs the same conformance suite against PostgREST/pgvector/Storage.
- `dart run living_worlds_engine:lw demo --verbose` is the fastest way to
  *see* the current state of the build end to end.

## Production key handling (§7)

API keys never touch the client: deploy `supabase/functions/llm-proxy`,
`supabase secrets set OPENROUTER_API_KEY=...`, and point the app's Settings
at your Supabase URL. The dev-only direct-key path exists behind Settings
for pure-local play.
