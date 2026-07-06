import 'package:living_worlds_engine/living_worlds_engine.dart';
import 'package:test/test.dart';

void main() {
  const config = EngineConfig();

  group('evaluateDeath (§4.3)', () {
    test('healthy + no peril delta => P is exactly 0, never dies', () {
      for (var seed = 0; seed < 200; seed++) {
        final r = evaluateDeath(
          health: config.safeThreshold,
          perilDeltaApplied: false,
          perilHint: true, // hint alone cannot open the gate
          seedTurn: seed,
          config: config,
        );
        expect(r.probability, 0);
        expect(r.outcome, isFalse);
      }
    });

    test('same seed => same outcome (determinism)', () {
      final a = evaluateDeath(
        health: 10,
        perilDeltaApplied: true,
        perilHint: true,
        seedTurn: 777,
        config: config,
      );
      final b = evaluateDeath(
        health: 10,
        perilDeltaApplied: true,
        perilHint: true,
        seedTurn: 777,
        config: config,
      );
      expect(a.outcome, b.outcome);
      expect(a.draw, b.draw);
      expect(a.probability, b.probability);
    });

    test('probability follows the logistic in the danger zone', () {
      final r = evaluateDeath(
        health: config.dangerMidpoint,
        perilDeltaApplied: true,
        perilHint: false,
        seedTurn: 1,
        config: config,
      );
      // At the midpoint, logistic(0) = 0.5.
      expect(r.probability, closeTo(0.5 * config.perilMultiplier, 1e-9));
    });

    test('lower health => higher probability (monotonic)', () {
      double p(double health) => evaluateDeath(
            health: health,
            perilDeltaApplied: true,
            perilHint: false,
            seedTurn: 1,
            config: config,
          ).probability;
      expect(p(5), greaterThan(p(25)));
      expect(p(25), greaterThan(p(59)));
    });

    test('peril hint scales probability but never gates', () {
      final without = evaluateDeath(
        health: 30,
        perilDeltaApplied: true,
        perilHint: false,
        seedTurn: 5,
        config: config,
      );
      final withHint = evaluateDeath(
        health: 30,
        perilDeltaApplied: true,
        perilHint: true,
        seedTurn: 5,
        config: config,
      );
      expect(withHint.probability,
          closeTo(without.probability * config.perilHintBoost, 1e-9));
    });

    test('instant trigger kills regardless of draw', () {
      final r = evaluateDeath(
        health: 100,
        perilDeltaApplied: true,
        perilHint: false,
        seedTurn: 3,
        config: config,
        instantTrigger: 'lethal poison stack',
      );
      expect(r.outcome, isTrue);
      expect(r.instantTrigger, 'lethal poison stack');
    });

    test('non-lethal context never rolls and never dies (§4.6)', () {
      final r = evaluateDeath(
        health: 0,
        perilDeltaApplied: true,
        perilHint: true,
        seedTurn: 3,
        config: config,
        instantTrigger: null,
        nonLethal: true,
      );
      expect(r.outcome, isFalse);
      expect(r.probability, 0);
      expect(r.skippedNonLethal, isTrue);
    });

    test('death rate over many seeds approximates P', () {
      const health = 25.0; // P = 0.5 at midpoint
      var deaths = 0;
      const n = 4000;
      for (var seed = 0; seed < n; seed++) {
        final r = evaluateDeath(
          health: health,
          perilDeltaApplied: true,
          perilHint: false,
          seedTurn: seedForTurn(999, seed),
          config: config,
        );
        if (r.outcome) deaths++;
      }
      expect(deaths / n, closeTo(0.5, 0.03));
    });

    test('probability clamps to 1 with extreme multipliers', () {
      final r = evaluateDeath(
        health: 0,
        perilDeltaApplied: true,
        perilHint: true,
        seedTurn: 1,
        config: const EngineConfig(perilMultiplier: 50),
      );
      expect(r.probability, 1);
      expect(r.outcome, isTrue);
    });
  });
}
