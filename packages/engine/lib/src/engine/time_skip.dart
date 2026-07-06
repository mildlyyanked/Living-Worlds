/// Time-skip / catch-up generator (§4.6).
///
/// When opening a character the world has advanced past: generate a
/// retrospective for `[B.subjective_clock, target]`, anchored to every
/// SharedEvent B participated in inside that window (fixed canon),
/// validate the proposed deltas through the normal engine **non-lethally**,
/// and commit a single undoable `TimeSkip` event holding the synthesized
/// summary plus the applied deltas.
library;

import 'dart:convert';

import '../llm/contract.dart';
import '../llm/llm_client.dart';
import '../model/event.dart';
import '../projection/projection.dart';
import '../repo/world_repository.dart';
import 'config.dart';
import 'rendezvous.dart';
import 'turn_engine.dart';
import 'validation.dart';

/// User's resume-point choice (§4.6.1).
enum TimeSkipTarget { afterLastSharedEvent, latestWorldClock }

class TimeSkipResult {
  const TimeSkipResult({
    required this.event,
    required this.summary,
    required this.fromClock,
    required this.toClock,
    required this.decisions,
    required this.notifications,
  });

  final Event event;
  final String summary;
  final int fromClock;
  final int toClock;
  final List<DeltaDecision> decisions;
  final List<String> notifications;
}

class TimeSkipGenerator {
  TimeSkipGenerator(
    this.repo, {
    this.config = const EngineConfig(),
    this.maxOpsPerSection = 8,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final WorldRepository repo;
  final EngineConfig config;

  /// "Bounded" proposed deltas (§4.6.3): ops beyond this per section are
  /// rejected before validation.
  final int maxOpsPerSection;
  final DateTime Function() _clock;

  int resolveTargetClock({
    required WorldProjection projection,
    required String characterId,
    required TimeSkipTarget target,
  }) {
    switch (target) {
      case TimeSkipTarget.latestWorldClock:
        return projection.worldClock;
      case TimeSkipTarget.afterLastSharedEvent:
        final shared = projection.sharedEventsFor(characterId);
        return shared.isEmpty
            ? projection.characters[characterId]!.subjectiveClock
            : shared.last.atClock;
    }
  }

  /// Build the retrospective prompt: window, anchors (fixed SharedEvents),
  /// character state, active quests.
  String buildPrompt({
    required WorldProjection projection,
    required String characterId,
    required int targetClock,
  }) {
    final c = projection.characters[characterId]!;
    final anchors = [
      for (final s in projection.sharedEventsFor(characterId))
        if (s.atClock > c.subjectiveClock && s.atClock <= targetClock) s
    ];
    final b = StringBuffer()
      ..writeln('Write a retrospective of what ${c.name} did between their '
          'minute ${c.subjectiveClock} and minute $targetClock.')
      ..writeln('Their current sheet: ${jsonEncode(c.toJson())}');
    if (anchors.isNotEmpty) {
      b.writeln('FIXED CANON — these shared events happened in this window '
          'and are non-negotiable; the retrospective must be consistent '
          'with each:');
      for (final a in anchors) {
        b.writeln('- minute ${a.atClock}: ${a.summary}');
      }
    }
    b
      ..writeln('Respond with strict JSON: {"summary": "...", '
          '"proposed_deltas": { "stats": [...], "status": [...], '
          '"inventory": [...], "relationships": [...], "quest": [...] }}')
      ..writeln('Deltas use the standard turn contract and must be modest — '
          'this is downtime, not an adventure. No more than '
          '$maxOpsPerSection ops per section.');
    return b.toString();
  }

  /// Full pipeline: prompt → LLM → bound → validate (non-lethal) → commit
  /// one TimeSkip event.
  Future<TimeSkipResult> run({
    required String characterId,
    required TimeSkipTarget target,
    required LlmClient llm,
    RendezvousService? rendezvous,
  }) async {
    final projection = await repo.projection();
    final world = projection.world;
    if (world == null) throw StateError('time-skip: no world');
    final character = projection.characters[characterId];
    if (character == null) {
      throw ArgumentError('time-skip: unknown character $characterId');
    }
    if (!character.alive) {
      throw StateError('time-skip: ${character.name} is dead');
    }

    final targetClock = resolveTargetClock(
        projection: projection, characterId: characterId, target: target);
    if (targetClock <= character.subjectiveClock) {
      throw StateError('time-skip: target minute $targetClock is not after '
          '${character.name}\'s clock (${character.subjectiveClock})');
    }

    final raw = await llm.complete(
      systemPrompt: 'You are the retrospective generator for a life-sim world. '
          'You narrate downtime between play sessions. Strict JSON only.',
      prompt: buildPrompt(
          projection: projection,
          characterId: characterId,
          targetClock: targetClock),
      expectJson: true,
    );
    final parsed = _parseRetrospective(raw);
    final summary = parsed.$1;
    final bounded = _bound(parsed.$2);

    // Normal engine validation, non-lethal, clock uncapped to reach target.
    final engine = TurnEngine(config: config);
    final turn = engine.runTurn(
      projection: projection,
      input: TurnInput(
        actorId: characterId,
        userInput: '(time skip to minute $targetClock)',
        nonLethal: true,
        allowUncappedClock: true,
        output: TurnOutput(
          narrative: summary,
          proposedDeltas: ProposedDeltas(
            clockAdvanceMinutes: targetClock - character.subjectiveClock,
            inventory: bounded.inventory,
            stats: bounded.stats,
            status: bounded.status,
            relationships: bounded.relationships,
            quest: bounded.quest,
          ),
        ),
      ),
      now: _clock(),
      rawLlmJson: raw,
    );
    assert(!turn.died, 'time-skips are non-lethal by design (§4.6)');

    // Fold the validated turn's granular payloads into ONE TimeSkip event.
    final deltas = <Map<String, Object?>>[];
    for (final e in turn.events) {
      final kind = switch (e.type) {
        EventType.statChanged => 'stat',
        EventType.statusChanged => 'status',
        EventType.itemGranted => 'item_granted',
        EventType.itemRemoved => 'item_removed',
        EventType.relationshipChanged => 'relationship',
        EventType.questProgressed => 'quest',
        _ => null,
      };
      if (kind != null) deltas.add({'kind': kind, ...e.payload});
    }

    final seq = await repo.lastSeq() + 1;
    final event = Event(
      id: 'evt-$seq',
      worldId: world.id,
      seq: seq,
      timeline: characterId,
      subjectiveClock: targetClock,
      type: EventType.timeSkip,
      payload: {
        'char_id': characterId,
        'from_clock': character.subjectiveClock,
        'to_clock': targetClock,
        'summary': summary,
        'target_mode': target.name,
        'deltas': deltas,
      },
      cause: {
        'llm_raw_ref': raw,
        'debug_report': turn.report.toJson(),
      },
      createdAt: _clock(),
    );
    await repo.appendEvent(event);

    return TimeSkipResult(
      event: event,
      summary: summary,
      fromClock: character.subjectiveClock,
      toClock: targetClock,
      decisions: turn.report.decisions,
      notifications: turn.notifications,
    );
  }

  (String, ProposedDeltas) _parseRetrospective(String raw) {
    var text = raw.trim();
    if (text.startsWith('```')) {
      text = text
          .replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '')
          .replaceFirst(RegExp(r'```\s*$'), '');
    }
    final json = jsonDecode(text) as Map<String, Object?>;
    final deltasJson =
        json['proposed_deltas'] as Map<String, Object?>? ?? const {};
    return (
      json['summary'] as String? ?? '',
      ProposedDeltas.fromJson(deltasJson),
    );
  }

  ProposedDeltas _bound(ProposedDeltas d) => ProposedDeltas(
        clockAdvanceMinutes: 0, // clock is set by the generator, not the LLM
        inventory: d.inventory.take(maxOpsPerSection).toList(),
        stats: d.stats.take(maxOpsPerSection).toList(),
        status: d.status.take(maxOpsPerSection).toList(),
        relationships: d.relationships.take(maxOpsPerSection).toList(),
        quest: d.quest.take(maxOpsPerSection).toList(),
      );
}
