/// Characters (§1.3): stats, statuses, inventory, quests, subjective clock.
library;

import 'item.dart';
import 'quest.dart';

/// A live status flag on a character (injury, buff, condition).
class StatusInstance {
  const StatusInstance({
    required this.key,
    required this.severity,
    required this.sinceClock,
  });

  final String key;
  final double severity;

  /// The character's subjective clock (minutes) when the status was applied
  /// or last refreshed; decay is computed from elapsed subjective time.
  final int sinceClock;

  StatusInstance copyWith({double? severity, int? sinceClock}) =>
      StatusInstance(
        key: key,
        severity: severity ?? this.severity,
        sinceClock: sinceClock ?? this.sinceClock,
      );

  Map<String, Object?> toJson() =>
      {'key': key, 'severity': severity, 'since_clock': sinceClock};

  factory StatusInstance.fromJson(Map<String, Object?> json) => StatusInstance(
        key: json['key'] as String,
        severity: (json['severity'] as num? ?? 1).toDouble(),
        sinceClock: json['since_clock'] as int? ?? 0,
      );
}

class Character {
  const Character({
    required this.id,
    required this.worldId,
    required this.name,
    this.portrait,
    this.bio = '',
    this.subjectiveClock = 0,
    this.alive = true,
    this.stats = const {},
    this.status = const [],
    this.inventory = const [],
    this.quests = const [],
  });

  final String id;
  final String worldId;
  final String name;
  final String? portrait;
  final String bio;

  /// Minutes of subjective in-world time lived so far.
  final int subjectiveClock;
  final bool alive;
  final Map<String, double> stats;
  final List<StatusInstance> status;
  final List<ItemInstance> inventory;
  final List<Quest> quests;

  Character copyWith({
    int? subjectiveClock,
    bool? alive,
    Map<String, double>? stats,
    List<StatusInstance>? status,
    List<ItemInstance>? inventory,
    List<Quest>? quests,
    String? bio,
  }) =>
      Character(
        id: id,
        worldId: worldId,
        name: name,
        portrait: portrait,
        bio: bio ?? this.bio,
        subjectiveClock: subjectiveClock ?? this.subjectiveClock,
        alive: alive ?? this.alive,
        stats: stats ?? this.stats,
        status: status ?? this.status,
        inventory: inventory ?? this.inventory,
        quests: quests ?? this.quests,
      );

  StatusInstance? statusByKey(String key) {
    for (final s in status) {
      if (s.key == key) return s;
    }
    return null;
  }

  ItemInstance? itemByUid(String uid) {
    for (final i in inventory) {
      if (i.uid == uid) return i;
    }
    return null;
  }

  /// Total quantity held of a given item definition.
  int qtyOfDef(String defId) =>
      inventory.where((i) => i.defId == defId).fold(0, (sum, i) => sum + i.qty);

  Quest? questById(String id) {
    for (final q in quests) {
      if (q.id == id) return q;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'world_id': worldId,
        'name': name,
        'portrait': portrait,
        'bio': bio,
        'subjective_clock': subjectiveClock,
        'alive': alive,
        'stats': stats,
        'status': [for (final s in status) s.toJson()],
        'inventory': [for (final i in inventory) i.toJson()],
        'quests': [for (final q in quests) q.toJson()],
      };

  factory Character.fromJson(Map<String, Object?> json) => Character(
        id: json['id'] as String,
        worldId: json['world_id'] as String,
        name: json['name'] as String,
        portrait: json['portrait'] as String?,
        bio: json['bio'] as String? ?? '',
        subjectiveClock: json['subjective_clock'] as int? ?? 0,
        alive: json['alive'] as bool? ?? true,
        stats: {
          for (final e
              in (json['stats'] as Map<String, Object?>? ?? {}).entries)
            e.key: (e.value! as num).toDouble()
        },
        status: [
          for (final s in json['status'] as List<Object?>? ?? <Object?>[])
            StatusInstance.fromJson(s! as Map<String, Object?>)
        ],
        inventory: [
          for (final i in json['inventory'] as List<Object?>? ?? <Object?>[])
            ItemInstance.fromJson(i! as Map<String, Object?>)
        ],
        quests: [
          for (final q in json['quests'] as List<Object?>? ?? <Object?>[])
            Quest.fromJson(q! as Map<String, Object?>)
        ],
      );
}
