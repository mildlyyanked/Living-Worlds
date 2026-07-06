/// Embedding seam (§5.3): OpenRouter in production, deterministic hash
/// vectors in tests (so retrieval tests need no network).
library;

import 'dart:math' as math;

import '../util/rng.dart';

abstract class EmbeddingClient {
  Future<List<double>> embed(String text);

  /// Embedding tokens consumed by the last call (for the cost log, §10).
  int get lastTokenCount;
}

/// Deterministic "embedding" built from character-trigram hashes. It is not
/// semantically meaningful, but identical/overlapping texts score high
/// cosine, which is enough to test the retrieval plumbing end to end.
class FixtureEmbeddingClient implements EmbeddingClient {
  FixtureEmbeddingClient({this.dims = 64});

  final int dims;
  int _lastTokens = 0;

  @override
  int get lastTokenCount => _lastTokens;

  @override
  Future<List<double>> embed(String text) async {
    _lastTokens = estimate(text);
    final v = List<double>.filled(dims, 0);
    final lower = text.toLowerCase();
    for (var i = 0; i + 3 <= lower.length; i++) {
      final tri = lower.substring(i, i + 3);
      final h =
          SplitMix64(tri.codeUnits.fold(17, (a, c) => a * 31 + c)).nextInt64();
      v[(h & 0x7FFFFFFFFFFFFFFF) % dims] += 1;
    }
    // L2 normalize.
    var norm = 0.0;
    for (final x in v) {
      norm += x * x;
    }
    if (norm > 0) {
      norm = 1 / math.sqrt(norm);
      for (var i = 0; i < v.length; i++) {
        v[i] *= norm;
      }
    }
    return v;
  }

  static int estimate(String text) => (text.length / 4).ceil();
}
