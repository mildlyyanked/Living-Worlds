/// Shared test fixtures: a standard world with two characters, item defs,
/// and a quest — the stage every suite plays on.
library;

import 'package:living_worlds_engine/living_worlds_engine.dart';

final DateTime t0 = DateTime.utc(2026, 1, 1);

DateTime Function() fixedClock([DateTime? at]) => () => at ?? t0;

World testWorld({int seed = 42}) => World(
      id: 'world-1',
      name: 'Testhaven',
      seed: seed,
      createdAt: t0,
      schema: WorldSchema.standard(),
    );

Character ash() => const Character(
      id: 'ash',
      worldId: 'world-1',
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
            stats: [QuestRewardStat(key: 'coin', delta: 25)],
          ),
        ),
      ],
    );

Character brynn() => const Character(
      id: 'brynn',
      worldId: 'world-1',
      name: 'Brynn',
      bio: 'A smuggler with a code.',
      stats: {'vitality': 100, 'hunger': 0, 'fatigue': 0, 'coin': 40},
    );

List<ItemDef> testItems() => const [
      ItemDef(
        id: 'item-rusty-key',
        worldId: 'world-1',
        name: 'rusty key',
        desc: 'Opens something old.',
        affordances: ['unlock'],
        consumable: false,
        stackable: false,
      ),
      ItemDef(
        id: 'item-potion',
        worldId: 'world-1',
        name: 'healing potion',
        desc: 'Restores vigor and staunches wounds.',
        affordances: ['heal'],
        effects: [
          ItemEffect(onUse: 'heal', statusKey: 'bleeding', statusOp: 'remove'),
          ItemEffect(onUse: 'heal', statKey: 'fatigue', statDelta: -20),
        ],
        consumable: true,
      ),
      ItemDef(
        id: 'item-lantern',
        worldId: 'world-1',
        name: 'storm lantern',
        desc: 'Sheds light in dark places.',
        affordances: ['light'],
      ),
    ];

/// Build a repository seeded with world, both characters, and item defs.
Future<T> seededRepo<T extends WorldRepository>(T repo) async {
  final service = WorldService(repo, clock: fixedClock());
  await service.createWorld(testWorld());
  await service.createCharacter(ash());
  await service.createCharacter(brynn());
  for (final def in testItems()) {
    await service.createItemDef(def);
  }
  return repo;
}

/// A quiet, harmless turn output.
TurnOutput calmTurn({String narrative = 'You walk on.', int minutes = 30}) =>
    TurnOutput(
      narrative: narrative,
      proposedDeltas: ProposedDeltas(clockAdvanceMinutes: minutes),
    );
