/// The deterministic turn engine (§3, §4).
///
/// `runTurn` is a pure function
/// `(projection, turn output, seed, config) -> (events, report)`.
/// It validates every proposed delta independently (accept / clamp / reject),
/// runs the authoritative subsystems in spec order — inventory legality →
/// stat/status apply → health recompute → clock advance → death eval →
/// quest checks → relationship apply — and emits idempotent events carrying
/// resolved absolute values. It never mutates the input projection: callers
/// commit the returned events and fold them via `applyEvent`, so live state
/// and replayed state share one code path.
library;

import '../debug/report.dart';
import '../llm/contract.dart';
import '../llm/llm_client.dart';
import '../model/character.dart';
import '../model/event.dart';
import '../model/item.dart';
import '../model/quest.dart';
import '../model/wiki.dart';
import '../model/world_schema.dart';
import '../projection/projection.dart';
import '../util/rng.dart';
import 'config.dart';
import 'death.dart';
import 'health.dart';
import 'validation.dart';

class TurnInput {
  const TurnInput({
    required this.actorId,
    required this.userInput,
    required this.output,
    this.nonLethal = false,
    this.allowUncappedClock = false,
    this.observationOnly = false,
  });

  final String actorId;
  final String userInput;
  final TurnOutput output;

  /// Time-skips are non-lethal (§4.6): no death roll.
  final bool nonLethal;

  /// Explicit declared skips may exceed PER_TURN_CAP (§4.4).
  final bool allowUncappedClock;

  /// An observation: the actor looks/examines to gain information. The engine
  /// discards every proposed delta and advances no clock — no consequences to
  /// stats, status, inventory, relationships or quests, and no death roll.
  /// Wiki candidates are still queued (observing reveals lore worth keeping).
  final bool observationOnly;
}

class TurnResult {
  const TurnResult({
    required this.events,
    required this.report,
    required this.died,
    required this.clockFrom,
    required this.clockTo,
    required this.healthBefore,
    required this.healthAfter,
    required this.notifications,
  });

  /// Events to commit, in order. First is always TurnCommitted (whose cause
  /// carries the full debug report).
  final List<Event> events;
  final TurnDebugReport report;
  final bool died;
  final int clockFrom;
  final int clockTo;
  final double healthBefore;
  final double healthAfter;

  /// Mechanical notification chips for the UI (§3.6): "−12 HP",
  /// "Acquired: rusty key", "+45 min".
  final List<String> notifications;
}

class TurnEngine {
  const TurnEngine({this.config = const EngineConfig()});

  final EngineConfig config;

  TurnResult runTurn({
    required WorldProjection projection,
    required TurnInput input,
    required DateTime now,
    List<LlmToolExchange> toolExchanges = const [],
    List<ContextSectionReport> contextSections = const [],
    LlmUsage usage = const LlmUsage(),
    String? rawLlmJson,
  }) {
    final world = projection.world;
    if (world == null) {
      throw StateError('runTurn: projection has no world');
    }
    final actor = projection.characters[input.actorId];
    if (actor == null) {
      throw ArgumentError('runTurn: unknown actor ${input.actorId}');
    }
    if (!actor.alive) {
      throw StateError(
          'runTurn: ${actor.name} is dead; timeline is frozen (§4.3)');
    }
    final schema = world.schema;
    final deltas = input.output.proposedDeltas;

    final turnSeq = projection.lastSeq + 1;
    final seedTurn = seedForTurn(world.seed, turnSeq);
    final turnId = 'turn-$turnSeq';

    // ---- Observation: a non-consequential look. No deltas, no clock, no
    // death — only the narrative and any surfaced wiki candidates. ----
    if (input.observationOnly) {
      return _observationTurn(
        world: world,
        actor: actor,
        input: input,
        turnSeq: turnSeq,
        turnId: turnId,
        now: now,
        toolExchanges: toolExchanges,
        contextSections: contextSections,
        usage: usage,
        rawLlmJson: rawLlmJson,
      );
    }

    final decisions = <DeltaDecision>[];
    final notes = <String>[];
    final notifications = <String>[];
    // Delta events (seq assigned after TurnCommitted at the end).
    final deltaEvents = <_PendingEvent>[];

    // Prose fallback (§14): the model ignored the JSON contract. The parser
    // already emptied the deltas; we just log it and flag the UI so it is
    // visible and monitorable.
    if (input.output.narratedInProse) {
      notes.add('prose fallback: model replied in prose instead of JSON; '
          'committed as non-consequential (no state changes). Monitored (§14).');
      notifications.add('Narration only (no state change)');
    }

    // Working copies of actor state, updated as proposals are accepted so
    // later validations see earlier effects.
    final stats = Map<String, double>.of(actor.stats);
    var statusList = List<StatusInstance>.of(actor.status);
    var inventory = List<ItemInstance>.of(actor.inventory);
    var quests = List<Quest>.of(actor.quests);

    final healthBefore = healthOf(actor, schema, config);

    // ---- Clock (validated first so status since_clock and decay use the
    // post-advance time; spec order applies its *effects* at step 4.4). ----
    final clockFrom = actor.subjectiveClock;
    final proposedAdvance = deltas.clockAdvanceMinutes;
    int acceptedAdvance;
    if (proposedAdvance < 0) {
      acceptedAdvance = 0;
      decisions.add(DeltaDecision(
        section: 'clock',
        proposal: {'clock_advance_minutes': proposedAdvance},
        outcome: DeltaOutcome.clamped,
        from: proposedAdvance,
        to: 0,
        reason: 'clock cannot move backwards',
      ));
    } else if (!input.allowUncappedClock &&
        proposedAdvance > config.perTurnCapMinutes) {
      acceptedAdvance = config.perTurnCapMinutes;
      decisions.add(DeltaDecision(
        section: 'clock',
        proposal: {'clock_advance_minutes': proposedAdvance},
        outcome: DeltaOutcome.clamped,
        from: proposedAdvance,
        to: acceptedAdvance,
        reason: 'exceeds PER_TURN_CAP (${config.perTurnCapMinutes} min)',
      ));
    } else {
      acceptedAdvance = proposedAdvance;
      decisions.add(DeltaDecision(
        section: 'clock',
        proposal: {'clock_advance_minutes': proposedAdvance},
        outcome: DeltaOutcome.accepted,
        from: proposedAdvance,
        to: acceptedAdvance,
      ));
    }
    final clockTo = clockFrom + acceptedAdvance;
    if (acceptedAdvance > 0) notifications.add('+$acceptedAdvance min');

    // Track statuses harmed/added this turn: drives peril gating and
    // instant-death triggers (§4.3).
    var perilDeltaApplied = false;
    final statusesTouchedThisTurn = <String>{};

    int grantCounter = 0;

    void emitStatChange(String key, double from, double to, String reason,
        {String source = 'llm'}) {
      if (from == to) return;
      deltaEvents.add(_PendingEvent(EventType.statChanged, {
        'char_id': actor.id,
        'key': key,
        'from': from,
        'to': to,
        'reason': reason,
        'source': source,
      }));
      final diff = to - from;
      notifications.add(
          '${diff >= 0 ? '+' : '−'}${_trim(diff.abs())} ${key.toUpperCase()}');
    }

    void applyStatDelta(String key, double delta, String reason,
        {String source = 'engine'}) {
      final def = schema.statDef(key);
      if (def == null) return;
      final from = stats[key] ?? def.defaultValue;
      final to = (from + delta).clamp(def.min, def.max);
      stats[key] = to;
      emitStatChange(key, from, to, reason, source: source);
    }

    void addStatus(String key, double severity, String reason,
        {String source = 'engine'}) {
      statusList = [
        for (final s in statusList)
          if (s.key != key) s
      ];
      statusList.add(
          StatusInstance(key: key, severity: severity, sinceClock: clockTo));
      statusesTouchedThisTurn.add(key);
      final def = schema.statusDef(key);
      if (def != null && def.weight > 0) perilDeltaApplied = true;
      deltaEvents.add(_PendingEvent(EventType.statusChanged, {
        'char_id': actor.id,
        'op': 'add',
        'key': key,
        'severity': severity,
        'since_clock': clockTo,
        'reason': reason,
        'source': source,
      }));
      notifications.add('Status: ${def?.label ?? key}'
          '${def != null && def.severityScale ? ' (${_trim(severity)})' : ''}');
    }

    void removeStatus(String key, String reason, {String source = 'engine'}) {
      statusList = [
        for (final s in statusList)
          if (s.key != key) s
      ];
      deltaEvents.add(_PendingEvent(EventType.statusChanged, {
        'char_id': actor.id,
        'op': 'remove',
        'key': key,
        'reason': reason,
        'source': source,
      }));
      final def = schema.statusDef(key);
      notifications.add('Status cleared: ${def?.label ?? key}');
    }

    ItemDef? resolveItem(String ref) {
      final direct = projection.itemDefs[ref];
      if (direct != null) return direct;
      final lower = ref.toLowerCase();
      for (final def in projection.itemDefs.values) {
        if (def.name.toLowerCase() == lower) return def;
      }
      return null;
    }

    int heldQty(String defId) =>
        inventory.where((i) => i.defId == defId).fold(0, (s, i) => s + i.qty);

    void grantItem(ItemDef def, int qty, String reason,
        {String source = 'engine'}) {
      final uid = 't$turnSeq-g${grantCounter++}';
      final instance = ItemInstance(defId: def.id, qty: qty, uid: uid);
      inventory = [...inventory, instance];
      deltaEvents.add(_PendingEvent(EventType.itemGranted, {
        'char_id': actor.id,
        'instance': instance.toJson(),
        'reason': reason,
        'source': source,
      }));
      notifications.add('Acquired: ${def.name}${qty > 1 ? ' ×$qty' : ''}');
    }

    /// Removes [qty] of [defId] across instances. Caller must have checked
    /// possession.
    void removeItemQty(String defId, int qty, String reason,
        {String source = 'engine', bool notify = true}) {
      var remaining = qty;
      final next = <ItemInstance>[];
      for (final inst in inventory) {
        if (inst.defId != defId || remaining == 0) {
          next.add(inst);
          continue;
        }
        final take = remaining < inst.qty ? remaining : inst.qty;
        final resulting = inst.qty - take;
        remaining -= take;
        deltaEvents.add(_PendingEvent(EventType.itemRemoved, {
          'char_id': actor.id,
          'uid': inst.uid,
          'removed_qty': take,
          'resulting_qty': resulting,
          'reason': reason,
          'source': source,
        }));
        if (resulting > 0) next.add(inst.copyWith(qty: resulting));
      }
      inventory = next;
      if (notify) {
        final def = projection.itemDefs[defId];
        notifications
            .add('Lost: ${def?.name ?? defId}${qty > 1 ? ' ×$qty' : ''}');
      }
    }

    // ---- 1. Inventory legality (§4.1) ----
    for (final op in deltas.inventory) {
      final def = resolveItem(op.item);
      if (def == null) {
        decisions.add(DeltaDecision(
          section: 'inventory',
          proposal: op.toJson(),
          outcome: DeltaOutcome.rejected,
          reason: 'no such item definition: "${op.item}"',
        ));
        continue;
      }
      if (op.qty < 1) {
        decisions.add(DeltaDecision(
          section: 'inventory',
          proposal: op.toJson(),
          outcome: DeltaOutcome.rejected,
          reason: 'qty must be >= 1',
        ));
        continue;
      }
      switch (op.op) {
        case InventoryOpKind.grant:
          grantItem(def, op.qty, op.reason, source: 'llm');
          decisions.add(DeltaDecision(
            section: 'inventory',
            proposal: op.toJson(),
            outcome: DeltaOutcome.accepted,
          ));
        case InventoryOpKind.remove:
          if (heldQty(def.id) < op.qty) {
            decisions.add(DeltaDecision(
              section: 'inventory',
              proposal: op.toJson(),
              outcome: DeltaOutcome.rejected,
              reason:
                  'not held: have ${heldQty(def.id)} of ${def.name}, tried to remove ${op.qty}',
            ));
            continue;
          }
          removeItemQty(def.id, op.qty, op.reason, source: 'llm');
          decisions.add(DeltaDecision(
            section: 'inventory',
            proposal: op.toJson(),
            outcome: DeltaOutcome.accepted,
          ));
        case InventoryOpKind.use:
          if (heldQty(def.id) < op.qty) {
            decisions.add(DeltaDecision(
              section: 'inventory',
              proposal: op.toJson(),
              outcome: DeltaOutcome.rejected,
              reason: 'cannot use ${def.name}: not held',
            ));
            continue;
          }
          // Apply effects per use (§4.1).
          for (var n = 0; n < op.qty; n++) {
            for (final effect in def.effects) {
              if (effect.statKey != null && effect.statDelta != null) {
                applyStatDelta(effect.statKey!, effect.statDelta!,
                    'effect of using ${def.name} (${effect.onUse})');
              }
              if (effect.statusKey != null) {
                if (effect.statusOp == 'remove') {
                  if (statusList.any((s) => s.key == effect.statusKey)) {
                    removeStatus(effect.statusKey!,
                        'effect of using ${def.name} (${effect.onUse})');
                  }
                } else {
                  addStatus(effect.statusKey!, effect.statusSeverity ?? 1,
                      'effect of using ${def.name} (${effect.onUse})');
                }
              }
            }
          }
          if (def.consumable) {
            removeItemQty(def.id, op.qty, 'consumed on use', notify: false);
            notifications
                .add('Used: ${def.name}${op.qty > 1 ? ' ×${op.qty}' : ''}');
          } else {
            notifications.add('Used: ${def.name}');
          }
          decisions.add(DeltaDecision(
            section: 'inventory',
            proposal: op.toJson(),
            outcome: DeltaOutcome.accepted,
          ));
      }
    }

    // ---- 2. Stats (§3.4) ----
    for (final op in deltas.stats) {
      final def = schema.statDef(op.key);
      if (def == null) {
        decisions.add(DeltaDecision(
          section: 'stats',
          proposal: op.toJson(),
          outcome: DeltaOutcome.rejected,
          reason: 'no such stat in world schema: "${op.key}"',
        ));
        continue;
      }
      final from = stats[op.key] ?? def.defaultValue;
      final target = op.op == StatOpKind.delta ? from + op.value : op.value;
      final clamped = target.clamp(def.min, def.max);
      stats[op.key] = clamped;
      decisions.add(DeltaDecision(
        section: 'stats',
        proposal: op.toJson(),
        outcome:
            clamped == target ? DeltaOutcome.accepted : DeltaOutcome.clamped,
        from: target,
        to: clamped,
        reason: clamped == target ? '' : 'clamped to [${def.min}, ${def.max}]',
      ));
      emitStatChange(op.key, from, clamped, op.reason);
    }

    // ---- 2b. Statuses ----
    for (final op in deltas.status) {
      final def = schema.statusDef(op.key);
      if (def == null) {
        decisions.add(DeltaDecision(
          section: 'status',
          proposal: op.toJson(),
          outcome: DeltaOutcome.rejected,
          reason: 'no such status in world schema: "${op.key}"',
        ));
        continue;
      }
      switch (op.op) {
        case StatusOpKind.add:
          addStatus(op.key, op.severity ?? 1.0, op.reason, source: 'llm');
          decisions.add(DeltaDecision(
            section: 'status',
            proposal: op.toJson(),
            outcome: DeltaOutcome.accepted,
          ));
        case StatusOpKind.remove:
          if (!statusList.any((s) => s.key == op.key)) {
            decisions.add(DeltaDecision(
              section: 'status',
              proposal: op.toJson(),
              outcome: DeltaOutcome.rejected,
              reason: 'status "${op.key}" not present',
            ));
            continue;
          }
          removeStatus(op.key, op.reason, source: 'llm');
          decisions.add(DeltaDecision(
            section: 'status',
            proposal: op.toJson(),
            outcome: DeltaOutcome.accepted,
          ));
      }
    }

    // ---- 3+4. Health recompute at the advanced clock (decay applied
    // lazily via since_clock, §4.2). ----
    final candidate = actor.copyWith(
      subjectiveClock: clockTo,
      stats: stats,
      status: statusList,
      inventory: inventory,
    );
    final healthAfter = healthOf(candidate, schema, config, atClock: clockTo);
    final hpDiff = healthAfter - healthBefore;
    if (hpDiff.abs() >= 0.5) {
      notifications.add('${hpDiff >= 0 ? '+' : '−'}${_trim(hpDiff.abs())} HP');
    }

    // Expire statuses fully decayed by the advance, so the sheet stays clean.
    for (final s in List.of(statusList)) {
      final def = schema.statusDef(s.key);
      if (statusExpired(s, def, clockTo) &&
          !statusesTouchedThisTurn.contains(s.key)) {
        removeStatus(s.key, 'decayed to zero');
      }
    }

    // ---- 5. Death eval (§4.3) ----
    String? instantTrigger;
    for (final s in statusList) {
      final def = schema.statusDef(s.key);
      final lethal = def?.lethalSeverity;
      if (lethal == null) continue;
      if (!statusesTouchedThisTurn.contains(s.key)) continue;
      if (effectiveSeverity(s, def, clockTo) >= lethal) {
        instantTrigger = 'lethal ${s.key} stack '
            '(severity ${_trim(effectiveSeverity(s, def, clockTo))} >= $lethal)';
        break;
      }
    }
    if (input.nonLethal && instantTrigger != null) {
      notes.add('non-lethal context: instant trigger "$instantTrigger" '
          'suppressed; status remains to play out (§4.6)');
    }

    final deathEval = evaluateDeath(
      health: healthAfter,
      perilDeltaApplied: perilDeltaApplied,
      perilHint: input.output.peril,
      seedTurn: seedTurn,
      config: config,
      instantTrigger: input.nonLethal ? null : instantTrigger,
      nonLethal: input.nonLethal,
    );

    // ---- 6. Quest checks ----
    for (final op in deltas.quest) {
      final quest = candidateQuest(quests, op.questId);
      if (quest == null) {
        decisions.add(DeltaDecision(
          section: 'quest',
          proposal: op.toJson(),
          outcome: DeltaOutcome.rejected,
          reason: 'no such quest on actor: "${op.questId}"',
        ));
        continue;
      }
      if (quest.state != QuestState.active) {
        decisions.add(DeltaDecision(
          section: 'quest',
          proposal: op.toJson(),
          outcome: DeltaOutcome.rejected,
          reason: 'quest "${quest.title}" is ${quest.state.name}, not active',
        ));
        continue;
      }
      switch (op.op) {
        case QuestOpKind.progress:
          final step = quest.steps.where((s) => s.id == op.stepId).firstOrNull;
          if (step == null) {
            decisions.add(DeltaDecision(
              section: 'quest',
              proposal: op.toJson(),
              outcome: DeltaOutcome.rejected,
              reason: 'no such step "${op.stepId}" on quest "${quest.title}"',
            ));
            continue;
          }
          if (step.done) {
            decisions.add(DeltaDecision(
              section: 'quest',
              proposal: op.toJson(),
              outcome: DeltaOutcome.rejected,
              reason: 'step "${op.stepId}" already done',
            ));
            continue;
          }
          final updatedSteps = [
            for (final s in quest.steps)
              s.id == step.id ? s.copyWith(done: true) : s
          ];
          final nowComplete = updatedSteps.every((s) => s.done);
          final updated = quest.copyWith(
            steps: updatedSteps,
            state: nowComplete ? QuestState.complete : QuestState.active,
          );
          quests = [for (final q in quests) q.id == quest.id ? updated : q];
          deltaEvents.add(_PendingEvent(EventType.questProgressed, {
            'char_id': actor.id,
            'quest_id': quest.id,
            'op': 'progress',
            'step_id': step.id,
            'steps_done': [step.id],
            'resulting_state': updated.state.name,
            'reason': op.reason,
          }));
          notifications.add(nowComplete
              ? 'Quest complete: ${quest.title}'
              : 'Quest progress: ${quest.title} — ${step.desc}');
          decisions.add(DeltaDecision(
            section: 'quest',
            proposal: op.toJson(),
            outcome: DeltaOutcome.accepted,
            reason: nowComplete ? 'final step; quest auto-completed' : '',
          ));
          if (nowComplete) {
            _grantQuestRewards(
                updated, projection, schema, grantItem, applyStatDelta, notes);
          }
        case QuestOpKind.complete:
          if (!quest.allStepsDone) {
            decisions.add(DeltaDecision(
              section: 'quest',
              proposal: op.toJson(),
              outcome: DeltaOutcome.rejected,
              reason: 'cannot complete "${quest.title}": steps remain undone',
            ));
            continue;
          }
          final updated = quest.copyWith(state: QuestState.complete);
          quests = [for (final q in quests) q.id == quest.id ? updated : q];
          deltaEvents.add(_PendingEvent(EventType.questProgressed, {
            'char_id': actor.id,
            'quest_id': quest.id,
            'op': 'complete',
            'steps_done': const <String>[],
            'resulting_state': 'complete',
            'reason': op.reason,
          }));
          notifications.add('Quest complete: ${quest.title}');
          decisions.add(DeltaDecision(
            section: 'quest',
            proposal: op.toJson(),
            outcome: DeltaOutcome.accepted,
          ));
          _grantQuestRewards(
              updated, projection, schema, grantItem, applyStatDelta, notes);
        case QuestOpKind.fail:
          final updated = quest.copyWith(state: QuestState.failed);
          quests = [for (final q in quests) q.id == quest.id ? updated : q];
          deltaEvents.add(_PendingEvent(EventType.questProgressed, {
            'char_id': actor.id,
            'quest_id': quest.id,
            'op': 'fail',
            'steps_done': const <String>[],
            'resulting_state': 'failed',
            'reason': op.reason,
          }));
          notifications.add('Quest failed: ${quest.title}');
          decisions.add(DeltaDecision(
            section: 'quest',
            proposal: op.toJson(),
            outcome: DeltaOutcome.accepted,
          ));
      }
    }

    // ---- 7. Relationships (§4.5) ----
    for (final op in deltas.relationships) {
      if (!schema.relationshipDims.contains(op.dim)) {
        decisions.add(DeltaDecision(
          section: 'relationships',
          proposal: op.toJson(),
          outcome: DeltaOutcome.rejected,
          reason: 'no such relationship dim in schema: "${op.dim}"',
        ));
        continue;
      }
      final target = projection.characters[op.to];
      if (target == null) {
        decisions.add(DeltaDecision(
          section: 'relationships',
          proposal: op.toJson(),
          outcome: DeltaOutcome.rejected,
          reason: 'no such character: "${op.to}"',
        ));
        continue;
      }
      final current = projection.edge(actor.id, op.to)?.dims[op.dim] ?? 0.0;
      final desired = current + op.delta;
      final clamped =
          desired.clamp(schema.relationshipDimMin, schema.relationshipDimMax);
      decisions.add(DeltaDecision(
        section: 'relationships',
        proposal: op.toJson(),
        outcome:
            clamped == desired ? DeltaOutcome.accepted : DeltaOutcome.clamped,
        from: desired,
        to: clamped,
        reason: clamped == desired
            ? ''
            : 'clamped to [${schema.relationshipDimMin}, ${schema.relationshipDimMax}]',
      ));
      if (clamped != current) {
        deltaEvents.add(_PendingEvent(EventType.relationshipChanged, {
          'from_char': actor.id,
          'to_char': op.to,
          'dim': op.dim,
          'from': current,
          'to': clamped,
          'note': op.reason,
        }));
        final diff = clamped - current;
        notifications.add(
            '${target.name}: ${diff >= 0 ? '+' : '−'}${_trim(diff.abs())} ${op.dim}');
      }
    }

    // ---- Wiki candidates -> review queue (§5.2) ----
    var candIdx = 0;
    for (final cand in input.output.wikiCandidates) {
      final id = cand.id.isEmpty ? 'cand-$turnSeq-${candIdx++}' : cand.id;
      deltaEvents.add(_PendingEvent(EventType.wikiCandidateQueued, {
        'candidate': WikiCandidate(
          id: id,
          title: cand.title,
          category: cand.category,
          body: cand.body,
          tags: cand.tags,
          clockRef: cand.clockRef,
          sourceTurnSeq: turnSeq,
        ).toJson(),
      }));
    }

    final report = TurnDebugReport(
      rawLlmJson: rawLlmJson,
      decisions: decisions,
      toolExchanges: toolExchanges,
      deathEval: deathEval,
      contextSections: contextSections,
      usage: usage,
      notes: notes,
    );

    // ---- Assemble committed events. TurnCommitted leads and carries the
    // debug report in its cause (§9). ----
    final events = <Event>[];
    var seq = turnSeq;
    events.add(Event(
      id: 'evt-$seq',
      worldId: world.id,
      seq: seq++,
      timeline: actor.id,
      subjectiveClock: clockTo,
      type: EventType.turnCommitted,
      payload: {
        'turn_id': turnId,
        'actor_id': actor.id,
        'narrative': input.output.narrative,
        'user_input': input.userInput,
        'clock_from': clockFrom,
        'clock_to': clockTo,
        'peril_hint': input.output.peril,
        'prose_fallback': input.output.narratedInProse,
        'observation': false,
      },
      cause: {
        'turn_id': turnId,
        'user_input_ref': input.userInput,
        'llm_raw_ref': rawLlmJson,
        'debug_report': report.toJson(),
      },
      createdAt: now,
    ));
    for (final pending in deltaEvents) {
      events.add(Event(
        id: 'evt-$seq',
        worldId: world.id,
        seq: seq++,
        timeline: actor.id,
        subjectiveClock: clockTo,
        type: pending.type,
        payload: pending.payload,
        cause: {'turn_id': turnId},
        createdAt: now,
      ));
    }
    if (deathEval.outcome) {
      events.add(Event(
        id: 'evt-$seq',
        worldId: world.id,
        seq: seq++,
        timeline: actor.id,
        subjectiveClock: clockTo,
        type: EventType.characterDied,
        payload: {
          'char_id': actor.id,
          'at_clock': clockTo,
          'death_eval': deathEval.toJson(),
        },
        cause: {'turn_id': turnId},
        createdAt: now,
      ));
      notifications.add('${actor.name} has died.');
    }

    return TurnResult(
      events: events,
      report: report,
      died: deathEval.outcome,
      clockFrom: clockFrom,
      clockTo: clockTo,
      healthBefore: healthBefore,
      healthAfter: healthAfter,
      notifications: notifications,
    );
  }

  /// Build a non-consequential observation turn: only a TurnCommitted (marked
  /// `observation: true`, clock unchanged) plus any queued wiki candidates.
  TurnResult _observationTurn({
    required dynamic world,
    required Character actor,
    required TurnInput input,
    required int turnSeq,
    required String turnId,
    required DateTime now,
    required List<LlmToolExchange> toolExchanges,
    required List<ContextSectionReport> contextSections,
    required LlmUsage usage,
    String? rawLlmJson,
  }) {
    final report = TurnDebugReport(
      rawLlmJson: rawLlmJson,
      decisions: const [],
      toolExchanges: toolExchanges,
      deathEval: null,
      contextSections: contextSections,
      usage: usage,
      notes: const [
        'observation: no deltas applied, clock unchanged, no death roll '
            '(§ observe)'
      ],
    );

    final clock = actor.subjectiveClock;
    final events = <Event>[];
    var seq = turnSeq;
    events.add(Event(
      id: 'evt-$seq',
      worldId: world.id as String,
      seq: seq++,
      timeline: actor.id,
      subjectiveClock: clock,
      type: EventType.turnCommitted,
      payload: {
        'turn_id': turnId,
        'actor_id': actor.id,
        'narrative': input.output.narrative,
        'user_input': input.userInput,
        'clock_from': clock,
        'clock_to': clock,
        'peril_hint': false,
        'prose_fallback': input.output.narratedInProse,
        'observation': true,
      },
      cause: {
        'turn_id': turnId,
        'user_input_ref': input.userInput,
        'llm_raw_ref': rawLlmJson,
        'debug_report': report.toJson(),
      },
      createdAt: now,
    ));
    var candIdx = 0;
    for (final cand in input.output.wikiCandidates) {
      final id = cand.id.isEmpty ? 'cand-$turnSeq-${candIdx++}' : cand.id;
      events.add(Event(
        id: 'evt-$seq',
        worldId: world.id as String,
        seq: seq++,
        timeline: actor.id,
        subjectiveClock: clock,
        type: EventType.wikiCandidateQueued,
        payload: {
          'candidate': WikiCandidate(
            id: id,
            title: cand.title,
            category: cand.category,
            body: cand.body,
            tags: cand.tags,
            clockRef: cand.clockRef,
            sourceTurnSeq: turnSeq,
          ).toJson(),
        },
        cause: {'turn_id': turnId},
        createdAt: now,
      ));
    }

    return TurnResult(
      events: events,
      report: report,
      died: false,
      clockFrom: clock,
      clockTo: clock,
      healthBefore: 0,
      healthAfter: 0,
      notifications: const ['Observation'],
    );
  }

  static Quest? candidateQuest(List<Quest> quests, String id) {
    for (final q in quests) {
      if (q.id == id) return q;
    }
    return null;
  }

  void _grantQuestRewards(
    Quest quest,
    WorldProjection projection,
    WorldSchema schema,
    void Function(ItemDef def, int qty, String reason) grantItem,
    void Function(String key, double delta, String reason) applyStatDelta,
    List<String> notes,
  ) {
    for (final defId in quest.reward.itemDefIds) {
      final def = projection.itemDefs[defId];
      if (def == null) {
        notes.add('quest "${quest.title}" reward item "$defId" has no '
            'definition; skipped');
        continue;
      }
      grantItem(def, 1, 'reward: ${quest.title}');
    }
    for (final rs in quest.reward.stats) {
      applyStatDelta(rs.key, rs.delta, 'reward: ${quest.title}');
    }
  }
}

class _PendingEvent {
  const _PendingEvent(this.type, this.payload);

  final EventType type;
  final Map<String, Object?> payload;
}

String _trim(double v) {
  if (v == v.roundToDouble()) return v.round().toString();
  return v.toStringAsFixed(1);
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
