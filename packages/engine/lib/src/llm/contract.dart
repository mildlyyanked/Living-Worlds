/// The LLM contract (§2). Every gameplay turn the model returns strict JSON:
/// narrative + proposed state deltas. Every field here is a *proposal* — the
/// deterministic engine accepts, clamps, or rejects each independently.
library;

import '../model/wiki.dart';

/// Tolerant enum lookup for parsing model output: real models occasionally
/// omit or misspell an `op`, and a hard `byName` throw would fail the whole
/// turn. We fall back to a value whose failure mode is a clean *rejection*
/// (never an unintended mutation), because the paired identity field
/// (item/key/quest_id) also defaults to '' and the engine rejects empties.
T _enumOr<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

String _str(Object? v) => v is String ? v : '';
double _dbl(Object? v) => v is num ? v.toDouble() : 0.0;

enum InventoryOpKind { grant, remove, use }

class InventoryOp {
  const InventoryOp({
    required this.op,
    required this.item,
    this.qty = 1,
    this.reason = '',
  });

  final InventoryOpKind op;

  /// Item name or def id as spoken by the model; resolved by the engine.
  final String item;
  final int qty;
  final String reason;

  Map<String, Object?> toJson() =>
      {'op': op.name, 'item': item, 'qty': qty, 'reason': reason};

  factory InventoryOp.fromJson(Map<String, Object?> json) => InventoryOp(
        // 'use' of an empty/unheld item is safely rejected by the engine.
        op: _enumOr(InventoryOpKind.values, json['op'], InventoryOpKind.use),
        item: _str(json['item']),
        qty: (json['qty'] as num?)?.round() ?? 1,
        reason: _str(json['reason']),
      );
}

enum StatOpKind { delta, set }

class StatOp {
  const StatOp({
    required this.key,
    required this.op,
    required this.value,
    this.reason = '',
  });

  final String key;
  final StatOpKind op;
  final double value;
  final String reason;

  Map<String, Object?> toJson() =>
      {'key': key, 'op': op.name, 'value': value, 'reason': reason};

  factory StatOp.fromJson(Map<String, Object?> json) => StatOp(
        key: _str(json['key']),
        // 'delta' of 0 on an empty key is a rejected no-op.
        op: _enumOr(StatOpKind.values, json['op'], StatOpKind.delta),
        value: _dbl(json['value']),
        reason: _str(json['reason']),
      );
}

enum StatusOpKind { add, remove }

class StatusOp {
  const StatusOp({
    required this.op,
    required this.key,
    this.severity,
    this.reason = '',
  });

  final StatusOpKind op;
  final String key;
  final double? severity;
  final String reason;

  Map<String, Object?> toJson() =>
      {'op': op.name, 'key': key, 'severity': severity, 'reason': reason};

  factory StatusOp.fromJson(Map<String, Object?> json) => StatusOp(
        // 'remove' of an empty/absent key is safely rejected.
        op: _enumOr(StatusOpKind.values, json['op'], StatusOpKind.remove),
        key: _str(json['key']),
        severity: (json['severity'] as num?)?.toDouble(),
        reason: _str(json['reason']),
      );
}

class RelationshipOp {
  const RelationshipOp({
    required this.to,
    required this.dim,
    required this.delta,
    this.reason = '',
  });

  /// Target character id; edge is actor -> to.
  final String to;
  final String dim;
  final double delta;
  final String reason;

  Map<String, Object?> toJson() =>
      {'to': to, 'dim': dim, 'delta': delta, 'reason': reason};

  factory RelationshipOp.fromJson(Map<String, Object?> json) => RelationshipOp(
        to: _str(json['to']),
        dim: _str(json['dim']),
        delta: _dbl(json['delta']),
        reason: _str(json['reason']),
      );
}

enum QuestOpKind { progress, complete, fail }

class QuestOp {
  const QuestOp({
    required this.questId,
    required this.op,
    this.stepId,
    this.reason = '',
  });

  final String questId;
  final QuestOpKind op;
  final String? stepId;
  final String reason;

  Map<String, Object?> toJson() =>
      {'quest_id': questId, 'op': op.name, 'step_id': stepId, 'reason': reason};

  factory QuestOp.fromJson(Map<String, Object?> json) => QuestOp(
        questId: _str(json['quest_id']),
        // 'progress' on an empty quest/step is safely rejected.
        op: _enumOr(QuestOpKind.values, json['op'], QuestOpKind.progress),
        stepId: json['step_id'] as String?,
        reason: _str(json['reason']),
      );
}

class ProposedDeltas {
  const ProposedDeltas({
    this.clockAdvanceMinutes = 0,
    this.inventory = const [],
    this.stats = const [],
    this.status = const [],
    this.relationships = const [],
    this.quest = const [],
  });

  final int clockAdvanceMinutes;
  final List<InventoryOp> inventory;
  final List<StatOp> stats;
  final List<StatusOp> status;
  final List<RelationshipOp> relationships;
  final List<QuestOp> quest;

  Map<String, Object?> toJson() => {
        'clock_advance_minutes': clockAdvanceMinutes,
        'inventory': [for (final o in inventory) o.toJson()],
        'stats': [for (final o in stats) o.toJson()],
        'status': [for (final o in status) o.toJson()],
        'relationships': [for (final o in relationships) o.toJson()],
        'quest': [for (final o in quest) o.toJson()],
      };

  factory ProposedDeltas.fromJson(Map<String, Object?> json) => ProposedDeltas(
        clockAdvanceMinutes:
            (json['clock_advance_minutes'] as num?)?.round() ?? 0,
        inventory: [
          for (final o in json['inventory'] as List<Object?>? ?? <Object?>[])
            InventoryOp.fromJson(o! as Map<String, Object?>)
        ],
        stats: [
          for (final o in json['stats'] as List<Object?>? ?? <Object?>[])
            StatOp.fromJson(o! as Map<String, Object?>)
        ],
        status: [
          for (final o in json['status'] as List<Object?>? ?? <Object?>[])
            StatusOp.fromJson(o! as Map<String, Object?>)
        ],
        relationships: [
          for (final o
              in json['relationships'] as List<Object?>? ?? <Object?>[])
            RelationshipOp.fromJson(o! as Map<String, Object?>)
        ],
        quest: [
          for (final o in json['quest'] as List<Object?>? ?? <Object?>[])
            QuestOp.fromJson(o! as Map<String, Object?>)
        ],
      );
}

/// The full structured output of one gameplay turn.
class TurnOutput {
  const TurnOutput({
    required this.narrative,
    this.proposedDeltas = const ProposedDeltas(),
    this.peril = false,
    this.wikiCandidates = const [],
    this.narratedInProse = false,
  });

  final String narrative;
  final ProposedDeltas proposedDeltas;

  /// HINT ONLY — the engine decides death gating (§4.3).
  final bool peril;
  final List<WikiCandidate> wikiCandidates;

  /// True when the model ignored the strict-JSON contract and replied in
  /// prose, so the whole reply was salvaged as narrative with empty deltas.
  /// The turn is committed as non-consequential; we log it and monitor how
  /// often it happens (a signal the pinned model doesn't honor json_object).
  final bool narratedInProse;

  Map<String, Object?> toJson() => {
        'narrative': narrative,
        'proposed_deltas': proposedDeltas.toJson(),
        'peril': peril,
        'wiki_candidates': [for (final c in wikiCandidates) c.toJson()],
        'narrated_in_prose': narratedInProse,
      };

  factory TurnOutput.fromJson(Map<String, Object?> json) => TurnOutput(
        narrative: json['narrative'] as String? ?? '',
        proposedDeltas: json['proposed_deltas'] == null
            ? const ProposedDeltas()
            : ProposedDeltas.fromJson(
                json['proposed_deltas'] as Map<String, Object?>),
        peril: json['peril'] as bool? ?? false,
        wikiCandidates: [
          for (final c
              in json['wiki_candidates'] as List<Object?>? ?? <Object?>[])
            WikiCandidate.fromJson(c! as Map<String, Object?>)
        ],
        narratedInProse: json['narrated_in_prose'] as bool? ?? false,
      );
}
