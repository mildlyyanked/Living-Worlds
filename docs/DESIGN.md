# Living Worlds — Tech & Product Design Document

**Status:** Ready for build. **Target:** Flutter (iOS + Android native), Supabase, OpenRouter.
**Design principle (read this first):** *The LLM proposes, the deterministic engine disposes.* Every gameplay turn returns narrative **plus** proposed state deltas; the engine validates, clamps, runs authoritative subsystems, and commits. The LLM never owns a number.

---

## 0. Architecture at a glance

```
┌─────────────────────────────── Flutter Client ───────────────────────────────┐
│  UI (World Select · World UI · Gameplay UI · Seeding UI · Debug Panel)         │
│  ── Turn Controller ──                                                         │
│      1 assemble context (budgeted)                                             │
│      2 call LLM (structured output + tool loop)                                │
│      3 validate + run engine subsystems (PURE, DETERMINISTIC, SEEDED)          │
│      4 commit events → recompute projections                                   │
│      5 render narrative + mechanical notifications + (debug report)            │
│  ── WorldRepository (interface) ──                                             │
│         LocalRepository (SQLite/drift)     RemoteRepository (Supabase)         │
└───────────────────────────────────────────────────────────────────────────────┘
        │ embeddings + completions (proxied)              │ pgvector · auth · storage
        ▼                                                 ▼
   OpenRouter  ◄──── Supabase Edge Function (key vault) ──┘
```

**Substrate:** the world is an **append-only event log**. Wiki, character sheets, relationship graph, clock, quests are all **projections** (materialized views) over that log. Undo = revert projection to before event N. Change logs and traceability are the storage model, not a feature. Delta application MUST be idempotent so replay is safe.

---

## 1. Data model

### 1.1 Event log (source of truth)
```
Event {
  id: uuid
  world_id: uuid
  seq: int                 # global monotonic per world; drives seeded RNG
  timeline: character_id | "WORLD"   # whose subjective stream this belongs to
  subjective_clock: int    # minutes; the acting character's time at commit
  type: enum               # TurnCommitted, WikiCreated, WikiUpdated,
                           # ItemGranted, ItemRemoved, StatChanged, StatusChanged,
                           # RelationshipChanged, QuestProgressed, SharedEvent,
                           # TimeSkip, CharacterDied, WorldCreated ...
  payload: json            # the validated delta(s) / content
  cause: json              # {turn_id, llm_raw_ref, user_input_ref}  (traceability)
  created_at: timestamptz
}
```
Events are immutable. "Undo" appends nothing to history conceptually — it rebuilds projections up to `seq = N` and marks events `> N` as reverted (soft, so redo works). Keep a `revert_marker` table rather than deleting.

### 1.2 Projections (rebuildable from log)
- **Character sheet:** stats map, status flags, inventory, health rating (derived), subjective_clock, alive flag, active quests.
- **Wiki:** entries + embeddings + the compact index.
- **Relationship graph:** directed edges with multi-dimensional values.
- **World clock display:** `max(subjective_clock)` across living characters.

### 1.3 Core records
```
World { id, name, seed:int, created_at, settings:json, schema:WorldSchema }

WorldSchema {                      # per-world configurable
  stat_defs: [{key, min, max, default, affects_health:bool, weight:float}]
  status_defs: [{key, label, decay_per_min:float?, severity_scale:bool}]
  wiki_categories: [string]        # pre-defined categories
  relationship_dims: [string]      # e.g. trust, affection, fear, respect
}

Character {
  id, world_id, name, portrait?, bio, subjective_clock:int, alive:bool,
  stats: {key: value}, status: [{key, severity?, since_clock}],
  inventory: [ItemInstance], quests: [Quest]
}

Quest {
  id, title, hidden:bool, steps:[{id, desc, done:bool}],
  reward: { items:[ItemSpec], stats:[{key, delta}] },
  state: active|complete|failed
}

WikiEntry {
  id, world_id, title, category, body, tags:[string],
  clock_ref:int?,           # if this entry is a timeline event
  embedding: vector,        # BLOB (local) / pgvector (remote)
  version:int, updated_at
}

ItemDef {
  id, world_id, name, desc,
  affordances: [string],    # verbs enabled: "unlock","heal","bribe","light"
  effects: [{on_use, stat/status delta}],
  consumable:bool, stackable:bool
}
ItemInstance { def_id, qty, uid, state:json }   # per-character possession

RelationshipEdge { world_id, from_char, to_char, dims:{dim:value}, notes:[] }
```

---

## 2. The LLM contract (keystone)

Every gameplay turn the model returns **strict JSON** (enforce via function-calling / JSON mode; pin to a tool-calling-reliable model such as Claude or GPT-4-class):

```jsonc
{
  "narrative": "prose shown to the player",
  "proposed_deltas": {
    "clock_advance_minutes": 45,
    "inventory": [{ "op": "grant|remove|use", "item": "rusty key", "qty": 1, "reason": "" }],
    "stats":   [{ "key": "fatigue", "op": "delta|set", "value": 10, "reason": "" }],
    "status":  [{ "op": "add|remove", "key": "bleeding", "severity": 2, "reason": "" }],
    "relationships": [{ "to": "char_id", "dim": "trust", "delta": -1, "reason": "" }],
    "quest":   [{ "quest_id": "", "op": "progress|complete|fail", "step_id": "", "reason": "" }]
  },
  "peril": true,               // HINT ONLY — engine decides death gating
  "wiki_candidates": [ /* async-extracted; see §5 */ ]
}
```
Plus a native **tool loop** the model can call before finalizing:
- `query_wiki(title? category? free_text?) -> entries`
- `query_relationship(char_a, char_b?) -> edges`
- `query_inventory(char_id) -> items+affordances`

**Every field in `proposed_deltas` is a proposal.** The engine is free to accept, clamp, or reject each independently (§4). `peril` is an input to death gating, never the decision.

---

## 3. Gameplay loop (a turn is a transaction)

1. **Assemble context** (budgeted — §6): character sheet (always) → recent turns verbatim + rolling summary of older → wiki index (always) + semantic top-k bodies → relationship snapshot of anyone present → active quests → clock/status/inventory-with-affordances.
2. **User input.**
3. **LLM** runs tool loop, returns structured output.
4. **Validate + run subsystems** in order: inventory legality → apply stat/status → recompute health → clock advance → **death eval** → quest checks → relationship apply. Each step emits an accept/clamp/reject record.
5. **Commit** events → recompute projections.
6. **Render** narrative + mechanical notifications (`−12 HP`, `Acquired: rusty key`, `+45 min`) + debug report if toggle on.

Determinism: everything in step 4 is a **pure function** `(state, validated_deltas, seed) -> (new_state, events, report)`. `seed_turn = hash(world.seed, event.seq)`.

---

## 4. Subsystems (deterministic engine)

### 4.1 Inventory & affordances
Items carry `affordances` (verbs) and `effects`. Affordances are injected into context so the model knows what's newly possible. Wiki entries / scene gates may declare `requires: <affordance|item>`; the engine only opens that branch if held. On `op:"use"`, engine checks possession + validity, applies effects, decrements if consumable. Illegal item ops (using an item not held, granting a nonexistent def) are **rejected** with reason.

### 4.2 Health (derived, never raw)
```
health = clamp(
   base_vitality
   − Σ(injury.severity * injury.weight)
   − hunger_penalty − fatigue_penalty
   + Σ(buffs), 0, 100)
```
Injuries/hunger/fatigue are **status flags** with severity and per-minute decay (from `status_defs`). Health is recomputed after every status/stat change — it's a projection, not stored state.

### 4.3 Death eval (seeded, gated, reproducible)
```
if health >= SAFE_THRESHOLD and not peril_delta_applied: P = 0
else:
    P = logistic(k * (DANGER_MIDPOINT − health)) * peril_multiplier
draw = seeded_rng(seed_turn)
death = draw < P  OR  engine_instant_death_trigger (e.g. fall, poison lethal stack)
```
`peril_delta_applied` = an injury/peril status was actually applied this turn (engine-observed, not just the LLM flag). On death: append `CharacterDied`, freeze that timeline, offer epilogue narration. Time-skips (§4.6) are **non-lethal** — no roll; near-lethal outcomes become a status to play out.

### 4.4 World clock & rendezvous (the hard one)
- Each character has `subjective_clock`. World display = `max` over living characters.
- A turn advances the actor's `subjective_clock` by validated `clock_advance_minutes` (clamped `[0, PER_TURN_CAP]` unless an explicit declared skip).
- **Meeting / cameo model:** when narrative introduces character B into A's session, engine materializes an **NPC-cameo snapshot** of B valid at A's current subjective time, from B's last-committed projection + wiki + relationship graph. The meeting outcome is written as a **`SharedEvent`** referencing both A and B, stamped with A's subjective time, appended to **both** timelines.
- **First-writer-wins:** a `SharedEvent` is immutable canon. When B is later played to/past that timestamp, the SharedEvent is injected as **fixed, non-negotiable context** B must narrate around. Bad canon is fixable only via undo (event log), never silent edit.

### 4.5 Relationship graph
Directed, multi-dimensional edges (`relationship_dims` from schema). "Opinion of" = edge `A→B`; "opinion by" = `B→A`. Deltas clamped to per-dim ranges. Snapshot of present characters injected into context; queryable via `query_relationship`.

### 4.6 Time-skip / catch-up generator
When opening B after the world has advanced:
1. User chooses resume point: **after last shared event** or **at latest world clock**.
2. Generator produces a retrospective for `[B.subjective_clock, target]`, **anchored to** every SharedEvent B participated in in that window (fixed), consistent with wiki + B's state/quests.
3. Emits **bounded** proposed deltas → normal engine validation, **non-lethal**.
4. Commits a single `TimeSkip` event (holds synthesized summary + applied deltas) → undoable/traceable. B's subjective_clock jumps to target.

---

## 5. Wiki, seeding & retrieval

### 5.1 Seeding session (behind-the-scenes workshop)
A ChatGPT-style window whose job is to create/update wiki entries. The model may ask clarifying questions to sharpen an entry. Output is a proposed `WikiCreated`/`WikiUpdated` event (title, category from the predefined set, body, tags, optional `clock_ref` for timeline entries). Every change is an event → change log + undo. Distinct from gameplay: no clock advance, no death, no character state.

### 5.2 Async fact extraction from gameplay
Gameplay turns may surface `wiki_candidates`. Extraction runs **non-blocking** (post-turn) so it never adds turn latency; candidates land in a review queue the user promotes/edits/rejects in the Wiki tab (each promotion is an event).

### 5.3 Retrieval (hybrid — cheap + robust)
1. **Always in context:** compact index `{title, category, one-line summary}` of the whole wiki (or relevant categories) → model knows what exists, issues precise `query_wiki`.
2. **Semantic top-k:** embed (recent window + user input), retrieve top-k bodies.
   - **Local:** brute-force cosine over SQLite-stored embedding BLOBs (sub-ms at this scale).
   - **Remote:** pgvector `<->`.
3. Embeddings generated via OpenRouter embedding endpoint (network already required for completions).

---

## 6. Context budget & summarization
- Hard token budget per turn; sections filled by priority: sheet (always) > current clock/status/inventory > active quests > relationship snapshot of present chars > recent turns verbatim > wiki index > semantic wiki bodies > rolling summary of old turns.
- **Rolling summarization:** when verbatim history exceeds its slice, oldest turns are folded into a running summary (its own async LLM call, cached as an event). Experiment-gated behind a setting.
- Debug report includes per-section token counts so pollution/overflow is visible.

---

## 7. Storage: local-first with a remote-parity ladder
Single interface, three test targets:

| Target | Impl | Use |
|---|---|---|
| **On-device** | `LocalRepository` — drift/SQLite, embeddings as BLOB, brute-force cosine | fast mobile debug loop, zero bootstrap |
| **Local Supabase** | `RemoteRepository` → Docker `supabase start` on PC, device via LAN IP | exercise real remote code path off-cloud |
| **Cloud Supabase** | `RemoteRepository` → hosted | production |

```
abstract class WorldRepository {
  Future<void> appendEvent(Event e);
  Future<List<Event>> eventsUpTo(int seq);
  Future<WorldProjection> projection({int? atSeq});   // rebuild/undo
  Future<List<WikiEntry>> semanticSearch(Vector q, {int k});
  Future<List<WikiEntry>> structuredWikiQuery({String? title, String? category});
  Future<void> saveWorldSnapshot(String blob);        // §8
  Future<String> loadWorldSnapshot(String id);
}
```
Save format = text/JSON (full event log + schema) until size forces binary. Cloud saves via Supabase storage; local saves to device. **API keys never touch the client** — completions/embeddings are proxied through a Supabase Edge Function key vault (in pure-local mode a dev-only direct key path guarded behind a debug flag is acceptable).

---

## 8. Save / load
A world save = `{ world record, schema, full event log, revert markers, projection cache }`. Load = restore log + rebuild projections (or trust cache + verify). Because projections derive from the log, saves are inherently consistent and diff-able.

---

## 9. Debug mode (temp toggle)
Bubbles up the turn transaction:
- Raw LLM structured output **pre-validation**.
- Each delta: accepted / clamped(from→to) / rejected(reason).
- Tool calls + results.
- Death eval: `health, P, seed_turn, draw, outcome`.
- Context assembly: per-section token counts, what wiki entries were retrieved and why.
- `TurnDebugReport` is a first-class object attached to the `TurnCommitted` event's `cause`, so bugs are inspectable after the fact, not just live.

## 10. Cost & latency logging
Per turn: `{model, prompt_tokens, completion_tokens, embedding_tokens, computed_cost, latency_ms, cached:bool}` (cost from OpenRouter usage/generation stats). Aggregated per session/world. Latency recorded, not optimized; cost surfaced prominently.

---

## 11. Test strategy (fully remote-runnable)
The whole point of "LLM proposes, engine disposes" is that the **engine is pure and the LLM is mockable.**

- **Unit (pure, no network):** health clamp formula; death eval determinism (same seed ⇒ same outcome); inventory legality (reject unheld-use, nonexistent-grant); status decay; relationship clamps; clock advance clamps; delta idempotency; `replay(log) == projection`; undo/redo correctness.
- **Property tests:** applying any delta then reverting returns identical projection; health always in `[0,100]`; replaying a shuffled-but-causally-valid log is stable.
- **Golden / integration (mocked LLM):** feed fixture structured-outputs through the real engine, assert resulting events + projections. One fixture per scenario (peril turn, item-gated branch, meeting/cameo, time-skip, quest completion, death).
- **Rendezvous tests:** author A→B meeting as SharedEvent, then play B to that timestamp, assert SharedEvent injected + immutable; assert first-writer-wins on contradiction.
- **Repository parity:** same test suite runs against `LocalRepository` and `RemoteRepository` (Docker Supabase) — identical results prove the seam.
- **LLM mock harness:** a `LlmClient` interface with a `FixtureLlmClient` returning canned structured outputs/tool responses; production `OpenRouterLlmClient` behind the same interface.

---

## 12. UI spec
**World Select** → per-world tiles → **World UI**:
- *Wiki tab:* content viewer, change log (with undo/redo), seeding session window, candidate review queue.
- *Characters tab:* list → **Gameplay UI**.
- *Save/Load tab.*
- *Relationship graph viewer.*
- *Clock display* (furthest world clock).
- *Map / Timeline* — deferred, stubbed.

**Gameplay UI:** character info panel (name, stats, status, health) beside main **chat window**; toggleable overlays for **inventory** (with affordances), **quests**, **relationships**; debug panel behind toggle; mechanical-notification inline chips.

**Seeding UI:** ChatGPT-style workshop window bound to wiki CRUD with clarifying-question flow and change-log write-through.

---

## 13. v1 scope & milestones
Deferred: Map, Timeline viewer. In v1: single-character playable loop → wiki + seeding → inventory/health/death → clock + cameo meetings → time-skip → relationship graph viewer.

1. **M1 – Engine core:** event log, projections, health/death/inventory/clock subsystems, full unit+property suite, `FixtureLlmClient`. *No UI, no network.*
2. **M2 – LocalRepository + minimal Gameplay UI:** playable single character on-device, debug panel, cost log.
3. **M3 – Wiki + seeding + hybrid retrieval** (local brute-force).
4. **M4 – Relationships, quests, cameo meetings, SharedEvent + first-writer-wins.**
5. **M5 – Time-skip/catch-up.**
6. **M6 – RemoteRepository (Supabase + pgvector + Edge Function proxy), repository-parity tests, cloud saves.**

---

## 14. Open decisions flagged for owner
- Time-skip is **non-lethal** (chosen) — override if you want lethal fast-forwards.
- `PER_TURN_CAP`, `SAFE_THRESHOLD`, `DANGER_MIDPOINT`, logistic `k`, `peril_multiplier` — tune during M2 with debug/cost logs.
- Model pinning: default to a tool-calling-reliable model; the design assumes strict JSON adherence.
- Whether the always-in-context wiki index is whole-wiki or category-scoped once entry counts grow.
