/// Deterministic, cross-platform seeded RNG.
///
/// The design doc requires `seed_turn = hash(world.seed, event.seq)` and
/// reproducible draws (same seed => same outcome, on every platform and VM
/// version). Dart's `Random(seed)` is not specified to be stable across VM
/// releases, so we implement SplitMix64 ourselves.
library;

/// One SplitMix64 step. Returns the next 64-bit state and mixes it into an
/// output value. All arithmetic is modulo 2^64 (Dart ints wrap on VM;
/// explicitly masked so behavior is identical everywhere).
class SplitMix64 {
  SplitMix64(int seed) : _state = seed;

  int _state;

  static const int _mask64 = 0xFFFFFFFFFFFFFFFF;

  int nextInt64() {
    _state = (_state + 0x9E3779B97F4A7C15) & _mask64;
    var z = _state;
    z = ((z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9) & _mask64;
    z = ((z ^ (z >>> 27)) * 0x94D049BB133111EB) & _mask64;
    return z ^ (z >>> 31);
  }

  /// Uniform double in [0, 1). Uses the top 53 bits of the next output.
  double nextDouble() => (nextInt64() >>> 11) * (1.0 / (1 << 53));
}

/// Stable combine of the world seed and an event sequence number into a
/// per-turn seed: `seed_turn = hash(world.seed, seq)`.
int seedForTurn(int worldSeed, int seq) {
  // Run each input through a SplitMix64 step and xor-fold; this is the
  // standard way to derive independent streams from SplitMix64.
  final a = SplitMix64(worldSeed).nextInt64();
  final b = SplitMix64(seq ^ 0x5DEECE66D).nextInt64();
  return a ^ b;
}
