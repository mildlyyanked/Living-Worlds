/// Health (§4.2): derived, never raw stored state.
///
/// ```
/// health = clamp(base_vitality
///                − Σ(injury.severity * injury.weight)
///                − hunger_penalty − fatigue_penalty
///                + Σ(buffs), 0, 100)
/// ```
///
/// Injuries and buffs are status flags whose per-severity health weight and
/// per-minute decay come from `status_defs` (buffs are statuses with a
/// negative weight). Hunger/fatigue-style penalties are stats flagged
/// `affects_health` with a weight. Decay is evaluated lazily from elapsed
/// subjective time, so no decay events are needed and replay stays exact.
library;

import 'dart:math' as math;

import '../model/character.dart';
import '../model/world_schema.dart';
import 'config.dart';

/// Severity of a status after decay, evaluated at [atClock] (subjective
/// minutes). Never negative.
double effectiveSeverity(StatusInstance status, StatusDef? def, int atClock) {
  final decay = def?.decayPerMin;
  if (decay == null || decay == 0) return math.max(0, status.severity);
  final elapsed = math.max(0, atClock - status.sinceClock);
  return math.max(0.0, status.severity - decay * elapsed);
}

/// True once decay has fully consumed the status.
bool statusExpired(StatusInstance status, StatusDef? def, int atClock) =>
    effectiveSeverity(status, def, atClock) <= 0;

/// Derived health in [0, 100].
double healthOf(Character c, WorldSchema schema, EngineConfig config,
    {int? atClock}) {
  final clock = atClock ?? c.subjectiveClock;

  var health =
      c.stats[config.baseVitalityStatKey] ?? config.defaultBaseVitality;

  for (final status in c.status) {
    final def = schema.statusDef(status.key);
    if (def == null) continue;
    final severity = effectiveSeverity(status, def, clock);
    if (severity <= 0) continue;
    final scale = def.severityScale ? severity : 1.0;
    // Positive weight harms; negative weight is a buff (adds health).
    health -= def.weight * scale;
  }

  for (final def in schema.statDefs) {
    if (!def.affectsHealth) continue;
    final value = c.stats[def.key];
    if (value == null) continue;
    health -= value * def.weight;
  }

  return health.clamp(0.0, 100.0);
}
