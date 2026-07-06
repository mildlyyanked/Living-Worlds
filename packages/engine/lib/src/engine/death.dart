/// Death eval (§4.3): seeded, gated, reproducible.
///
/// ```
/// if health >= SAFE_THRESHOLD and not peril_delta_applied: P = 0
/// else: P = logistic(k * (DANGER_MIDPOINT − health)) * peril_multiplier
/// draw = seeded_rng(seed_turn)
/// death = draw < P  OR  engine_instant_death_trigger
/// ```
///
/// `peril_delta_applied` is engine-observed (a harmful status was actually
/// applied this turn), never the LLM flag. The LLM `peril` hint only scales
/// the multiplier and cannot open the gate by itself.
library;

import 'dart:math' as math;

import '../debug/report.dart';
import '../util/rng.dart';
import 'config.dart';

double logistic(double x) => 1.0 / (1.0 + math.exp(-x));

/// Pure death evaluation. [instantTrigger] is a non-null reason string when
/// an engine rule (e.g. lethal poison stack, declared fall) forces death.
/// [nonLethal] contexts (time-skips) never roll and never die.
DeathEvalReport evaluateDeath({
  required double health,
  required bool perilDeltaApplied,
  required bool perilHint,
  required int seedTurn,
  required EngineConfig config,
  String? instantTrigger,
  bool nonLethal = false,
}) {
  if (nonLethal) {
    return DeathEvalReport(
      health: health,
      probability: 0,
      seedTurn: seedTurn,
      draw: 0,
      outcome: false,
      perilDeltaApplied: perilDeltaApplied,
      perilHint: perilHint,
      skippedNonLethal: true,
    );
  }

  double p;
  if (health >= config.safeThreshold && !perilDeltaApplied) {
    p = 0;
  } else {
    final multiplier =
        config.perilMultiplier * (perilHint ? config.perilHintBoost : 1.0);
    p = logistic(config.logisticK * (config.dangerMidpoint - health)) *
        multiplier;
    p = p.clamp(0.0, 1.0);
  }

  final draw = SplitMix64(seedTurn).nextDouble();
  final death = draw < p || instantTrigger != null;

  return DeathEvalReport(
    health: health,
    probability: p,
    seedTurn: seedTurn,
    draw: draw,
    outcome: death,
    perilDeltaApplied: perilDeltaApplied,
    perilHint: perilHint,
    instantTrigger: instantTrigger,
  );
}
