/// Engine tunables (§14): flagged for tuning during M2 via debug/cost logs.
library;

class EngineConfig {
  const EngineConfig({
    this.perTurnCapMinutes = 240,
    this.safeThreshold = 60,
    this.dangerMidpoint = 25,
    this.logisticK = 0.12,
    this.perilMultiplier = 1.0,
    this.perilHintBoost = 1.25,
    this.baseVitalityStatKey = 'vitality',
    this.defaultBaseVitality = 100,
  });

  /// Max minutes a single ordinary turn may advance the actor's clock
  /// (explicit declared skips bypass this — §4.4).
  final int perTurnCapMinutes;

  /// At or above this derived health, with no peril delta applied this turn,
  /// death probability is exactly 0 (§4.3).
  final double safeThreshold;

  /// Health at which the death logistic is centered (§4.3).
  final double dangerMidpoint;

  /// Steepness of the death logistic (§4.3).
  final double logisticK;

  /// Base multiplier on death probability (§4.3).
  final double perilMultiplier;

  /// The LLM's `peril` flag is a hint, never the decision (§2): when true it
  /// scales the multiplier by this factor. It cannot create risk on its own
  /// because the safe gate is engine-observed.
  final double perilHintBoost;

  /// Stat used as base vitality in the health formula; if the schema doesn't
  /// define it, [defaultBaseVitality] is used.
  final String baseVitalityStatKey;
  final double defaultBaseVitality;

  Map<String, Object?> toJson() => {
        'per_turn_cap_minutes': perTurnCapMinutes,
        'safe_threshold': safeThreshold,
        'danger_midpoint': dangerMidpoint,
        'logistic_k': logisticK,
        'peril_multiplier': perilMultiplier,
        'peril_hint_boost': perilHintBoost,
        'base_vitality_stat_key': baseVitalityStatKey,
        'default_base_vitality': defaultBaseVitality,
      };
}
