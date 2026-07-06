import 'package:living_worlds_engine/living_worlds_engine.dart';
import 'package:test/test.dart';

void main() {
  group('SplitMix64', () {
    test('same seed produces identical stream', () {
      final a = SplitMix64(12345);
      final b = SplitMix64(12345);
      for (var i = 0; i < 100; i++) {
        expect(a.nextInt64(), b.nextInt64());
      }
    });

    test('different seeds diverge', () {
      expect(SplitMix64(1).nextInt64(),
          isNot(equals(SplitMix64(2).nextInt64())));
    });

    test('nextDouble stays in [0, 1)', () {
      final rng = SplitMix64(99);
      for (var i = 0; i < 10000; i++) {
        final d = rng.nextDouble();
        expect(d, greaterThanOrEqualTo(0));
        expect(d, lessThan(1));
      }
    });

    test('nextDouble is roughly uniform', () {
      final rng = SplitMix64(7);
      var sum = 0.0;
      const n = 20000;
      for (var i = 0; i < n; i++) {
        sum += rng.nextDouble();
      }
      expect(sum / n, closeTo(0.5, 0.02));
    });
  });

  group('seedForTurn', () {
    test('is deterministic', () {
      expect(seedForTurn(42, 7), seedForTurn(42, 7));
    });

    test('varies with world seed and with seq', () {
      expect(seedForTurn(42, 7), isNot(equals(seedForTurn(43, 7))));
      expect(seedForTurn(42, 7), isNot(equals(seedForTurn(42, 8))));
    });

    test('golden values are stable across releases', () {
      // If these change, every recorded death roll in every save replays
      // differently. Do not "fix" these expectations — fix the regression.
      expect(seedForTurn(42, 0), 8488510227441112855);
      expect(seedForTurn(42, 1), -7105968090023827064);
      expect(seedForTurn(0, 0), 3042925972389327917);
    });
  });
}
