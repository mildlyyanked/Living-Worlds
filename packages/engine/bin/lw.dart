/// Living Worlds CLI harness — headless observability for the build.
///
///   dart run living_worlds_engine:lw demo [--db path] [--verbose]
///   dart run living_worlds_engine:lw inspect DB [--events] [--turn N]
///   dart run living_worlds_engine:lw replay DB     # verify replay==live
///   dart run living_worlds_engine:lw play DB       # interactive (needs
///                                                  # OPENROUTER_API_KEY)
///
/// `demo` drives the REAL engine through a scripted fixture playthrough that
/// exercises every subsystem (peril, items, quests, meeting/SharedEvent,
/// time-skip, wiki candidates) and prints the full turn transaction:
/// decisions, death eval, context sections, cost — exactly what the in-app
/// debug panel shows (§9).
library;

import 'dart:convert';
import 'dart:io';

import 'package:living_worlds_engine/living_worlds_engine.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    _usage();
    exit(64);
  }
  switch (args.first) {
    case 'demo':
      await _demo(args.skip(1).toList());
    case 'inspect':
      await _inspect(args.skip(1).toList());
    case 'replay':
      await _replay(args.skip(1).toList());
    case 'play':
      await _play(args.skip(1).toList());
    default:
      _usage();
      exit(64);
  }
}

void _usage() {
  stdout.writeln('Living Worlds engine harness.\n'
      'Commands:\n'
      '  demo [--db PATH] [--verbose]   scripted full-subsystem playthrough\n'
      '  inspect DB [--events] [--turn SEQ]\n'
      '  replay DB                      verify replay(log) == projection\n'
      '  play DB [--actor ID] [--model M]  interactive turns via OpenRouter');
}

String? _flagValue(List<String> args, String flag) {
  final i = args.indexOf(flag);
  if (i < 0 || i + 1 >= args.length) return null;
  return args[i + 1];
}

// ---------------------------------------------------------------- demo ----

Future<void> _demo(List<String> args) async {
  final dbPath = _flagValue(args, '--db');
  final verbose = args.contains('--verbose');
  final repo = dbPath == null
      ? InMemoryRepository()
      : LocalRepository.open(dbPath) as WorldRepository;

  final service = WorldService(repo);
  await service.createWorld(World(
    id: 'world-demo',
    name: 'Harborfall',
    seed: 42,
    createdAt: DateTime.now().toUtc(),
    schema: WorldSchema.standard(),
  ));
  await service.createCharacter(const Character(
    id: 'ash',
    worldId: 'world-demo',
    name: 'Ash',
    bio: 'A wandering cartographer.',
    stats: {'vitality': 100, 'hunger': 0, 'fatigue': 0, 'coin': 10},
    quests: [
      Quest(
        id: 'q-map',
        title: 'Map the Sunken Vault',
        steps: [
          QuestStep(id: 's1', desc: 'Find the vault entrance'),
          QuestStep(id: 's2', desc: 'Sketch the inner chambers'),
        ],
        reward: QuestReward(
            itemDefIds: ['item-lantern'],
            stats: [QuestRewardStat(key: 'coin', delta: 25)]),
      ),
    ],
  ));
  await service.createCharacter(const Character(
    id: 'brynn',
    worldId: 'world-demo',
    name: 'Brynn',
    bio: 'A smuggler with a code.',
    stats: {'vitality': 100, 'hunger': 0, 'fatigue': 0, 'coin': 40},
  ));
  for (final def in const [
    ItemDef(
        id: 'item-rusty-key',
        worldId: 'world-demo',
        name: 'rusty key',
        desc: 'Opens something old.',
        affordances: ['unlock'],
        stackable: false),
    ItemDef(
        id: 'item-potion',
        worldId: 'world-demo',
        name: 'healing potion',
        desc: 'Staunches wounds.',
        affordances: ['heal'],
        effects: [
          ItemEffect(onUse: 'heal', statusKey: 'bleeding', statusOp: 'remove')
        ],
        consumable: true),
    ItemDef(
        id: 'item-lantern',
        worldId: 'world-demo',
        name: 'storm lantern',
        desc: 'Light in dark places.',
        affordances: ['light']),
  ]) {
    await service.createItemDef(def);
  }
  await service.createWikiEntry(WikiEntry(
      id: 'wiki-gullet',
      worldId: 'world-demo',
      title: 'The Gullet',
      category: 'Places',
      body: 'A drowned smuggling tunnel beneath Harborfall.'));

  final embedder = FixtureEmbeddingClient();
  final p0 = await repo.projection();
  for (final w in p0.wiki.values) {
    await repo.saveEmbedding(w.id, await embedder.embed(w.body));
  }

  final script = <(String, TurnOutput)>[
    (
      'search the tide pools below the vault',
      const TurnOutput(
        narrative: 'Wedged in the silt: a rusty key, and a shallow gash '
            'across your palm for the trouble.',
        proposedDeltas: ProposedDeltas(
          clockAdvanceMinutes: 40,
          inventory: [InventoryOp(op: InventoryOpKind.grant, item: 'rusty key')],
          status: [StatusOp(op: StatusOpKind.add, key: 'bleeding', severity: 1)],
        ),
        peril: true,
        wikiCandidates: [
          WikiCandidate(
              id: '',
              title: 'The Sunken Vault',
              category: 'Places',
              body: 'A flooded vault below the tide pools; opens to old iron.')
        ],
      )
    ),
    (
      'unlock the vault door',
      const TurnOutput(
        narrative: 'The key grinds; the door yields. You have found the '
            'entrance.',
        proposedDeltas: ProposedDeltas(
          clockAdvanceMinutes: 15,
          inventory: [InventoryOp(op: InventoryOpKind.use, item: 'rusty key')],
          quest: [
            QuestOp(questId: 'q-map', op: QuestOpKind.progress, stepId: 's1')
          ],
        ),
      )
    ),
    (
      'sketch the chambers, then head to the tavern',
      const TurnOutput(
        narrative: 'Charcoal on vellum until the light dies. At the tavern, '
            'Brynn raises a glass to your soaked boots.',
        proposedDeltas: ProposedDeltas(
          clockAdvanceMinutes: 200,
          quest: [
            QuestOp(questId: 'q-map', op: QuestOpKind.progress, stepId: 's2')
          ],
          relationships: [
            RelationshipOp(to: 'brynn', dim: 'respect', delta: 2)
          ],
          stats: [StatOp(key: 'fatigue', op: StatOpKind.delta, value: 30)],
        ),
      )
    ),
  ];

  final controller = TurnController(
    repo: repo,
    llm: FixtureLlmClient(turnOutputs: [for (final s in script) s.$2]),
    embedder: embedder,
  );

  stdout.writeln('=== Living Worlds demo: Harborfall (seed 42) ===\n');
  for (final (input, _) in script) {
    final turn = await controller.playTurn(
        actorId: 'ash',
        userInput: input,
        presentCharacterIds: input.contains('tavern') ? ['brynn'] : const []);
    _printTurn(input, turn, verbose: verbose);
  }

  // Meeting canon: first-writer-wins.
  final rendezvous = RendezvousService(repo);
  final pMeet = await repo.projection();
  await rendezvous.commitSharedEvent(
    projection: pMeet,
    writerId: 'ash',
    participants: ['ash', 'brynn'],
    summary: 'Ash and Brynn agreed to split the vault haul at dawn.',
  );
  stdout.writeln('-- SharedEvent committed: "split the vault haul at dawn" '
      '(canon for both timelines)\n');

  // Time-skip Brynn to the world clock.
  final skipLlm = FixtureLlmClient(completions: [
    jsonEncode({
      'summary': 'Brynn worked the docks, ears open, and kept the meeting '
          'at dawn in mind.',
      'proposed_deltas': {
        'stats': [
          {'key': 'coin', 'op': 'delta', 'value': 8, 'reason': 'dock work'}
        ]
      },
    })
  ]);
  final skip = await TimeSkipGenerator(repo).run(
      characterId: 'brynn',
      target: TimeSkipTarget.latestWorldClock,
      llm: skipLlm);
  stdout.writeln('-- TimeSkip: Brynn ${skip.fromClock} -> ${skip.toClock} min '
      '(non-lethal): ${skip.summary}\n');

  final p = await repo.projection();
  _printProjection(p);
  final agg = controller.costLog.aggregate();
  stdout.writeln('\nCOST: ${jsonEncode(agg.toJson())}');
  await repo.close();
}

void _printTurn(String input, CommittedTurn turn, {required bool verbose}) {
  stdout
    ..writeln('> $input')
    ..writeln(turn.narrative)
    ..writeln('  [${turn.notifications.join('] [')}]');
  final eval = turn.report.deathEval;
  if (eval != null) {
    stdout.writeln('  death eval: health=${eval.health.toStringAsFixed(1)} '
        'P=${eval.probability.toStringAsFixed(4)} draw=${eval.draw.toStringAsFixed(4)} '
        '=> ${eval.outcome ? 'DEAD' : 'alive'}'
        '${eval.instantTrigger != null ? ' (instant: ${eval.instantTrigger})' : ''}');
  }
  if (verbose) {
    for (final d in turn.report.decisions) {
      stdout.writeln('  delta[${d.section}] ${d.outcome.name}'
          '${d.outcome == DeltaOutcome.clamped ? ' ${d.from}->${d.to}' : ''}'
          '${d.reason.isNotEmpty ? ' (${d.reason})' : ''}');
    }
    for (final s in turn.report.contextSections) {
      stdout.writeln('  ctx ${s.section}: ${s.tokens} tok'
          '${s.included ? '' : ' (dropped)'}');
    }
  }
  stdout.writeln('');
}

void _printProjection(WorldProjection p) {
  stdout.writeln('=== World state (seq ${p.lastSeq}, world clock '
      '${p.worldClock} min) ===');
  for (final c in p.characters.values) {
    final schema = p.world!.schema;
    stdout.writeln(
        '${c.name}: clock=${c.subjectiveClock} alive=${c.alive} '
        'health=${healthOf(c, schema, const EngineConfig()).toStringAsFixed(0)} '
        'stats=${jsonEncode(c.stats)}');
    if (c.status.isNotEmpty) {
      stdout.writeln(
          '  status: ${c.status.map((s) => '${s.key}(${s.severity})').join(', ')}');
    }
    if (c.inventory.isNotEmpty) {
      stdout.writeln('  inventory: ${c.inventory.map((i) {
        final def = p.itemDefs[i.defId];
        return '${def?.name ?? i.defId} x${i.qty}';
      }).join(', ')}');
    }
    for (final q in c.quests) {
      stdout.writeln('  quest "${q.title}": ${q.state.name} '
          '(${q.steps.where((s) => s.done).length}/${q.steps.length} steps)');
    }
  }
  for (final e in p.edges.values) {
    stdout.writeln('edge ${e.fromChar} -> ${e.toChar}: ${jsonEncode(e.dims)}');
  }
  for (final s in p.sharedEvents) {
    stdout.writeln('shared@${s.atClock}min ${s.participants.join('+')}: '
        '${s.summary}');
  }
  if (p.pendingCandidates.isNotEmpty) {
    stdout.writeln('pending wiki candidates: '
        '${p.pendingCandidates.values.map((c) => c.title).join(', ')}');
  }
  stdout.writeln(
      'wiki: ${p.wiki.values.map((w) => '${w.title} v${w.version}').join(', ')}');
}

// ------------------------------------------------------------- inspect ----

Future<void> _inspect(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('inspect: missing DB path');
    exit(64);
  }
  final repo = LocalRepository.open(args.first);
  final showEvents = args.contains('--events');
  final turnSeq = _flagValue(args, '--turn');

  final p = await repo.projection();
  _printProjection(p);

  if (showEvents) {
    stdout.writeln('\n=== Event log ===');
    final reverted = await repo.revertedSeqs();
    for (final e in await repo.eventsUpTo(-1)) {
      stdout.writeln('${e.seq.toString().padLeft(4)} '
          '${reverted.contains(e.seq) ? 'REVERTED ' : ''}'
          '${e.type.name.padRight(22)} ${e.timeline.padRight(8)} '
          '@${e.subjectiveClock}min ${jsonEncode(e.payload).length} bytes');
    }
  }

  if (turnSeq != null) {
    final events = await repo.eventsUpTo(-1);
    final turn = events.firstWhere(
        (e) => e.seq == int.parse(turnSeq) && e.type == EventType.turnCommitted,
        orElse: () => throw StateError('no TurnCommitted at seq $turnSeq'));
    stdout.writeln('\n=== TurnDebugReport for seq $turnSeq (§9) ===');
    stdout.writeln(const JsonEncoder.withIndent('  ')
        .convert(turn.cause['debug_report']));
  }
  await repo.close();
}

// -------------------------------------------------------------- replay ----

Future<void> _replay(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('replay: missing DB path');
    exit(64);
  }
  final repo = LocalRepository.open(args.first);
  final live = await repo.projection();
  final replayed = WorldProjection.replay(await repo.eventsUpTo(-1),
      revertedSeqs: await repo.revertedSeqs());
  // Embeddings live outside the log; compare the log-derived state only.
  final a = jsonEncode(live.toJson());
  final b = jsonEncode(replayed.toJson());
  if (_stripEmbeddings(a) == _stripEmbeddings(b)) {
    stdout.writeln('OK: replay(log) == projection '
        '(${replayed.lastSeq + 1} events)');
  } else {
    stderr.writeln('MISMATCH: replay(log) != projection');
    exit(1);
  }
  await repo.close();
}

String _stripEmbeddings(String json) =>
    json.replaceAll(RegExp(r'"embedding":\[[^\]]*\]'), '"embedding":null');

// ---------------------------------------------------------------- play ----

Future<void> _play(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('play: missing DB path');
    exit(64);
  }
  final key = Platform.environment['OPENROUTER_API_KEY'];
  if (key == null || key.isEmpty) {
    stderr.writeln('play: set OPENROUTER_API_KEY (dev-only direct path, §7)');
    exit(78);
  }
  final repo = LocalRepository.open(args.first);
  final p = await repo.projection();
  if (p.world == null) {
    stderr.writeln('play: DB has no world; run demo --db first');
    exit(66);
  }
  final actor = _flagValue(args, '--actor') ?? p.characters.keys.first;
  final model = _flagValue(args, '--model') ?? 'anthropic/claude-sonnet-4.5';

  final controller = TurnController(
    repo: repo,
    llm: OpenRouterLlmClient(
        baseUrl: 'https://openrouter.ai/api/v1', apiKey: key, model: model),
    embedder: OpenRouterEmbeddingClient(
        baseUrl: 'https://openrouter.ai/api/v1', apiKey: key),
  );

  stdout.writeln('Playing ${p.characters[actor]?.name ?? actor} in '
      '${p.world!.name} via $model. Empty line quits.');
  while (true) {
    stdout.write('\n> ');
    final input = stdin.readLineSync();
    if (input == null || input.trim().isEmpty) break;
    final turn = await controller.playTurn(actorId: actor, userInput: input);
    _printTurn(input, turn, verbose: true);
    final usage = turn.report.usage;
    stdout.writeln('  cost: \$${usage.computedCostUsd.toStringAsFixed(4)} '
        '(${usage.promptTokens}+${usage.completionTokens} tok, '
        '${usage.latencyMs} ms)');
    if (turn.died) {
      stdout.writeln('${p.characters[actor]?.name} has died. '
          'Timeline frozen (undo to continue).');
      break;
    }
  }
  await repo.close();
}
