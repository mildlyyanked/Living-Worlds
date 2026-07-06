/// Per-world configurable schema (§1.3 of the design doc).
library;

/// Definition of a numeric character stat.
class StatDef {
  const StatDef({
    required this.key,
    required this.min,
    required this.max,
    required this.defaultValue,
    this.affectsHealth = false,
    this.weight = 0.0,
  });

  final String key;
  final double min;
  final double max;
  final double defaultValue;

  /// When true, this stat contributes `-(value * weight)` to derived health
  /// (e.g. hunger, fatigue penalties in §4.2).
  final bool affectsHealth;
  final double weight;

  Map<String, Object?> toJson() => {
        'key': key,
        'min': min,
        'max': max,
        'default': defaultValue,
        'affects_health': affectsHealth,
        'weight': weight,
      };

  factory StatDef.fromJson(Map<String, Object?> json) => StatDef(
        key: json['key'] as String,
        min: (json['min'] as num).toDouble(),
        max: (json['max'] as num).toDouble(),
        defaultValue: (json['default'] as num).toDouble(),
        affectsHealth: json['affects_health'] as bool? ?? false,
        weight: (json['weight'] as num? ?? 0).toDouble(),
      );
}

/// Definition of a status flag (injury, buff, condition).
class StatusDef {
  const StatusDef({
    required this.key,
    required this.label,
    this.decayPerMin,
    this.severityScale = true,
    this.weight = 0.0,
    this.lethalSeverity,
  });

  final String key;
  final String label;

  /// Severity lost per in-world minute. Null = no decay.
  final double? decayPerMin;

  /// Whether severity scales the effect (design §1.3 `severity_scale`).
  final bool severityScale;

  /// Health contribution per severity point (§4.2 `injury.weight`).
  /// Positive = harmful (subtracted from health); negative = buff (added).
  final double weight;

  /// If set, a severity at or above this value is an engine instant-death
  /// trigger (§4.3, e.g. "poison lethal stack").
  final double? lethalSeverity;

  Map<String, Object?> toJson() => {
        'key': key,
        'label': label,
        'decay_per_min': decayPerMin,
        'severity_scale': severityScale,
        'weight': weight,
        'lethal_severity': lethalSeverity,
      };

  factory StatusDef.fromJson(Map<String, Object?> json) => StatusDef(
        key: json['key'] as String,
        label: json['label'] as String,
        decayPerMin: (json['decay_per_min'] as num?)?.toDouble(),
        severityScale: json['severity_scale'] as bool? ?? true,
        weight: (json['weight'] as num? ?? 0).toDouble(),
        lethalSeverity: (json['lethal_severity'] as num?)?.toDouble(),
      );
}

/// Per-world configuration: which stats, statuses, wiki categories and
/// relationship dimensions exist.
class WorldSchema {
  const WorldSchema({
    required this.statDefs,
    required this.statusDefs,
    required this.wikiCategories,
    required this.relationshipDims,
    this.relationshipDimMin = -10,
    this.relationshipDimMax = 10,
  });

  final List<StatDef> statDefs;
  final List<StatusDef> statusDefs;
  final List<String> wikiCategories;
  final List<String> relationshipDims;
  final double relationshipDimMin;
  final double relationshipDimMax;

  StatDef? statDef(String key) {
    for (final d in statDefs) {
      if (d.key == key) return d;
    }
    return null;
  }

  StatusDef? statusDef(String key) {
    for (final d in statusDefs) {
      if (d.key == key) return d;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
        'stat_defs': [for (final d in statDefs) d.toJson()],
        'status_defs': [for (final d in statusDefs) d.toJson()],
        'wiki_categories': wikiCategories,
        'relationship_dims': relationshipDims,
        'relationship_dim_min': relationshipDimMin,
        'relationship_dim_max': relationshipDimMax,
      };

  factory WorldSchema.fromJson(Map<String, Object?> json) => WorldSchema(
        statDefs: [
          for (final d in json['stat_defs'] as List<Object?>)
            StatDef.fromJson(d! as Map<String, Object?>)
        ],
        statusDefs: [
          for (final d in json['status_defs'] as List<Object?>)
            StatusDef.fromJson(d! as Map<String, Object?>)
        ],
        wikiCategories: [
          for (final c in json['wiki_categories'] as List<Object?>) c! as String
        ],
        relationshipDims: [
          for (final r in json['relationship_dims'] as List<Object?>)
            r! as String
        ],
        relationshipDimMin:
            (json['relationship_dim_min'] as num? ?? -10).toDouble(),
        relationshipDimMax:
            (json['relationship_dim_max'] as num? ?? 10).toDouble(),
      );

  /// A reasonable default fantasy-ish schema used by new worlds and tests.
  factory WorldSchema.standard() => const WorldSchema(
        statDefs: [
          StatDef(key: 'vitality', min: 0, max: 100, defaultValue: 100),
          StatDef(
              key: 'hunger',
              min: 0,
              max: 100,
              defaultValue: 0,
              affectsHealth: true,
              weight: 0.25),
          StatDef(
              key: 'fatigue',
              min: 0,
              max: 100,
              defaultValue: 0,
              affectsHealth: true,
              weight: 0.25),
          StatDef(key: 'coin', min: 0, max: 999999, defaultValue: 10),
        ],
        statusDefs: [
          StatusDef(
              key: 'bleeding', label: 'Bleeding', decayPerMin: 0.02, weight: 8),
          StatusDef(key: 'injured', label: 'Injured', weight: 10),
          StatusDef(
              key: 'poisoned',
              label: 'Poisoned',
              decayPerMin: 0.01,
              weight: 6,
              lethalSeverity: 10),
          StatusDef(
              key: 'rested',
              label: 'Well Rested',
              weight: -5,
              decayPerMin: 0.05),
          StatusDef(
              key: 'blessed', label: 'Blessed', weight: -8, decayPerMin: 0.01),
        ],
        wikiCategories: [
          'Characters',
          'Places',
          'Factions',
          'Items',
          'Events',
          'Lore',
        ],
        relationshipDims: ['trust', 'affection', 'fear', 'respect'],
      );
}
