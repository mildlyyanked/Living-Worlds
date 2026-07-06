/// Item definitions and per-character possessions (§1.3, §4.1).
library;

/// A stat or status effect an item applies when used.
class ItemEffect {
  const ItemEffect({
    required this.onUse,
    this.statKey,
    this.statDelta,
    this.statusKey,
    this.statusOp,
    this.statusSeverity,
  });

  /// The affordance verb that triggers this effect (e.g. "heal", "light").
  final String onUse;
  final String? statKey;
  final double? statDelta;
  final String? statusKey;

  /// "add" or "remove".
  final String? statusOp;
  final double? statusSeverity;

  Map<String, Object?> toJson() => {
        'on_use': onUse,
        'stat_key': statKey,
        'stat_delta': statDelta,
        'status_key': statusKey,
        'status_op': statusOp,
        'status_severity': statusSeverity,
      };

  factory ItemEffect.fromJson(Map<String, Object?> json) => ItemEffect(
        onUse: json['on_use'] as String,
        statKey: json['stat_key'] as String?,
        statDelta: (json['stat_delta'] as num?)?.toDouble(),
        statusKey: json['status_key'] as String?,
        statusOp: json['status_op'] as String?,
        statusSeverity: (json['status_severity'] as num?)?.toDouble(),
      );
}

class ItemDef {
  const ItemDef({
    required this.id,
    required this.worldId,
    required this.name,
    required this.desc,
    this.affordances = const [],
    this.effects = const [],
    this.consumable = false,
    this.stackable = true,
  });

  final String id;
  final String worldId;
  final String name;
  final String desc;

  /// Verbs this item enables: "unlock", "heal", "bribe", "light" ... (§4.1).
  final List<String> affordances;
  final List<ItemEffect> effects;
  final bool consumable;
  final bool stackable;

  Map<String, Object?> toJson() => {
        'id': id,
        'world_id': worldId,
        'name': name,
        'desc': desc,
        'affordances': affordances,
        'effects': [for (final e in effects) e.toJson()],
        'consumable': consumable,
        'stackable': stackable,
      };

  factory ItemDef.fromJson(Map<String, Object?> json) => ItemDef(
        id: json['id'] as String,
        worldId: json['world_id'] as String,
        name: json['name'] as String,
        desc: json['desc'] as String,
        affordances: [
          for (final a in json['affordances'] as List<Object?>? ?? <Object?>[])
            a! as String
        ],
        effects: [
          for (final e in json['effects'] as List<Object?>? ?? <Object?>[])
            ItemEffect.fromJson(e! as Map<String, Object?>)
        ],
        consumable: json['consumable'] as bool? ?? false,
        stackable: json['stackable'] as bool? ?? true,
      );
}

/// A concrete possession held by a character.
class ItemInstance {
  const ItemInstance({
    required this.defId,
    required this.qty,
    required this.uid,
    this.state = const {},
  });

  final String defId;
  final int qty;

  /// Unique per grant — makes ItemGranted events idempotent on replay.
  final String uid;
  final Map<String, Object?> state;

  ItemInstance copyWith({int? qty, Map<String, Object?>? state}) =>
      ItemInstance(defId: defId, qty: qty ?? this.qty, uid: uid, state: state ?? this.state);

  Map<String, Object?> toJson() =>
      {'def_id': defId, 'qty': qty, 'uid': uid, 'state': state};

  factory ItemInstance.fromJson(Map<String, Object?> json) => ItemInstance(
        defId: json['def_id'] as String,
        qty: json['qty'] as int,
        uid: json['uid'] as String,
        state: (json['state'] as Map<String, Object?>?) ?? const {},
      );
}
