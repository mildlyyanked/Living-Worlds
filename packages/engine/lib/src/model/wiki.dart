/// Wiki entries (§1.3, §5).
library;

class WikiEntry {
  const WikiEntry({
    required this.id,
    required this.worldId,
    required this.title,
    required this.category,
    required this.body,
    this.tags = const [],
    this.clockRef,
    this.embedding,
    this.version = 1,
    this.updatedAt,
    this.imageId,
  });

  final String id;
  final String worldId;
  final String title;
  final String category;
  final String body;
  final List<String> tags;

  /// Id of a generated illustration stored in the on-device image blob store,
  /// if any. Null until the user generates one (§ images).
  final String? imageId;

  /// If set, this entry is a timeline event at this world-clock minute.
  final int? clockRef;

  /// Embedding vector; stored as BLOB locally, pgvector remotely. Null until
  /// the (async) embedding job has run.
  final List<double>? embedding;
  final int version;
  final DateTime? updatedAt;

  /// One line for the always-in-context compact index (§5.3.1).
  String get summaryLine {
    final firstLine = body.split('\n').first;
    final oneLiner = firstLine.length <= 100
        ? firstLine
        : '${firstLine.substring(0, 97)}...';
    return '[$category] $title — $oneLiner';
  }

  WikiEntry copyWith({
    String? title,
    String? category,
    String? body,
    List<String>? tags,
    int? clockRef,
    List<double>? embedding,
    int? version,
    DateTime? updatedAt,
    String? imageId,
  }) =>
      WikiEntry(
        id: id,
        worldId: worldId,
        title: title ?? this.title,
        category: category ?? this.category,
        body: body ?? this.body,
        tags: tags ?? this.tags,
        clockRef: clockRef ?? this.clockRef,
        embedding: embedding ?? this.embedding,
        version: version ?? this.version,
        updatedAt: updatedAt ?? this.updatedAt,
        imageId: imageId ?? this.imageId,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'world_id': worldId,
        'title': title,
        'category': category,
        'body': body,
        'tags': tags,
        'clock_ref': clockRef,
        'embedding': embedding,
        'version': version,
        'updated_at': updatedAt?.toIso8601String(),
        'image_id': imageId,
      };

  factory WikiEntry.fromJson(Map<String, Object?> json) => WikiEntry(
        id: json['id'] as String,
        worldId: json['world_id'] as String,
        title: json['title'] as String,
        category: json['category'] as String,
        body: json['body'] as String,
        tags: [
          for (final t in json['tags'] as List<Object?>? ?? <Object?>[])
            t! as String
        ],
        clockRef: json['clock_ref'] as int?,
        embedding: json['embedding'] == null
            ? null
            : [
                for (final v in json['embedding'] as List<Object?>)
                  (v! as num).toDouble()
              ],
        version: json['version'] as int? ?? 1,
        updatedAt: json['updated_at'] == null
            ? null
            : DateTime.parse(json['updated_at'] as String),
        imageId: json['image_id'] as String?,
      );
}

/// A fact surfaced during gameplay awaiting user review (§5.2). Promotion,
/// edit or rejection each become events.
class WikiCandidate {
  const WikiCandidate({
    required this.id,
    required this.title,
    required this.category,
    required this.body,
    this.tags = const [],
    this.clockRef,
    this.sourceTurnSeq,
  });

  final String id;
  final String title;
  final String category;
  final String body;
  final List<String> tags;
  final int? clockRef;

  /// seq of the TurnCommitted event this candidate was extracted from.
  final int? sourceTurnSeq;

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'category': category,
        'body': body,
        'tags': tags,
        'clock_ref': clockRef,
        'source_turn_seq': sourceTurnSeq,
      };

  // Tolerant of missing fields: the gameplay model emits candidates without
  // an `id` (the engine assigns one), and may omit others. Never hard-cast
  // model-provided JSON — a null cast would fail the whole turn.
  factory WikiCandidate.fromJson(Map<String, Object?> json) => WikiCandidate(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        category: json['category'] as String? ?? '',
        body: json['body'] as String? ?? '',
        tags: [
          for (final t in json['tags'] as List<Object?>? ?? <Object?>[])
            if (t != null) '$t'
        ],
        clockRef: (json['clock_ref'] as num?)?.round(),
        sourceTurnSeq: (json['source_turn_seq'] as num?)?.round(),
      );
}
