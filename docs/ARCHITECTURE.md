# Living Worlds — Implementation Notes

Companion to [DESIGN.md](DESIGN.md) (the spec). Section references (§) point
there. This file records how the spec maps to code and the handful of
implementation decisions the spec left open.

## Where things live

| Spec concept | Code |
|---|---|
| Event log (§1.1) | `engine/src/model/event.dart`, append-only via `WorldRepository.appendEvent(s)` |
| Projections (§1.2) | `engine/src/projection/projection.dart` — `WorldProjection.replay` / `applyEvent` |
| LLM contract (§2) | `engine/src/llm/contract.dart` (`TurnOutput`, `ProposedDeltas`) |
| Tool loop (§2) | `LlmToolHandler` + `RepositoryToolHandler` (query_wiki / query_relationship / query_inventory) |
| Turn transaction (§3) | `engine/src/engine/turn_controller.dart` (assemble → LLM → engine → commit → render) |
| Deterministic subsystems (§4) | `engine/src/engine/turn_engine.dart` (+ `health.dart`, `death.dart`) |
| Rendezvous / SharedEvent (§4.4) | `engine/src/engine/rendezvous.dart`; auto-committed by the turn controller when other characters are present |
| Relationship graph (§4.5) | edges in the projection; clamped in the turn engine |
| Time-skip (§4.6) | `engine/src/engine/time_skip.dart` — single `TimeSkip` event, non-lethal |
| Seeding (§5.1) | `engine/src/wiki/seeding_session.dart` + `WorldService.create/updateWikiEntry` |
| Candidate queue (§5.2) | `wikiCandidateQueued/Promoted/Rejected` events |
| Hybrid retrieval (§5.3) | wiki index in `ContextAssembler`; cosine top-k in repositories; pgvector RPC remotely |
| Context budget (§6) | `engine/src/context/assembler.dart`; rolling summary in `summarizer.dart` |
| Storage ladder (§7) | `InMemoryRepository` / `LocalRepository` (sqlite3) / `RemoteRepository` (Supabase) behind one interface |
| Save/load (§8) | `engine/src/save/save_codec.dart` |
| Debug report (§9) | `engine/src/debug/report.dart`, attached to `TurnCommitted.cause` |
| Cost log (§10) | `engine/src/cost/cost_log.dart` |
| CLI observability | `engine/bin/lw.dart` (demo / inspect / replay / play) |

## Decisions the spec left open (and what was chosen)

- **Idempotency strategy (§0):** committed events carry *resolved absolute
  values* (`from → to`, item instance `uid`s, `resulting_qty`), so applying
  an event twice is a no-op and replay is exact. The engine never emits raw
  deltas into the log.
- **Deterministic RNG:** hand-rolled SplitMix64 (`util/rng.dart`) instead of
  `dart:math Random`, whose sequence is not guaranteed stable across VM
  versions. Golden tests pin `seedForTurn` values forever.
- **Status decay (§4.2):** evaluated lazily — `StatusInstance` stores base
  severity + `since_clock`, and `effectiveSeverity(at)` applies
  `decay_per_min`. No decay events, no log bloat, replay-exact. Statuses
  whose effective severity reaches 0 are expired at the next clock advance.
- **Health formula (§4.2):** `weight` lives on `StatusDef` (harm per
  severity point; negative = buff) and on stat defs flagged
  `affects_health` (hunger/fatigue penalties). Base vitality is the
  `vitality` stat when defined, else 100.
- **Peril hint (§2/§4.3):** the LLM `peril` flag only scales the multiplier
  (`perilHintBoost`, default 1.25). The safe gate uses only the
  engine-observed `peril_delta_applied` (a harmful status actually applied
  this turn), so the model can never open the death gate by assertion.
- **Instant death triggers (§4.3):** `StatusDef.lethalSeverity` (e.g.
  poison ≥ 10). Only statuses *touched this turn* can trigger, so a
  survivable time-skip cannot become a surprise death on the next quiet
  turn. In non-lethal contexts the trigger is suppressed and the status
  remains "to play out".
- **Turn event shape (§3):** one `TurnCommitted` (narrative, clock from→to,
  debug report in `cause`) followed by granular delta events sharing its
  `turn_id`; a `TimeSkip` is the single-event exception per §4.6.
- **SQLite driver (§7):** `package:sqlite3` directly rather than drift —
  an append-only log with JSON payloads gains nothing from codegen, and it
  keeps the engine pure Dart. The repository interface is unchanged either
  way.
- **Remote scoping:** Supabase tables are namespaced by a `scope` column
  (one world or test-run per scope) with `(scope, seq)` primary keys, so
  many worlds share a database and parity tests isolate cleanly. A DB
  trigger rejects UPDATE/DELETE on `lw_events` — append-only is enforced
  server-side.
- **Cloud saves (§7/§8):** Supabase Storage bucket `world-saves`, one JSON
  object per slot.
- **Meetings (§4.4):** marking characters "present in scene" injects cameo
  snapshots into context AND commits the turn's outcome as a `SharedEvent`
  for all participants, stamped with the writer's post-turn clock.
  First-writer-wins is ordering by `seq`; contradictions are fixed by undo,
  never edit.
- **Offline narrator (app):** a deterministic no-network `LlmClient` so the
  full loop is playable and widget-testable without keys. It is not a mock
  of intelligence — just canned prose; the engine path is identical.

## Testing map (§11)

- `packages/engine/test/` — 142 tests:
  - unit: `rng_test`, `health_test`, `death_test`, `turn_engine_test`
  - log/projection: `projection_test` (replay==live, idempotency, undo/redo)
  - property: `property_test` (randomized playthroughs; invariants + determinism)
  - golden: `golden_turns_test` (peril, item-gate, quest, meeting, death, failed-turn-commits-nothing, cost log)
  - rendezvous: `rendezvous_test` (cameo, canon both timelines, first-writer-wins)
  - time-skip: `time_skip_test` (single event, non-lethal, bounded, undoable)
  - storage: `repository_parity_test` + shared `helpers/repository_suite.dart`,
    `save_load_test`, `remote_repository_test` (env-gated)
  - context: `context_retrieval_test` (budget order, retrieval, summarizer)
  - wiki: `seeding_wiki_test`
- `app/test/app_flow_test.dart` — 11 widget tests over in-memory repos +
  fixture LLMs, including clamp/reject surfacing and the meeting →
  time-skip flow.

## Tunables (§14)

All in `EngineConfig` (defaults): `perTurnCapMinutes 240`,
`safeThreshold 60`, `dangerMidpoint 25`, `logisticK 0.12`,
`perilMultiplier 1.0`, `perilHintBoost 1.25`. Tune with the debug panel +
cost log during play; the CLI `demo --verbose` prints every eval.
