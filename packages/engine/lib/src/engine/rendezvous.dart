/// World clock & rendezvous (§4.4) — "the hard one".
///
/// When narrative introduces character B into A's session, the engine
/// materializes an NPC-cameo snapshot of B valid at A's current subjective
/// time (from B's last-committed projection + wiki + relationship graph).
/// The meeting outcome is a `SharedEvent` — immutable, first-writer-wins
/// canon appended to both timelines. When B is later played to/past that
/// timestamp, the SharedEvent is injected as fixed, non-negotiable context.
library;

import '../model/character.dart';
import '../model/event.dart';
import '../model/relationship.dart';
import '../model/wiki.dart';
import '../projection/projection.dart';
import '../repo/world_repository.dart';

/// Read-only view of a character for cameo use in someone else's session.
class CameoSnapshot {
  const CameoSnapshot({
    required this.character,
    required this.asOfClock,
    required this.viewerClock,
    required this.outgoingEdge,
    required this.incomingEdge,
    required this.relatedWiki,
    required this.priorSharedEvents,
    required this.stale,
  });

  /// B's last-committed sheet.
  final Character character;

  /// B's subjective clock at snapshot (their last-committed time).
  final int asOfClock;

  /// A's subjective time the cameo is valid at.
  final int viewerClock;

  /// Viewer's opinion of the cameo (A -> B) and vice versa (B -> A).
  final RelationshipEdge? outgoingEdge;
  final RelationshipEdge? incomingEdge;
  final List<WikiEntry> relatedWiki;

  /// Shared canon these two already have, for continuity.
  final List<SharedEventRecord> priorSharedEvents;

  /// True when B's own clock is behind the viewer's time: B's state here is
  /// a projection of an earlier self and B will have to narrate around
  /// whatever canon gets written now.
  final bool stale;

  /// Compact context block injected into A's turn.
  String toContextBlock() {
    final b = StringBuffer()
      ..writeln('CAMEO: ${character.name} (as of their minute $asOfClock, '
          'meeting at your minute $viewerClock${stale ? '; their timeline '
              'has not reached this moment yet — outcomes here become fixed '
              'canon for them' : ''})')
      ..writeln('  bio: ${character.bio}')
      ..writeln('  alive: ${character.alive}');
    if (outgoingEdge != null && outgoingEdge!.dims.isNotEmpty) {
      b.writeln('  your opinion of them: ${outgoingEdge!.dims}');
    }
    if (incomingEdge != null && incomingEdge!.dims.isNotEmpty) {
      b.writeln('  their opinion of you: ${incomingEdge!.dims}');
    }
    for (final s in priorSharedEvents) {
      b.writeln('  shared history (min ${s.atClock}): ${s.summary}');
    }
    return b.toString();
  }
}

class RendezvousService {
  RendezvousService(this.repo, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final WorldRepository repo;
  final DateTime Function() _clock;

  /// Materialize B ([cameoId]) for A's ([viewerId]) session (§4.4).
  Future<CameoSnapshot> cameoSnapshot({
    required WorldProjection projection,
    required String viewerId,
    required String cameoId,
  }) async {
    final viewer = projection.characters[viewerId];
    final cameo = projection.characters[cameoId];
    if (viewer == null || cameo == null) {
      throw ArgumentError('cameoSnapshot: unknown character '
          '(${viewer == null ? viewerId : cameoId})');
    }
    final related = await repo.structuredWikiQuery(freeText: cameo.name);
    final prior = [
      for (final s in projection.sharedEventsFor(viewerId))
        if (s.participants.contains(cameoId)) s
    ];
    return CameoSnapshot(
      character: cameo,
      asOfClock: cameo.subjectiveClock,
      viewerClock: viewer.subjectiveClock,
      outgoingEdge: projection.edge(viewerId, cameoId),
      incomingEdge: projection.edge(cameoId, viewerId),
      relatedWiki: related,
      priorSharedEvents: prior,
      stale: cameo.subjectiveClock < viewer.subjectiveClock,
    );
  }

  /// Write the meeting outcome as immutable canon on both timelines,
  /// stamped with the first writer's subjective time (§4.4).
  Future<Event> commitSharedEvent({
    required WorldProjection projection,
    required String writerId,
    required List<String> participants,
    required String summary,
    String detail = '',
    Map<String, Object?> cause = const {},
  }) async {
    final writer = projection.characters[writerId];
    if (writer == null) {
      throw ArgumentError('commitSharedEvent: unknown writer $writerId');
    }
    if (!participants.contains(writerId)) {
      throw ArgumentError('commitSharedEvent: writer must participate');
    }
    for (final id in participants) {
      if (!projection.characters.containsKey(id)) {
        throw ArgumentError('commitSharedEvent: unknown participant $id');
      }
    }
    final seq = await repo.lastSeq() + 1;
    final e = Event(
      id: 'evt-$seq',
      worldId: projection.world!.id,
      // One event, both timelines: participants are in the payload and
      // sharedEventsFor() projects it into every participant's stream.
      seq: seq,
      timeline: writerId,
      subjectiveClock: writer.subjectiveClock,
      type: EventType.sharedEvent,
      payload: {
        'participants': participants,
        'at_clock': writer.subjectiveClock,
        'summary': summary,
        'detail': detail,
        'writer': writerId,
      },
      cause: cause,
      createdAt: _clock(),
    );
    await repo.appendEvent(e);
    return e;
  }

  /// First-writer-wins (§4.4): canon a character must narrate around when
  /// played at [atClock] — every SharedEvent stamped at or before that time
  /// that their own turns haven't caught up to. Bad canon is fixable only
  /// via undo, never silent edit.
  List<SharedEventRecord> fixedCanonFor({
    required WorldProjection projection,
    required String characterId,
    required int atClock,
  }) =>
      [
        for (final s in projection.sharedEventsFor(characterId))
          if (s.atClock <= atClock) s
      ];
}
