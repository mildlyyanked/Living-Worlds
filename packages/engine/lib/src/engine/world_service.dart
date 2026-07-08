/// Helpers for authoring foundational events: world creation, characters,
/// item definitions, wiki CRUD, undo/redo, and candidate review — every
/// change is an event (§0, §5).
library;

import '../model/character.dart';
import '../model/event.dart';
import '../model/item.dart';
import '../model/wiki.dart';
import '../model/world.dart';
import '../projection/projection.dart';
import '../repo/world_repository.dart';

class WorldService {
  WorldService(this.repo, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final WorldRepository repo;
  final DateTime Function() _clock;

  Future<Event> _append(
    String worldId,
    EventType type,
    Map<String, Object?> payload, {
    String timeline = worldTimeline,
    int subjectiveClock = 0,
    Map<String, Object?> cause = const {},
  }) async {
    final seq = await repo.lastSeq() + 1;
    final e = Event(
      id: 'evt-$seq',
      worldId: worldId,
      seq: seq,
      timeline: timeline,
      subjectiveClock: subjectiveClock,
      type: type,
      payload: payload,
      cause: cause,
      createdAt: _clock(),
    );
    await repo.appendEvent(e);
    return e;
  }

  Future<Event> createWorld(World world) =>
      _append(world.id, EventType.worldCreated, {'world': world.toJson()});

  Future<Event> createCharacter(Character character) => _append(
        character.worldId,
        EventType.characterCreated,
        {'character': character.toJson()},
        timeline: character.id,
        subjectiveClock: character.subjectiveClock,
      );

  Future<Event> createItemDef(ItemDef def) => _append(
      def.worldId, EventType.itemDefCreated, {'item_def': def.toJson()});

  /// Designate (or clear) the wiki entry that serves as the world's basic bio,
  /// used as context when generating new characters/scenarios (§ onboarding).
  /// Passing null clears the designation.
  Future<Event> designateWorldBio(String worldId, String? entryId) => _append(
        worldId,
        EventType.worldConfigured,
        {
          'settings': {'world_bio_entry_id': entryId}
        },
      );

  /// Seeding session output (§5.1): create a wiki entry as an event.
  Future<Event> createWikiEntry(WikiEntry entry,
      {Map<String, Object?> cause = const {}}) async {
    final p = await repo.projection();
    _requireValidCategory(p, entry.category);
    if (p.wiki.containsKey(entry.id)) {
      throw WorldRepositoryException(
          'wiki entry "${entry.id}" already exists; use updateWikiEntry');
    }
    return _append(entry.worldId, EventType.wikiCreated,
        {'entry': entry.copyWith(updatedAt: _clock()).toJson()},
        cause: cause);
  }

  /// Update = new immutable version event (§5.1).
  Future<Event> updateWikiEntry(WikiEntry updated,
      {Map<String, Object?> cause = const {}}) async {
    final p = await repo.projection();
    final existing = p.wiki[updated.id];
    if (existing == null) {
      throw WorldRepositoryException(
          'wiki entry "${updated.id}" does not exist; use createWikiEntry');
    }
    _requireValidCategory(p, updated.category);
    final next =
        updated.copyWith(version: existing.version + 1, updatedAt: _clock());
    return _append(
        updated.worldId,
        EventType.wikiUpdated,
        {
          'entry': next.toJson(),
          'from_version': existing.version,
        },
        cause: cause);
  }

  /// Promote a queued gameplay candidate into a real entry (§5.2). The
  /// user may have edited it first — pass the edited entry.
  Future<Event> promoteCandidate(String candidateId, WikiEntry asEntry) async {
    final p = await repo.projection();
    if (!p.pendingCandidates.containsKey(candidateId)) {
      throw WorldRepositoryException('no pending candidate "$candidateId"');
    }
    _requireValidCategory(p, asEntry.category);
    return _append(asEntry.worldId, EventType.wikiCandidatePromoted, {
      'candidate_id': candidateId,
      'entry': asEntry.copyWith(updatedAt: _clock()).toJson(),
    });
  }

  Future<Event> rejectCandidate(String worldId, String candidateId) async {
    final p = await repo.projection();
    if (!p.pendingCandidates.containsKey(candidateId)) {
      throw WorldRepositoryException('no pending candidate "$candidateId"');
    }
    return _append(worldId, EventType.wikiCandidateRejected,
        {'candidate_id': candidateId});
  }

  /// Undo to just after [seq]: everything later becomes soft-reverted
  /// (§1.1 — projections rebuild, history is kept for redo).
  Future<int> undoTo(int seq) => repo.revertAfter(seq);

  /// Redo events up to [seq] by clearing their revert markers.
  Future<int> redoTo(int seq) => repo.unrevertUpTo(seq);

  void _requireValidCategory(WorldProjection projection, String category) {
    final world = projection.world;
    if (world == null) return;
    if (!world.schema.wikiCategories.contains(category)) {
      throw WorldRepositoryException(
          'category "$category" is not in this world\'s schema '
          '(${world.schema.wikiCategories.join(', ')})');
    }
  }
}
