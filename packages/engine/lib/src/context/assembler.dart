/// Context budget & summarization (§6).
///
/// Hard token budget per turn; sections filled by priority:
/// sheet (always) > clock/status/inventory > active quests > relationship
/// snapshot of present chars > recent turns verbatim > wiki index >
/// semantic wiki bodies > rolling summary of old turns.
/// The debug report gets per-section token counts so pollution/overflow is
/// visible (§9).
library;

import 'dart:convert';

import '../debug/report.dart';
import '../engine/config.dart';
import '../engine/health.dart';
import '../model/character.dart';
import '../model/quest.dart';
import '../model/wiki.dart';
import '../projection/projection.dart';

/// Cheap deterministic token estimate: ~4 chars per token. Good enough for
/// budgeting; the real counts come back in usage stats (§10).
int estimateTokens(String text) => (text.length / 4).ceil();

class AssembledContext {
  const AssembledContext({required this.text, required this.sections});

  final String text;
  final List<ContextSectionReport> sections;

  int get totalTokens =>
      sections.where((s) => s.included).fold(0, (t, s) => t + s.tokens);
}

class ContextAssembler {
  const ContextAssembler({
    this.budgetTokens = 6000,
    this.recentTurnsVerbatim = 5,
    this.config = const EngineConfig(),
  });

  final int budgetTokens;
  final int recentTurnsVerbatim;
  final EngineConfig config;

  AssembledContext assemble({
    required WorldProjection projection,
    required String actorId,

    /// Cameo/canon blocks from the rendezvous service, already rendered.
    List<String> cameoBlocks = const [],

    /// Fixed shared-event canon the actor must narrate around (§4.4).
    List<SharedEventRecord> fixedCanon = const [],

    /// Semantic top-k bodies, already retrieved (§5.3.2).
    List<WikiEntry> semanticEntries = const [],
    String retrievalDetail = '',
  }) {
    final actor = projection.characters[actorId];
    if (actor == null) {
      throw ArgumentError('assemble: unknown actor $actorId');
    }

    final reports = <ContextSectionReport>[];
    final included = <String>[];
    var remaining = budgetTokens;

    // Returns true when the section was included.
    bool add(String name, String body,
        {bool always = false, String detail = ''}) {
      final tokens = estimateTokens(body);
      final fits = always || tokens <= remaining;
      reports.add(ContextSectionReport(
          section: name, tokens: tokens, included: fits, detail: detail));
      if (fits) {
        included.add(body);
        remaining -= tokens;
        if (remaining < 0) remaining = 0;
      }
      return fits;
    }

    // 1. Character sheet — always.
    add('character_sheet', _sheet(actor, projection), always: true);

    // 2. Clock / status / inventory with affordances — always.
    add('clock_status_inventory', _vitals(actor, projection), always: true);

    // 3. Active quests.
    final quests = [
      for (final q in actor.quests)
        if (q.state == QuestState.active && !q.hidden) q
    ];
    if (quests.isNotEmpty) {
      add('active_quests', _quests(quests));
    }

    // 4. Relationship snapshot of present characters + cameo blocks.
    final relBlock = _relationships(actor, projection, cameoBlocks);
    if (relBlock.isNotEmpty) add('relationships_present', relBlock);

    // 4b. Fixed canon (first-writer-wins, §4.4) — must not be dropped.
    if (fixedCanon.isNotEmpty) {
      add('fixed_canon', _canon(fixedCanon), always: true);
    }

    // 4c. Key beats — a cheap deterministic digest of durable milestones
    // (quest outcomes, deaths) so they survive even when the verbatim window
    // is small (§6 condensation). No LLM cost.
    final beats = _keyBeats(actor, projection);
    if (beats.isNotEmpty) add('key_beats', beats, always: true);

    // 5. Recent turns verbatim.
    final turns = projection.turnsFor(actorId);
    final recent = turns.length <= recentTurnsVerbatim
        ? turns
        : turns.sublist(turns.length - recentTurnsVerbatim);
    if (recent.isNotEmpty) {
      add('recent_turns', _turns(recent),
          detail: '${recent.length} of ${turns.length} turns verbatim');
    }

    // 6. Wiki index — compact {title, category, one-liner} of everything.
    if (projection.wiki.isNotEmpty) {
      add('wiki_index', _wikiIndex(projection),
          detail: '${projection.wiki.length} entries');
    }

    // 7. Semantic wiki bodies.
    if (semanticEntries.isNotEmpty) {
      add('semantic_wiki', _wikiBodies(semanticEntries),
          detail: retrievalDetail);
    }

    // 8. Rolling summary of older turns.
    final summary = projection.summaries[actorId];
    if (summary != null && recent.length < turns.length) {
      add('rolling_summary', 'EARLIER (summarized): ${summary.summary}');
    }

    return AssembledContext(text: included.join('\n\n'), sections: reports);
  }

  String _sheet(Character c, WorldProjection p) {
    final schema = p.world!.schema;
    final b = StringBuffer()
      ..writeln('CHARACTER: ${c.name}')
      ..writeln('bio: ${c.bio}')
      ..writeln('stats: ${jsonEncode(c.stats)}')
      ..writeln('derived health: '
          '${healthOf(c, schema, config).toStringAsFixed(0)}/100')
      ..writeln('alive: ${c.alive}');
    return b.toString().trimRight();
  }

  String _vitals(Character c, WorldProjection p) {
    final schema = p.world!.schema;
    final b = StringBuffer()
      ..writeln('SUBJECTIVE CLOCK: minute ${c.subjectiveClock} '
          '(world clock: minute ${p.worldClock})');
    if (c.status.isEmpty) {
      b.writeln('status: none');
    } else {
      b.writeln('status:');
      for (final s in c.status) {
        final def = schema.statusDef(s.key);
        final eff = effectiveSeverity(s, def, c.subjectiveClock);
        b.writeln('  - ${def?.label ?? s.key} '
            '(severity ${eff.toStringAsFixed(1)})');
      }
    }
    if (c.inventory.isEmpty) {
      b.writeln('inventory: empty');
    } else {
      b.writeln('inventory (with affordances — verbs you may narrate):');
      for (final i in c.inventory) {
        final def = p.itemDefs[i.defId];
        b.writeln('  - ${def?.name ?? i.defId} x${i.qty}'
            '${def != null && def.affordances.isNotEmpty ? ' [enables: ${def.affordances.join(', ')}]' : ''}');
      }
    }
    return b.toString().trimRight();
  }

  String _keyBeats(Character actor, WorldProjection p) {
    final beats = <String>[];
    for (final q in actor.quests) {
      if (q.state == QuestState.complete) {
        beats.add('completed quest "${q.title}"');
      } else if (q.state == QuestState.failed) {
        beats.add('failed quest "${q.title}"');
      }
    }
    for (final c in p.characters.values) {
      if (!c.alive) beats.add('${c.name} has died');
    }
    if (beats.isEmpty) return '';
    final b = StringBuffer()..writeln('KEY BEATS SO FAR:');
    for (final beat in beats) {
      b.writeln('- $beat');
    }
    return b.toString().trimRight();
  }

  String _quests(List<Quest> quests) {
    final b = StringBuffer()..writeln('ACTIVE QUESTS:');
    for (final q in quests) {
      b.writeln('- ${q.title} (${q.id})');
      for (final s in q.steps) {
        b.writeln('  ${s.done ? '[x]' : '[ ]'} ${s.desc} (${s.id})');
      }
    }
    return b.toString().trimRight();
  }

  String _relationships(
      Character actor, WorldProjection p, List<String> cameoBlocks) {
    final b = StringBuffer();
    final lines = <String>[];
    for (final edge in p.edges.values) {
      if (edge.fromChar == actor.id || edge.toChar == actor.id) {
        final from = p.characters[edge.fromChar]?.name ?? edge.fromChar;
        final to = p.characters[edge.toChar]?.name ?? edge.toChar;
        lines.add('  $from -> $to: ${jsonEncode(edge.dims)}');
      }
    }
    if (lines.isNotEmpty) {
      b.writeln('RELATIONSHIPS:');
      lines.forEach(b.writeln);
    }
    for (final block in cameoBlocks) {
      b.writeln(block);
    }
    return b.toString().trimRight();
  }

  String _canon(List<SharedEventRecord> canon) {
    final b = StringBuffer()
      ..writeln('FIXED CANON (immutable shared events — narrate around '
          'these; they already happened and cannot be contradicted):');
    for (final s in canon) {
      b.writeln('- minute ${s.atClock}: ${s.summary}'
          '${s.detail.isNotEmpty ? ' — ${s.detail}' : ''}');
    }
    return b.toString().trimRight();
  }

  String _turns(List<TurnRecord> turns) {
    final b = StringBuffer()..writeln('RECENT TURNS:');
    for (final t in turns) {
      b
        ..writeln('> ${t.userInput}')
        ..writeln(t.narrative);
    }
    return b.toString().trimRight();
  }

  String _wikiIndex(WorldProjection p) {
    final b = StringBuffer()
      ..writeln('WIKI INDEX (query_wiki for full bodies):');
    final entries = p.wiki.values.toList()
      ..sort((a, b) => a.title.compareTo(b.title));
    for (final w in entries) {
      b.writeln('- ${w.summaryLine}');
    }
    return b.toString().trimRight();
  }

  String _wikiBodies(List<WikiEntry> entries) {
    final b = StringBuffer()..writeln('RELEVANT WIKI ENTRIES:');
    for (final w in entries) {
      b
        ..writeln('## ${w.title} [${w.category}]')
        ..writeln(w.body);
    }
    return b.toString().trimRight();
  }
}
