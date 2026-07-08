/// Projections (§1.2): character sheets, wiki, relationship graph, clock —
/// all rebuildable folds over the append-only event log.
///
/// `applyEvent` is idempotent: payloads carry resolved absolute values
/// (from -> to), so applying the same event twice cannot double-apply and
/// replay is safe (§0).
library;

import 'dart:math' as math;

import '../model/character.dart';
import '../model/event.dart';
import '../model/item.dart';
import '../model/quest.dart';
import '../model/relationship.dart';
import '../model/wiki.dart';
import '../model/world.dart';

/// One committed turn's narrative record, kept for context assembly (§6).
class TurnRecord {
  const TurnRecord({
    required this.seq,
    required this.timeline,
    required this.userInput,
    required this.narrative,
    required this.clockAfter,
    this.observation = false,
  });

  final int seq;
  final String timeline;
  final String userInput;
  final String narrative;
  final int clockAfter;

  /// A non-consequential observation (§ observe): kept in history for context
  /// and display, but advanced no clock and committed no deltas.
  final bool observation;

  Map<String, Object?> toJson() => {
        'seq': seq,
        'timeline': timeline,
        'user_input': userInput,
        'narrative': narrative,
        'clock_after': clockAfter,
        'observation': observation,
      };
}

/// A shared-canon record between characters (§4.4). Immutable first-writer-
/// wins canon: when a later-played participant reaches this timestamp it is
/// injected as fixed, non-negotiable context.
class SharedEventRecord {
  const SharedEventRecord({
    required this.seq,
    required this.participants,
    required this.atClock,
    required this.summary,
    this.detail = '',
  });

  final int seq;
  final List<String> participants;

  /// Subjective time of the first writer at commit.
  final int atClock;
  final String summary;
  final String detail;

  Map<String, Object?> toJson() => {
        'seq': seq,
        'participants': participants,
        'at_clock': atClock,
        'summary': summary,
        'detail': detail,
      };
}

class RollingSummary {
  const RollingSummary({required this.uptoSeq, required this.summary});

  final int uptoSeq;
  final String summary;

  Map<String, Object?> toJson() => {'upto_seq': uptoSeq, 'summary': summary};
}

String edgeKey(String from, String to) => '$from|$to';

/// Materialized world state. Build with [WorldProjection.replay].
class WorldProjection {
  WorldProjection();

  World? world;
  final Map<String, Character> characters = {};
  final Map<String, ItemDef> itemDefs = {};
  final Map<String, WikiEntry> wiki = {};
  final Map<String, RelationshipEdge> edges = {};
  final Map<String, WikiCandidate> pendingCandidates = {};
  final Map<String, RollingSummary> summaries = {};
  final List<TurnRecord> turnHistory = [];
  final List<SharedEventRecord> sharedEvents = [];

  /// Monitoring (§14): count of committed gameplay turns and how many of them
  /// were non-consequential prose fallbacks (model ignored the JSON contract).
  int turnCount = 0;
  int proseFallbackTurns = 0;

  /// Highest seq applied.
  int lastSeq = -1;

  /// World clock display = max subjective clock across living characters
  /// (§1.2). 0 when no living characters exist.
  int get worldClock {
    var maxClock = 0;
    for (final c in characters.values) {
      if (c.alive) maxClock = math.max(maxClock, c.subjectiveClock);
    }
    return maxClock;
  }

  /// Id of the wiki entry the user designated as the world overview, if any.
  String? get worldBioEntryId =>
      world?.settings['world_bio_entry_id'] as String?;

  /// A compact "basic bio of the world" for character/scenario generation.
  /// Prefers the user-designated overview entry's body; otherwise falls back
  /// to the compact index of all entries. Empty when the wiki is empty.
  String worldBioText() {
    final designated = worldBioEntryId;
    if (designated != null && wiki[designated] != null) {
      final e = wiki[designated]!;
      return '${e.title}\n${e.body}';
    }
    if (wiki.isEmpty) return '';
    final lines = wiki.values.map((w) => '- ${w.summaryLine}').toList()..sort();
    return lines.join('\n');
  }

  List<TurnRecord> turnsFor(String timeline) => [
        for (final t in turnHistory)
          if (t.timeline == timeline) t
      ];

  /// Shared events involving [characterId], ordered by canon time.
  List<SharedEventRecord> sharedEventsFor(String characterId) {
    final list = [
      for (final s in sharedEvents)
        if (s.participants.contains(characterId)) s
    ];
    list.sort((a, b) => a.atClock.compareTo(b.atClock));
    return list;
  }

  RelationshipEdge? edge(String from, String to) => edges[edgeKey(from, to)];

  /// Rebuild from an event log. [upToSeq] rebuilds history only through that
  /// seq (undo); [revertedSeqs] skips soft-reverted events (undo/redo, §1.1).
  static WorldProjection replay(
    Iterable<Event> events, {
    int? upToSeq,
    Set<int> revertedSeqs = const {},
  }) {
    final p = WorldProjection();
    final sorted = events.toList()..sort((a, b) => a.seq.compareTo(b.seq));
    for (final e in sorted) {
      if (upToSeq != null && e.seq > upToSeq) break;
      if (revertedSeqs.contains(e.seq)) continue;
      p.applyEvent(e);
    }
    return p;
  }

  /// Fold one event into the projection. Idempotent by construction.
  void applyEvent(Event e) {
    switch (e.type) {
      case EventType.worldCreated:
        world = World.fromJson(
            e.payload['world'] as Map<String, Object?>? ?? e.payload);
      case EventType.worldConfigured:
        final w = world;
        if (w != null) {
          final merged = Map<String, Object?>.of(w.settings)
            ..addAll(
                e.payload['settings'] as Map<String, Object?>? ?? const {});
          world = w.copyWith(settings: merged);
        }
      case EventType.characterCreated:
        final c = Character.fromJson(
            e.payload['character'] as Map<String, Object?>? ?? e.payload);
        characters[c.id] = c;
      case EventType.itemDefCreated:
        final def = ItemDef.fromJson(
            e.payload['item_def'] as Map<String, Object?>? ?? e.payload);
        itemDefs[def.id] = def;
      case EventType.turnCommitted:
        _applyTurnCommitted(e);
      case EventType.statChanged:
        _applyStatChanged(e.payload);
      case EventType.statusChanged:
        _applyStatusChanged(e.payload);
      case EventType.itemGranted:
        _applyItemGranted(e.payload);
      case EventType.itemRemoved:
        _applyItemRemoved(e.payload);
      case EventType.relationshipChanged:
        _applyRelationshipChanged(e.payload);
      case EventType.questProgressed:
        _applyQuestProgressed(e.payload);
      case EventType.sharedEvent:
        _applySharedEvent(e);
      case EventType.timeSkip:
        _applyTimeSkip(e.payload);
      case EventType.characterDied:
        _applyCharacterDied(e.payload);
      case EventType.wikiCreated:
      case EventType.wikiUpdated:
        final entry = WikiEntry.fromJson(
            e.payload['entry'] as Map<String, Object?>? ?? e.payload);
        wiki[entry.id] = entry;
      case EventType.wikiCandidateQueued:
        final c = WikiCandidate.fromJson(
            e.payload['candidate'] as Map<String, Object?>? ?? e.payload);
        pendingCandidates[c.id] = c;
      case EventType.wikiCandidatePromoted:
        pendingCandidates.remove(e.payload['candidate_id'] as String?);
        final entryJson = e.payload['entry'] as Map<String, Object?>?;
        if (entryJson != null) {
          final entry = WikiEntry.fromJson(entryJson);
          wiki[entry.id] = entry;
        }
      case EventType.wikiCandidateRejected:
        pendingCandidates.remove(e.payload['candidate_id'] as String?);
      case EventType.summaryCached:
        summaries[e.payload['timeline'] as String] = RollingSummary(
          uptoSeq: e.payload['upto_seq'] as int,
          summary: e.payload['summary'] as String,
        );
    }
    lastSeq = math.max(lastSeq, e.seq);
  }

  void _applyTurnCommitted(Event e) {
    final actorId = e.payload['actor_id'] as String;
    final clockTo = e.payload['clock_to'] as int;
    final observation = e.payload['observation'] as bool? ?? false;
    final c = characters[actorId];
    if (c != null) {
      characters[actorId] = c.copyWith(subjectiveClock: clockTo);
    }
    // Idempotent history: replace any record with the same seq.
    final firstApply = !turnHistory.any((t) => t.seq == e.seq);
    turnHistory.removeWhere((t) => t.seq == e.seq);
    turnHistory.add(TurnRecord(
      seq: e.seq,
      timeline: actorId,
      userInput: e.payload['user_input'] as String? ?? '',
      narrative: e.payload['narrative'] as String? ?? '',
      clockAfter: clockTo,
      observation: observation,
    ));
    turnHistory.sort((a, b) => a.seq.compareTo(b.seq));
    // Monitoring counters (only consequential turns count; observations are
    // excluded). Guarded on first apply so replay idempotency holds.
    if (firstApply && !observation) {
      turnCount++;
      if (e.payload['prose_fallback'] as bool? ?? false) proseFallbackTurns++;
    }
  }

  void _applyStatChanged(Map<String, Object?> p) {
    final c = characters[p['char_id'] as String];
    if (c == null) return;
    final stats = Map<String, double>.of(c.stats);
    stats[p['key'] as String] = (p['to'] as num).toDouble();
    characters[c.id] = c.copyWith(stats: stats);
  }

  void _applyStatusChanged(Map<String, Object?> p) {
    final c = characters[p['char_id'] as String];
    if (c == null) return;
    final key = p['key'] as String;
    final op = p['op'] as String;
    final status = [
      for (final s in c.status)
        if (s.key != key) s
    ];
    if (op == 'add' || op == 'set') {
      status.add(StatusInstance(
        key: key,
        severity: (p['severity'] as num? ?? 1).toDouble(),
        sinceClock: p['since_clock'] as int? ?? c.subjectiveClock,
      ));
    }
    characters[c.id] = c.copyWith(status: status);
  }

  void _applyItemGranted(Map<String, Object?> p) {
    final c = characters[p['char_id'] as String];
    if (c == null) return;
    final instance =
        ItemInstance.fromJson(p['instance'] as Map<String, Object?>);
    // Idempotent: instance uid is unique per grant.
    final inventory = [
      for (final i in c.inventory)
        if (i.uid != instance.uid) i
    ];
    inventory.add(instance);
    characters[c.id] = c.copyWith(inventory: inventory);
  }

  void _applyItemRemoved(Map<String, Object?> p) {
    final c = characters[p['char_id'] as String];
    if (c == null) return;
    final uid = p['uid'] as String;
    final resultingQty = p['resulting_qty'] as int;
    final inventory = <ItemInstance>[];
    for (final i in c.inventory) {
      if (i.uid != uid) {
        inventory.add(i);
      } else if (resultingQty > 0) {
        inventory.add(i.copyWith(qty: resultingQty));
      }
    }
    characters[c.id] = c.copyWith(inventory: inventory);
  }

  void _applyRelationshipChanged(Map<String, Object?> p) {
    final from = p['from_char'] as String;
    final to = p['to_char'] as String;
    final key = edgeKey(from, to);
    final existing = edges[key] ??
        RelationshipEdge(worldId: world?.id ?? '', fromChar: from, toChar: to);
    final dims = Map<String, double>.of(existing.dims);
    dims[p['dim'] as String] = (p['to'] as num).toDouble();
    final notes = List<String>.of(existing.notes);
    final note = p['note'] as String?;
    if (note != null && note.isNotEmpty && !notes.contains(note)) {
      notes.add(note);
    }
    edges[key] = existing.copyWith(dims: dims, notes: notes);
  }

  void _applyQuestProgressed(Map<String, Object?> p) {
    final c = characters[p['char_id'] as String];
    if (c == null) return;
    final questId = p['quest_id'] as String;
    final stepsDone = {
      for (final s in p['steps_done'] as List<Object?>? ?? <Object?>[])
        s! as String
    };
    final resultingState = p['resulting_state'] as String?;
    final quests = <Quest>[];
    for (final q in c.quests) {
      if (q.id != questId) {
        quests.add(q);
        continue;
      }
      final steps = [
        for (final s in q.steps)
          stepsDone.contains(s.id) ? s.copyWith(done: true) : s
      ];
      quests.add(q.copyWith(
        steps: steps,
        state: resultingState == null
            ? q.state
            : QuestState.values.byName(resultingState),
      ));
    }
    characters[c.id] = c.copyWith(quests: quests);
  }

  void _applySharedEvent(Event e) {
    // Idempotent: seq identifies the record.
    sharedEvents.removeWhere((s) => s.seq == e.seq);
    sharedEvents.add(SharedEventRecord(
      seq: e.seq,
      participants: [
        for (final id in e.payload['participants'] as List<Object?>)
          id! as String
      ],
      atClock: e.payload['at_clock'] as int,
      summary: e.payload['summary'] as String? ?? '',
      detail: e.payload['detail'] as String? ?? '',
    ));
    sharedEvents.sort((a, b) => a.seq.compareTo(b.seq));
  }

  void _applyTimeSkip(Map<String, Object?> p) {
    // A TimeSkip holds its synthesized summary plus all applied deltas as
    // absolute records (§4.6) — apply each, then jump the clock.
    for (final d in p['deltas'] as List<Object?>? ?? <Object?>[]) {
      final delta = d! as Map<String, Object?>;
      switch (delta['kind'] as String) {
        case 'stat':
          _applyStatChanged(delta);
        case 'status':
          _applyStatusChanged(delta);
        case 'item_granted':
          _applyItemGranted(delta);
        case 'item_removed':
          _applyItemRemoved(delta);
        case 'relationship':
          _applyRelationshipChanged(delta);
        case 'quest':
          _applyQuestProgressed(delta);
      }
    }
    final charId = p['char_id'] as String;
    final c = characters[charId];
    if (c != null) {
      characters[charId] = c.copyWith(subjectiveClock: p['to_clock'] as int);
    }
  }

  void _applyCharacterDied(Map<String, Object?> p) {
    final c = characters[p['char_id'] as String];
    if (c == null) return;
    characters[c.id] = c.copyWith(alive: false);
  }

  /// Full JSON snapshot; used for equality in tests and the projection cache
  /// in saves (§8).
  Map<String, Object?> toJson() => {
        'world': world?.toJson(),
        'characters': {
          for (final e in characters.entries) e.key: e.value.toJson()
        },
        'item_defs': {
          for (final e in itemDefs.entries) e.key: e.value.toJson()
        },
        'wiki': {for (final e in wiki.entries) e.key: e.value.toJson()},
        'edges': {for (final e in edges.entries) e.key: e.value.toJson()},
        'pending_candidates': {
          for (final e in pendingCandidates.entries) e.key: e.value.toJson()
        },
        'summaries': {
          for (final e in summaries.entries) e.key: e.value.toJson()
        },
        'turn_history': [for (final t in turnHistory) t.toJson()],
        'shared_events': [for (final s in sharedEvents) s.toJson()],
        'last_seq': lastSeq,
        'world_clock': worldClock,
        'turn_count': turnCount,
        'prose_fallback_turns': proseFallbackTurns,
      };
}
