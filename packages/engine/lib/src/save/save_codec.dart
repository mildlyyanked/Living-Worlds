/// Save / load (§8). A world save =
/// `{world record, schema, full event log, revert markers, projection cache}`.
/// Text/JSON format; because projections derive from the log, saves are
/// inherently consistent and diff-able. Load restores the log and rebuilds
/// projections (verifying against the cache).
library;

import 'dart:convert';

import '../model/event.dart';
import '../projection/projection.dart';
import '../repo/world_repository.dart';

class WorldSave {
  const WorldSave({
    required this.formatVersion,
    required this.events,
    required this.revertedSeqs,
    required this.projectionCache,
  });

  final int formatVersion;
  final List<Event> events;
  final Set<int> revertedSeqs;
  final Map<String, Object?> projectionCache;

  static const int currentFormatVersion = 1;
}

class SaveCodec {
  const SaveCodec();

  Future<String> exportWorld(WorldRepository repo) async {
    final events = await repo.eventsUpTo(-1);
    final reverted = await repo.revertedSeqs();
    final projection = await repo.projection();
    return const JsonEncoder.withIndent('  ').convert({
      'format_version': WorldSave.currentFormatVersion,
      'world': projection.world?.toJson(),
      'schema': projection.world?.schema.toJson(),
      'events': [for (final e in events) e.toJson()],
      'revert_markers': reverted.toList()..sort(),
      'projection_cache': projection.toJson(),
    });
  }

  WorldSave decode(String blob) {
    final json = jsonDecode(blob) as Map<String, Object?>;
    final version = json['format_version'] as int? ?? 0;
    if (version > WorldSave.currentFormatVersion) {
      throw WorldRepositoryException(
          'save format v$version is newer than supported '
          'v${WorldSave.currentFormatVersion}');
    }
    return WorldSave(
      formatVersion: version,
      events: [
        for (final e in json['events'] as List<Object?>)
          Event.fromJson(e! as Map<String, Object?>)
      ],
      revertedSeqs: {
        for (final s in json['revert_markers'] as List<Object?>? ?? <Object?>[])
          s! as int
      },
      projectionCache:
          (json['projection_cache'] as Map<String, Object?>?) ?? const {},
    );
  }

  /// Restore a save into an empty repository. Rebuilds the projection from
  /// the log and, when the save carries a cache, verifies replay against it
  /// ("trust cache + verify", §8). Returns the rebuilt projection.
  Future<WorldProjection> importWorld(
      WorldRepository repo, String blob) async {
    if (await repo.lastSeq() != -1) {
      throw WorldRepositoryException(
          'importWorld: repository is not empty');
    }
    final save = decode(blob);
    await repo.appendEvents(save.events);
    await repo.setRevertMarkers(save.revertedSeqs);
    final projection = await repo.projection();
    final cache = save.projectionCache;
    if (cache.isNotEmpty) {
      final replayed = jsonEncode(projection.toJson());
      final cached = jsonEncode(cache);
      if (replayed != cached) {
        throw WorldRepositoryException(
            'importWorld: replayed projection differs from save cache — '
            'log and cache are inconsistent');
      }
    }
    return projection;
  }
}
