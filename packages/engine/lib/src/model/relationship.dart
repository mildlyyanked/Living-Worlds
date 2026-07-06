/// Directed, multi-dimensional relationship edges (§1.3, §4.5).
library;

class RelationshipEdge {
  const RelationshipEdge({
    required this.worldId,
    required this.fromChar,
    required this.toChar,
    this.dims = const {},
    this.notes = const [],
  });

  final String worldId;
  final String fromChar;
  final String toChar;

  /// dim key -> value, clamped to the schema's per-dim range.
  final Map<String, double> dims;
  final List<String> notes;

  RelationshipEdge copyWith({Map<String, double>? dims, List<String>? notes}) =>
      RelationshipEdge(
        worldId: worldId,
        fromChar: fromChar,
        toChar: toChar,
        dims: dims ?? this.dims,
        notes: notes ?? this.notes,
      );

  Map<String, Object?> toJson() => {
        'world_id': worldId,
        'from_char': fromChar,
        'to_char': toChar,
        'dims': dims,
        'notes': notes,
      };

  factory RelationshipEdge.fromJson(Map<String, Object?> json) =>
      RelationshipEdge(
        worldId: json['world_id'] as String,
        fromChar: json['from_char'] as String,
        toChar: json['to_char'] as String,
        dims: {
          for (final e in (json['dims'] as Map<String, Object?>? ?? {}).entries)
            e.key: (e.value! as num).toDouble()
        },
        notes: [
          for (final n in json['notes'] as List<Object?>? ?? <Object?>[])
            n! as String
        ],
      );
}
