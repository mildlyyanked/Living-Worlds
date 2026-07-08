/// World record (§1.3).
library;

import 'world_schema.dart';

class World {
  const World({
    required this.id,
    required this.name,
    required this.seed,
    required this.createdAt,
    this.settings = const {},
    required this.schema,
  });

  final String id;
  final String name;

  /// Root seed for all deterministic draws in this world.
  final int seed;
  final DateTime createdAt;
  final Map<String, Object?> settings;
  final WorldSchema schema;

  World copyWith({String? name, Map<String, Object?>? settings}) => World(
        id: id,
        name: name ?? this.name,
        seed: seed,
        createdAt: createdAt,
        settings: settings ?? this.settings,
        schema: schema,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'seed': seed,
        'created_at': createdAt.toIso8601String(),
        'settings': settings,
        'schema': schema.toJson(),
      };

  factory World.fromJson(Map<String, Object?> json) => World(
        id: json['id'] as String,
        name: json['name'] as String,
        seed: json['seed'] as int,
        createdAt: DateTime.parse(json['created_at'] as String),
        settings: (json['settings'] as Map<String, Object?>?) ?? const {},
        schema: WorldSchema.fromJson(json['schema'] as Map<String, Object?>),
      );
}
