/// Storage seam (§7): one interface, multiple targets (in-memory for tests,
/// SQLite on device, Supabase remote). The same test suite runs against all
/// implementations to prove parity.
library;

import '../model/event.dart';
import '../model/wiki.dart';
import '../projection/projection.dart';

class WorldRepositoryException implements Exception {
  const WorldRepositoryException(this.message);

  final String message;

  @override
  String toString() => 'WorldRepositoryException: $message';
}

abstract class WorldRepository {
  /// Append one event. Must reject non-monotonic seq (append-only log).
  Future<void> appendEvent(Event e);

  /// Append a turn's events atomically — all or none (§3: a turn is a
  /// transaction).
  Future<void> appendEvents(List<Event> events);

  /// All events with seq <= [seq] in order. Negative = all.
  Future<List<Event>> eventsUpTo(int seq);

  /// Current revert markers (soft-undone seqs, §1.1).
  Future<Set<int>> revertedSeqs();

  /// Mark events with seq > [afterSeq] reverted (undo). Returns count.
  Future<int> revertAfter(int afterSeq);

  /// Remove revert markers with seq <= [uptoSeq] (redo). Returns count.
  Future<int> unrevertUpTo(int uptoSeq);

  /// Replace the marker set wholesale (save import, §8).
  Future<void> setRevertMarkers(Set<int> seqs);

  /// Rebuild the projection from the log, honoring revert markers.
  /// [atSeq] rebuilds as-of that seq (inspection/undo preview).
  Future<WorldProjection> projection({int? atSeq});

  /// Brute-force/pgvector cosine top-k over wiki embeddings (§5.3).
  Future<List<WikiEntry>> semanticSearch(List<double> query, {int k = 5});

  /// Exact-ish structured lookup (§2 `query_wiki`).
  Future<List<WikiEntry>> structuredWikiQuery(
      {String? title, String? category, String? freeText});

  /// Persist a wiki embedding (async embedding job write-back).
  Future<void> saveEmbedding(String entryId, List<double> embedding);

  /// Save/load a full world snapshot blob (§8).
  Future<void> saveWorldSnapshot(String id, String blob);
  Future<String> loadWorldSnapshot(String id);

  /// Highest committed seq, or -1 when empty.
  Future<int> lastSeq();

  Future<void> close();
}
