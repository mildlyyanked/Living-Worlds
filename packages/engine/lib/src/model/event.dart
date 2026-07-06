/// The append-only event log — the world's source of truth (§1.1).
///
/// Events are immutable. All projections (character sheets, wiki,
/// relationship graph, clock) are folds over this log. Payloads record
/// *resolved absolute values* (`from` -> `to`) rather than raw deltas so that
/// applying an event is idempotent and replay is safe.
library;

/// Special timeline id for events that belong to the world itself rather
/// than to a character's subjective stream.
const String worldTimeline = 'WORLD';

enum EventType {
  worldCreated,
  characterCreated,
  itemDefCreated,
  turnCommitted,
  wikiCreated,
  wikiUpdated,
  wikiCandidateQueued,
  wikiCandidatePromoted,
  wikiCandidateRejected,
  itemGranted,
  itemRemoved,
  statChanged,
  statusChanged,
  relationshipChanged,
  questProgressed,
  sharedEvent,
  timeSkip,
  characterDied,
  summaryCached,
}

class Event {
  const Event({
    required this.id,
    required this.worldId,
    required this.seq,
    required this.timeline,
    required this.subjectiveClock,
    required this.type,
    required this.payload,
    this.cause = const {},
    required this.createdAt,
  });

  final String id;
  final String worldId;

  /// Global monotonic per world; drives the seeded RNG
  /// (`seed_turn = hash(world.seed, seq)`).
  final int seq;

  /// Character id or [worldTimeline].
  final String timeline;

  /// The acting character's subjective time (minutes) at commit.
  final int subjectiveClock;
  final EventType type;
  final Map<String, Object?> payload;

  /// Traceability: {turn_id, llm_raw_ref, user_input_ref, debug_report}.
  final Map<String, Object?> cause;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
        'id': id,
        'world_id': worldId,
        'seq': seq,
        'timeline': timeline,
        'subjective_clock': subjectiveClock,
        'type': type.name,
        'payload': payload,
        'cause': cause,
        'created_at': createdAt.toIso8601String(),
      };

  factory Event.fromJson(Map<String, Object?> json) => Event(
        id: json['id'] as String,
        worldId: json['world_id'] as String,
        seq: json['seq'] as int,
        timeline: json['timeline'] as String,
        subjectiveClock: json['subjective_clock'] as int? ?? 0,
        type: EventType.values.byName(json['type'] as String),
        payload: (json['payload'] as Map<String, Object?>?) ?? const {},
        cause: (json['cause'] as Map<String, Object?>?) ?? const {},
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}
