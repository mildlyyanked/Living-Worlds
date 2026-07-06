/// On-device repository (§7): SQLite event log, embeddings as BLOBs,
/// brute-force cosine retrieval. Zero bootstrap; the fast mobile debug loop.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../model/event.dart';
import '../model/wiki.dart';
import '../projection/projection.dart';
import '../retrieval/cosine.dart';
import 'world_repository.dart';

class LocalRepository implements WorldRepository {
  LocalRepository._(this._db);

  /// Open (or create) a database file; use [LocalRepository.inMemory] for
  /// tests.
  factory LocalRepository.open(String path) {
    final db = sqlite3.open(path);
    _migrate(db);
    return LocalRepository._(db);
  }

  factory LocalRepository.inMemory() {
    final db = sqlite3.openInMemory();
    _migrate(db);
    return LocalRepository._(db);
  }

  final Database _db;

  static void _migrate(Database db) {
    db.execute('''
      PRAGMA journal_mode = WAL;
      CREATE TABLE IF NOT EXISTS events (
        seq INTEGER PRIMARY KEY,
        id TEXT NOT NULL,
        world_id TEXT NOT NULL,
        timeline TEXT NOT NULL,
        subjective_clock INTEGER NOT NULL,
        type TEXT NOT NULL,
        payload TEXT NOT NULL,
        cause TEXT NOT NULL,
        created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS revert_markers (
        seq INTEGER PRIMARY KEY
      );
      CREATE TABLE IF NOT EXISTS embeddings (
        entry_id TEXT PRIMARY KEY,
        vector BLOB NOT NULL
      );
      CREATE TABLE IF NOT EXISTS snapshots (
        id TEXT PRIMARY KEY,
        blob TEXT NOT NULL,
        saved_at TEXT NOT NULL
      );
    ''');
  }

  @override
  Future<void> appendEvent(Event e) async {
    final last = await lastSeq();
    if (e.seq != last + 1) {
      throw WorldRepositoryException(
          'appendEvent: seq ${e.seq} is not ${last + 1} (append-only log)');
    }
    _insert(e);
  }

  @override
  Future<void> appendEvents(List<Event> events) async {
    var expected = await lastSeq() + 1;
    for (final e in events) {
      if (e.seq != expected) {
        throw WorldRepositoryException(
            'appendEvents: seq ${e.seq} is not $expected (atomic batch)');
      }
      expected++;
    }
    _db.execute('BEGIN');
    try {
      for (final e in events) {
        _insert(e);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _insert(Event e) {
    _db.execute(
      'INSERT INTO events (seq, id, world_id, timeline, subjective_clock, '
      'type, payload, cause, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        e.seq,
        e.id,
        e.worldId,
        e.timeline,
        e.subjectiveClock,
        e.type.name,
        jsonEncode(e.payload),
        jsonEncode(e.cause),
        e.createdAt.toIso8601String(),
      ],
    );
  }

  Event _rowToEvent(Row row) => Event(
        id: row['id'] as String,
        worldId: row['world_id'] as String,
        seq: row['seq'] as int,
        timeline: row['timeline'] as String,
        subjectiveClock: row['subjective_clock'] as int,
        type: EventType.values.byName(row['type'] as String),
        payload: jsonDecode(row['payload'] as String) as Map<String, Object?>,
        cause: jsonDecode(row['cause'] as String) as Map<String, Object?>,
        createdAt: DateTime.parse(row['created_at'] as String),
      );

  @override
  Future<List<Event>> eventsUpTo(int seq) async {
    final rows = seq < 0
        ? _db.select('SELECT * FROM events ORDER BY seq')
        : _db.select('SELECT * FROM events WHERE seq <= ? ORDER BY seq', [seq]);
    return [for (final r in rows) _rowToEvent(r)];
  }

  @override
  Future<Set<int>> revertedSeqs() async => {
        for (final r in _db.select('SELECT seq FROM revert_markers'))
          r['seq'] as int
      };

  @override
  Future<int> revertAfter(int afterSeq) async {
    final rows = _db.select(
        'SELECT seq FROM events WHERE seq > ? AND seq NOT IN '
        '(SELECT seq FROM revert_markers)',
        [afterSeq]);
    for (final r in rows) {
      _db.execute('INSERT INTO revert_markers (seq) VALUES (?)', [r['seq']]);
    }
    return rows.length;
  }

  @override
  Future<int> unrevertUpTo(int uptoSeq) async {
    final n = _db.select('SELECT COUNT(*) c FROM revert_markers WHERE seq <= ?',
        [uptoSeq]).first['c'] as int;
    _db.execute('DELETE FROM revert_markers WHERE seq <= ?', [uptoSeq]);
    return n;
  }

  @override
  Future<void> setRevertMarkers(Set<int> seqs) async {
    _db.execute('DELETE FROM revert_markers');
    for (final s in seqs) {
      _db.execute('INSERT INTO revert_markers (seq) VALUES (?)', [s]);
    }
  }

  @override
  Future<WorldProjection> projection({int? atSeq}) async {
    final events = await eventsUpTo(atSeq ?? -1);
    final p =
        WorldProjection.replay(events, revertedSeqs: await revertedSeqs());
    for (final r in _db.select('SELECT entry_id, vector FROM embeddings')) {
      final entry = p.wiki[r['entry_id'] as String];
      if (entry != null) {
        p.wiki[entry.id] =
            entry.copyWith(embedding: _blobToVector(r['vector'] as List<int>));
      }
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
        if ((title == null || w.title.toLowerCase() == title.toLowerCase()) &&
            (category == null ||
                w.category.toLowerCase() == category.toLowerCase()) &&
            (freeText == null ||
                w.title.toLowerCase().contains(freeText.toLowerCase()) ||
                w.body.toLowerCase().contains(freeText.toLowerCase()) ||
                w.tags.any(
                    (t) => t.toLowerCase().contains(freeText.toLowerCase()))))
          w
    ];
  }

  @override
  Future<void> saveEmbedding(String entryId, List<double> embedding) async {
    _db.execute(
      'INSERT INTO embeddings (entry_id, vector) VALUES (?, ?) '
      'ON CONFLICT(entry_id) DO UPDATE SET vector = excluded.vector',
      [entryId, _vectorToBlob(embedding)],
    );
  }

  static Uint8List _vectorToBlob(List<double> v) {
    final data = Float64List.fromList(v);
    return data.buffer.asUint8List();
  }

  static List<double> _blobToVector(List<int> blob) {
    final bytes = Uint8List.fromList(blob);
    return bytes.buffer.asFloat64List().toList();
  }

  @override
  Future<void> saveWorldSnapshot(String id, String blob) async {
    _db.execute(
      'INSERT INTO snapshots (id, blob, saved_at) VALUES (?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET blob = excluded.blob, '
      'saved_at = excluded.saved_at',
      [id, blob, DateTime.now().toIso8601String()],
    );
  }

  @override
  Future<String> loadWorldSnapshot(String id) async {
    final rows = _db.select('SELECT blob FROM snapshots WHERE id = ?', [id]);
    if (rows.isEmpty) {
      throw WorldRepositoryException('no snapshot with id "$id"');
    }
    return rows.first['blob'] as String;
  }

  @override
  Future<int> lastSeq() async {
    final row = _db.select('SELECT MAX(seq) m FROM events').first;
    return (row['m'] as int?) ?? -1;
  }

  @override
  Future<void> close() async => _db.dispose();
}
