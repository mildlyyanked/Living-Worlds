/// Rolling summarization (§6): when verbatim history exceeds its slice,
/// oldest turns are folded into a running summary via its own async LLM
/// call, cached as a SummaryCached event. Experiment-gated behind a setting.
library;

import '../llm/llm_client.dart';
import '../model/event.dart';
import '../repo/world_repository.dart';

class RollingSummarizer {
  RollingSummarizer({
    required this.repo,
    required this.llm,
    this.keepVerbatim = 8,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final WorldRepository repo;
  final LlmClient llm;

  /// Turns kept verbatim; older ones are folded into the summary.
  final int keepVerbatim;
  final DateTime Function() _clock;

  /// True when [timeline] has more history than its verbatim slice and the
  /// cached summary is stale.
  Future<bool> needsSummarization(String timeline) async {
    final p = await repo.projection();
    final turns = p.turnsFor(timeline);
    if (turns.length <= keepVerbatim) return false;
    final cutoff = turns[turns.length - keepVerbatim - 1].seq;
    final cached = p.summaries[timeline];
    return cached == null || cached.uptoSeq < cutoff;
  }

  /// Fold old turns into the running summary and cache it as an event.
  /// Non-blocking by design: call after a turn commits, off the hot path
  /// (§5.2's pattern).
  Future<Event?> summarize(String timeline) async {
    final p = await repo.projection();
    final turns = p.turnsFor(timeline);
    if (turns.length <= keepVerbatim) return null;

    final old = turns.sublist(0, turns.length - keepVerbatim);
    final cached = p.summaries[timeline];
    final unsummarized = [
      for (final t in old)
        if (cached == null || t.seq > cached.uptoSeq) t
    ];
    if (unsummarized.isEmpty) return null;

    final prompt = StringBuffer();
    if (cached != null) {
      prompt.writeln('RUNNING SUMMARY SO FAR:\n${cached.summary}\n');
    }
    prompt.writeln('FOLD IN THESE OLDER TURNS (keep names, injuries, debts, '
        'promises, discoveries; drop color):');
    for (final t in unsummarized) {
      prompt
        ..writeln('> ${t.userInput}')
        ..writeln(t.narrative);
    }

    final summary = await llm.complete(
      systemPrompt: 'You maintain a compact running summary of a character\'s '
          'story so far. Output plain prose, max ~200 words.',
      prompt: prompt.toString(),
    );

    final seq = await repo.lastSeq() + 1;
    final event = Event(
      id: 'evt-$seq',
      worldId: p.world!.id,
      seq: seq,
      timeline: timeline,
      subjectiveClock: p.characters[timeline]?.subjectiveClock ?? 0,
      type: EventType.summaryCached,
      payload: {
        'timeline': timeline,
        'upto_seq': old.last.seq,
        'summary': summary,
      },
      createdAt: _clock(),
    );
    await repo.appendEvent(event);
    return event;
  }
}
