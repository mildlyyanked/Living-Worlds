/// The LLM contract (§2). Every gameplay turn the model returns strict JSON:
/// narrative + proposed state deltas. Every field here is a *proposal* — the
/// deterministic engine accepts, clamps, or rejects each independently.
library;

import '../model/wiki.dart';

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
        op: InventoryOpKind.values.byName(json['op'] as String),
        item: json['item'] as String,
        qty: json['qty'] as int? ?? 1,
        reason: json['reason'] as String? ?? '',
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
        key: json['key'] as String,
        op: StatOpKind.values.byName(json['op'] as String),
        value: (json['value'] as num).toDouble(),
        reason: json['reason'] as String? ?? '',
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
        op: StatusOpKind.values.byName(json['op'] as String),
        key: json['key'] as String,
        severity: (json['severity'] as num?)?.toDouble(),
        reason: json['reason'] as String? ?? '',
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
        to: json['to'] as String,
        dim: json['dim'] as String,
        delta: (json['delta'] as num).toDouble(),
        reason: json['reason'] as String? ?? '',
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
        questId: json['quest_id'] as String,
        op: QuestOpKind.values.byName(json['op'] as String),
        stepId: json['step_id'] as String?,
        reason: json['reason'] as String? ?? '',
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
  });

  final String narrative;
  final ProposedDeltas proposedDeltas;

  /// HINT ONLY — the engine decides death gating (§4.3).
  final bool peril;
  final List<WikiCandidate> wikiCandidates;

  Map<String, Object?> toJson() => {
        'narrative': narrative,
        'proposed_deltas': proposedDeltas.toJson(),
        'peril': peril,
        'wiki_candidates': [for (final c in wikiCandidates) c.toJson()],
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
      );
}
