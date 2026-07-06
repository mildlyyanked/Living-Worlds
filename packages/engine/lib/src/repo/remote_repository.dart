/// Remote repository (§7): Supabase (PostgREST + pgvector + Storage).
///
/// Same [WorldRepository] contract as the local targets — the parity suite
/// (test/remote_repository_test.dart) proves it. Works against both a local
/// `supabase start` stack (LAN) and hosted Supabase.
///
/// Each repository instance is namespaced by [scope] so many
/// worlds/test-runs share one database without touching each other.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../model/event.dart';
import '../model/wiki.dart';
import '../projection/projection.dart';
import 'world_repository.dart';

class RemoteRepository implements WorldRepository {
  RemoteRepository({
    required this.url,
    required this.apiKey,
    required this.scope,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  /// Supabase project URL, e.g. https://xyz.supabase.co or http://LAN:54321.
  final String url;

  /// anon or service-role key (RLS decides what it may do).
  final String apiKey;

  /// Namespace for this world's rows (usually the world id).
  final String scope;
  final http.Client _http;

  static const String savesBucket = 'world-saves';

  Map<String, String> get _headers => {
        'apikey': apiKey,
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      };

  Never _fail(String op, http.Response resp) => throw WorldRepositoryException(
      '$op failed: HTTP ${resp.statusCode} ${resp.body}');

  Map<String, Object?> _eventRow(Event e) => {
        'scope': scope,
        'seq': e.seq,
        'event_id': e.id,
        'world_id': e.worldId,
        'timeline': e.timeline,
        'subjective_clock': e.subjectiveClock,
        'type': e.type.name,
        'payload': e.payload,
        'cause': e.cause,
        'created_at': e.createdAt.toIso8601String(),
      };

  Event _rowToEvent(Map<String, Object?> row) => Event(
        id: row['event_id'] as String,
        worldId: row['world_id'] as String,
        seq: row['seq'] as int,
        timeline: row['timeline'] as String,
        subjectiveClock: row['subjective_clock'] as int,
        type: EventType.values.byName(row['type'] as String),
        payload: (row['payload'] as Map<String, Object?>?) ?? const {},
        cause: (row['cause'] as Map<String, Object?>?) ?? const {},
        createdAt: DateTime.parse(row['created_at'] as String),
      );

  @override
  Future<void> appendEvent(Event e) => appendEvents([e]);

  @override
  Future<void> appendEvents(List<Event> events) async {
    if (events.isEmpty) return;
    var expected = await lastSeq() + 1;
    for (final e in events) {
      if (e.seq != expected) {
        throw WorldRepositoryException(
            'appendEvents: seq ${e.seq} is not $expected (atomic batch)');
      }
      expected++;
    }
    // One PostgREST insert = one statement = atomic. The (scope, seq)
    // primary key turns write races into a clean conflict error.
    final resp = await _http.post(
      Uri.parse('$url/rest/v1/lw_events'),
      headers: {..._headers, 'Prefer': 'return=minimal'},
      body: jsonEncode([for (final e in events) _eventRow(e)]),
    );
    if (resp.statusCode == 409) {
      throw WorldRepositoryException(
          'appendEvents: seq conflict (concurrent writer?) ${resp.body}');
    }
    if (resp.statusCode >= 300) _fail('appendEvents', resp);
  }

  @override
  Future<List<Event>> eventsUpTo(int seq) async {
    final filter = seq < 0 ? '' : '&seq=lte.$seq';
    final resp = await _http.get(
      Uri.parse('$url/rest/v1/lw_events?scope=eq.$scope$filter&order=seq.asc'),
      headers: _headers,
    );
    if (resp.statusCode >= 300) _fail('eventsUpTo', resp);
    final rows = jsonDecode(resp.body) as List<Object?>;
    return [
      for (final r in rows) _rowToEvent(r! as Map<String, Object?>)
    ];
  }

  @override
  Future<Set<int>> revertedSeqs() async {
    final resp = await _http.get(
      Uri.parse('$url/rest/v1/lw_revert_markers?scope=eq.$scope&select=seq'),
      headers: _headers,
    );
    if (resp.statusCode >= 300) _fail('revertedSeqs', resp);
    final rows = jsonDecode(resp.body) as List<Object?>;
    return {
      for (final r in rows) (r! as Map<String, Object?>)['seq'] as int
    };
  }

  @override
  Future<int> revertAfter(int afterSeq) async {
    final events = await eventsUpTo(-1);
    final existing = await revertedSeqs();
    final toMark = [
      for (final e in events)
        if (e.seq > afterSeq && !existing.contains(e.seq)) e.seq
    ];
    if (toMark.isEmpty) return 0;
    final resp = await _http.post(
      Uri.parse('$url/rest/v1/lw_revert_markers'),
      headers: {..._headers, 'Prefer': 'return=minimal'},
      body: jsonEncode([
        for (final s in toMark) {'scope': scope, 'seq': s}
      ]),
    );
    if (resp.statusCode >= 300) _fail('revertAfter', resp);
    return toMark.length;
  }

  @override
  Future<int> unrevertUpTo(int uptoSeq) async {
    final existing = await revertedSeqs();
    final removing = existing.where((s) => s <= uptoSeq).length;
    if (removing == 0) return 0;
    final resp = await _http.delete(
      Uri.parse(
          '$url/rest/v1/lw_revert_markers?scope=eq.$scope&seq=lte.$uptoSeq'),
      headers: _headers,
    );
    if (resp.statusCode >= 300) _fail('unrevertUpTo', resp);
    return removing;
  }

  @override
  Future<void> setRevertMarkers(Set<int> seqs) async {
    final resp = await _http.delete(
      Uri.parse('$url/rest/v1/lw_revert_markers?scope=eq.$scope'),
      headers: _headers,
    );
    if (resp.statusCode >= 300) _fail('setRevertMarkers(clear)', resp);
    if (seqs.isEmpty) return;
    final insert = await _http.post(
      Uri.parse('$url/rest/v1/lw_revert_markers'),
      headers: {..._headers, 'Prefer': 'return=minimal'},
      body: jsonEncode([
        for (final s in seqs) {'scope': scope, 'seq': s}
      ]),
    );
    if (insert.statusCode >= 300) _fail('setRevertMarkers(insert)', insert);
  }

  @override
  Future<WorldProjection> projection({int? atSeq}) async {
    final events = await eventsUpTo(atSeq ?? -1);
    final p = WorldProjection.replay(events,
        revertedSeqs: await revertedSeqs());
    // Attach stored embeddings.
    final resp = await _http.get(
      Uri.parse(
          '$url/rest/v1/lw_embeddings?scope=eq.$scope&select=entry_id,embedding'),
      headers: _headers,
    );
    if (resp.statusCode >= 300) _fail('projection(embeddings)', resp);
    for (final r in jsonDecode(resp.body) as List<Object?>) {
      final row = r! as Map<String, Object?>;
      final entry = p.wiki[row['entry_id'] as String];
      if (entry != null) {
        p.wiki[entry.id] =
            entry.copyWith(embedding: _parseVector(row['embedding']));
      }
    }
    return p;
  }

  static List<double> _parseVector(Object? v) {
    // pgvector serializes as the string "[1,2,3]" through PostgREST.
    if (v is List<Object?>) {
      return [for (final x in v) (x! as num).toDouble()];
    }
    final s = (v as String).replaceAll('[', '').replaceAll(']', '');
    if (s.trim().isEmpty) return const [];
    return [for (final part in s.split(',')) double.parse(part)];
  }

  @override
  Future<List<WikiEntry>> semanticSearch(List<double> query,
      {int k = 5}) async {
    // pgvector `<->` via RPC (§5.3).
    final resp = await _http.post(
      Uri.parse('$url/rest/v1/rpc/lw_match_wiki'),
      headers: _headers,
      body: jsonEncode({
        'p_scope': scope,
        'p_query': '[${query.join(',')}]',
        'p_k': k,
      }),
    );
    if (resp.statusCode >= 300) _fail('semanticSearch', resp);
    final rows = jsonDecode(resp.body) as List<Object?>;
    final ids = [
      for (final r in rows) (r! as Map<String, Object?>)['entry_id'] as String
    ];
    final p = await projection();
    return [
      for (final id in ids)
        if (p.wiki[id] != null) p.wiki[id]!
    ];
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
                w.tags.any((t) =>
                    t.toLowerCase().contains(freeText.toLowerCase()))))
          w
    ];
  }

  @override
  Future<void> saveEmbedding(String entryId, List<double> embedding) async {
    final resp = await _http.post(
      Uri.parse('$url/rest/v1/lw_embeddings'),
      headers: {
        ..._headers,
        'Prefer': 'resolution=merge-duplicates,return=minimal'
      },
      body: jsonEncode({
        'scope': scope,
        'entry_id': entryId,
        'embedding': '[${embedding.join(',')}]',
      }),
    );
    if (resp.statusCode >= 300) _fail('saveEmbedding', resp);
  }

  @override
  Future<void> saveWorldSnapshot(String id, String blob) async {
    // Cloud saves via Supabase Storage (§7).
    final resp = await _http.post(
      Uri.parse('$url/storage/v1/object/$savesBucket/$scope/$id.json'),
      headers: {
        'apikey': apiKey,
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
        'x-upsert': 'true',
      },
      body: blob,
    );
    if (resp.statusCode >= 300) _fail('saveWorldSnapshot', resp);
  }

  @override
  Future<String> loadWorldSnapshot(String id) async {
    final resp = await _http.get(
      Uri.parse('$url/storage/v1/object/$savesBucket/$scope/$id.json'),
      headers: {'apikey': apiKey, 'Authorization': 'Bearer $apiKey'},
    );
    if (resp.statusCode == 404 || resp.statusCode == 400) {
      throw WorldRepositoryException('no snapshot with id "$id"');
    }
    if (resp.statusCode >= 300) _fail('loadWorldSnapshot', resp);
    return resp.body;
  }

  @override
  Future<int> lastSeq() async {
    final resp = await _http.get(
      Uri.parse('$url/rest/v1/lw_events?scope=eq.$scope&select=seq'
          '&order=seq.desc&limit=1'),
      headers: _headers,
    );
    if (resp.statusCode >= 300) _fail('lastSeq', resp);
    final rows = jsonDecode(resp.body) as List<Object?>;
    if (rows.isEmpty) return -1;
    return (rows.first! as Map<String, Object?>)['seq'] as int;
  }

  /// Delete every row in this scope (test teardown helper).
  Future<void> deleteScope() async {
    for (final table in ['lw_events', 'lw_revert_markers', 'lw_embeddings']) {
      final resp = await _http.delete(
        Uri.parse('$url/rest/v1/$table?scope=eq.$scope'),
        headers: _headers,
      );
      if (resp.statusCode >= 300) _fail('deleteScope($table)', resp);
    }
  }

  @override
  Future<void> close() async => _http.close();
}
