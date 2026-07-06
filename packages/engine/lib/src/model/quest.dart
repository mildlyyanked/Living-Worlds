/// Quests (§1.3).
library;

class QuestStep {
  const QuestStep({required this.id, required this.desc, this.done = false});

  final String id;
  final String desc;
  final bool done;

  QuestStep copyWith({bool? done}) =>
      QuestStep(id: id, desc: desc, done: done ?? this.done);

  Map<String, Object?> toJson() => {'id': id, 'desc': desc, 'done': done};

  factory QuestStep.fromJson(Map<String, Object?> json) => QuestStep(
        id: json['id'] as String,
        desc: json['desc'] as String,
        done: json['done'] as bool? ?? false,
      );
}

class QuestRewardStat {
  const QuestRewardStat({required this.key, required this.delta});

  final String key;
  final double delta;

  Map<String, Object?> toJson() => {'key': key, 'delta': delta};

  factory QuestRewardStat.fromJson(Map<String, Object?> json) =>
      QuestRewardStat(
          key: json['key'] as String, delta: (json['delta'] as num).toDouble());
}

class QuestReward {
  const QuestReward({this.itemDefIds = const [], this.stats = const []});

  /// Item definition ids granted on completion.
  final List<String> itemDefIds;
  final List<QuestRewardStat> stats;

  Map<String, Object?> toJson() => {
        'items': itemDefIds,
        'stats': [for (final s in stats) s.toJson()],
      };

  factory QuestReward.fromJson(Map<String, Object?> json) => QuestReward(
        itemDefIds: [
          for (final i in json['items'] as List<Object?>? ?? <Object?>[])
            i! as String
        ],
        stats: [
          for (final s in json['stats'] as List<Object?>? ?? <Object?>[])
            QuestRewardStat.fromJson(s! as Map<String, Object?>)
        ],
      );
}

enum QuestState { active, complete, failed }

class Quest {
  const Quest({
    required this.id,
    required this.title,
    this.hidden = false,
    this.steps = const [],
    this.reward = const QuestReward(),
    this.state = QuestState.active,
  });

  final String id;
  final String title;
  final bool hidden;
  final List<QuestStep> steps;
  final QuestReward reward;
  final QuestState state;

  bool get allStepsDone => steps.every((s) => s.done);

  Quest copyWith({List<QuestStep>? steps, QuestState? state}) => Quest(
        id: id,
        title: title,
        hidden: hidden,
        steps: steps ?? this.steps,
        reward: reward,
        state: state ?? this.state,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'hidden': hidden,
        'steps': [for (final s in steps) s.toJson()],
        'reward': reward.toJson(),
        'state': state.name,
      };

  factory Quest.fromJson(Map<String, Object?> json) => Quest(
        id: json['id'] as String,
        title: json['title'] as String,
        hidden: json['hidden'] as bool? ?? false,
        steps: [
          for (final s in json['steps'] as List<Object?>? ?? <Object?>[])
            QuestStep.fromJson(s! as Map<String, Object?>)
        ],
        reward: json['reward'] == null
            ? const QuestReward()
            : QuestReward.fromJson(json['reward'] as Map<String, Object?>),
        state: QuestState.values.byName(json['state'] as String? ?? 'active'),
      );
}
