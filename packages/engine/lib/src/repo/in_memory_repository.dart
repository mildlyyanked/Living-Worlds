/// In-memory repository: the reference implementation the parity suite
/// measures the others against. Also useful for fast unit tests.
library;

import '../model/event.dart';
import '../model/wiki.dart';
import '../projection/projection.dart';
import '../retrieval/cosine.dart';
import 'world_repository.dart';

class InMemoryRepository implements WorldRepository {
  final List<Event> _events = [];
  final Set<int> _reverted = {};
  final Map<String, List<double>> _embeddings = {};
  final Map<String, String> _snapshots = {};

  @override
  Future<void> appendEvent(Event e) async {
    final last = _events.isEmpty ? -1 : _events.last.seq;
    if (e.seq != last + 1) {
      throw WorldRepositoryException(
          'appendEvent: seq ${e.seq} is not ${last + 1} (append-only log)');
    }
    _events.add(e);
    // A new commit past an undo point invalidates redo of the old branch —
    // markers above the new event are meaningless (events are gone from the
    // active history's perspective but stay inspectable).
  }

  @override
  Future<void> appendEvents(List<Event> events) async {
    // Atomic: validate the whole batch before mutating.
    var expected = (_events.isEmpty ? -1 : _events.last.seq) + 1;
    for (final e in events) {
      if (e.seq != expected) {
        throw WorldRepositoryException(
            'appendEvents: seq ${e.seq} is not $expected (atomic batch)');
      }
      expected++;
    }
    _events.addAll(events);
  }

  @override
  Future<List<Event>> eventsUpTo(int seq) async => [
        for (final e in _events)
          if (seq < 0 || e.seq <= seq) e
      ];

  @override
  Future<Set<int>> revertedSeqs() async => Set.of(_reverted);

  @override
  Future<int> revertAfter(int afterSeq) async {
    var n = 0;
    for (final e in _events) {
      if (e.seq > afterSeq && _reverted.add(e.seq)) n++;
    }
    return n;
  }

  @override
  Future<int> unrevertUpTo(int uptoSeq) async {
    final toRemove = [
      for (final s in _reverted)
        if (s <= uptoSeq) s
    ];
    _reverted.removeAll(toRemove);
    return toRemove.length;
  }

  @override
  Future<void> setRevertMarkers(Set<int> seqs) async {
    _reverted
      ..clear()
      ..addAll(seqs);
  }

  @override
  Future<WorldProjection> projection({int? atSeq}) async {
    final p = WorldProjection.replay(
      _events,
      upToSeq: atSeq,
      revertedSeqs: _reverted,
    );
    for (final e in _embeddings.entries) {
      final entry = p.wiki[e.key];
      if (entry != null) p.wiki[e.key] = entry.copyWith(embedding: e.value);
    }
    return p;
  }

  @override
  Future<List<WikiEntry>> semanticSearch(List<double> query,
      {int k = 5}) async {
    final p = await projection();
    return topKByCosine(query, p.wiki.values, (w) => w.embedding, k: k);
  }

  @override
  Future<List<WikiEntry>> structuredWikiQuery(
      {String? title, String? category, String? freeText}) async {
    final p = await projection();
    return [
      for (final w in p.wiki.values)
        if ((title == null ||
                w.title.toLowerCase() == title.toLowerCase()) &&
            (category == null ||
                w.category.toLowerCase() == category.toLowerCase()) &&
            (freeText == null ||
                w.title.toLowerCase().contains(freeText.toLowerCase()) ||
                w.body.toLowerCase().contains(freeText.toLowerCase()) ||
                w.tags.any((t) =>
                    t.toLowerCase().contains(freeText.toLowerCase()))))
          w
    ];
  }

  @override
  Future<void> saveEmbedding(String entryId, List<double> embedding) async {
    _embeddings[entryId] = List.of(embedding);
  }

  @override
  Future<void> saveWorldSnapshot(String id, String blob) async {
    _snapshots[id] = blob;
  }

  @override
  Future<String> loadWorldSnapshot(String id) async {
    final blob = _snapshots[id];
    if (blob == null) {
      throw WorldRepositoryException('no snapshot with id "$id"');
    }
    return blob;
  }

  @override
  Future<int> lastSeq() async => _events.isEmpty ? -1 : _events.last.seq;

  @override
  Future<void> close() async {}
}
