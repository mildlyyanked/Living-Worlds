/// Brute-force cosine similarity (§5.3): sub-millisecond at this scale.
library;

import 'dart:math' as math;

double cosineSimilarity(List<double> a, List<double> b) {
  if (a.isEmpty || b.isEmpty || a.length != b.length) return 0;
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na == 0 || nb == 0) return 0;
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

/// Top-k items by cosine similarity to [query]. Ties broken by insertion
/// order for determinism.
List<T> topKByCosine<T>(
  List<double> query,
  Iterable<T> items,
  List<double>? Function(T) embeddingOf, {
  int k = 5,
}) {
  final scored = <(T, double, int)>[];
  var idx = 0;
  for (final item in items) {
    final emb = embeddingOf(item);
    if (emb != null && emb.isNotEmpty) {
      scored.add((item, cosineSimilarity(query, emb), idx));
    }
    idx++;
  }
  scored.sort((a, b) {
    final byScore = b.$2.compareTo(a.$2);
    return byScore != 0 ? byScore : a.$3.compareTo(b.$3);
  });
  return [for (final s in scored.take(k)) s.$1];
}
