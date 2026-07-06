import 'package:living_worlds_engine/living_worlds_engine.dart';
import 'package:test/test.dart';

import 'helpers/fixtures.dart';

void main() {
  final schema = WorldSchema.standard();
  const config = EngineConfig();

  Character char({
    Map<String, double> stats = const {'vitality': 100},
    List<StatusInstance> status = const [],
    int clock = 0,
  }) =>
      Character(
        id: 'c',
        worldId: 'w',
        name: 'C',
        stats: stats,
        status: status,
        subjectiveClock: clock,
      );

  group('healthOf', () {
    test('full vitality, no statuses => 100', () {
      expect(healthOf(char(), schema, config), 100);
    });

    test('injury subtracts severity * weight', () {
      // bleeding weight 8, severity 2 => 100 - 16 = 84
      final c = char(status: [
        const StatusInstance(key: 'bleeding', severity: 2, sinceClock: 0)
      ]);
      expect(healthOf(c, schema, config), 84);
    });

    test('hunger/fatigue stats subtract value * weight', () {
      // hunger 40 * 0.25 + fatigue 20 * 0.25 = 15
      final c = char(stats: {'vitality': 100, 'hunger': 40, 'fatigue': 20});
      expect(healthOf(c, schema, config), 85);
    });

    test('buffs (negative weight) add health', () {
      // injured (10*3=30) then blessed (-8): 100-30+8 = 78
      final c = char(status: [
        const StatusInstance(key: 'injured', severity: 3, sinceClock: 0),
        const StatusInstance(key: 'blessed', severity: 1, sinceClock: 0),
      ]);
      expect(healthOf(c, schema, config), 78);
    });

    test('clamps to 0 at the bottom', () {
      final c = char(status: [
        const StatusInstance(key: 'injured', severity: 50, sinceClock: 0)
      ]);
      expect(healthOf(c, schema, config), 0);
    });

    test('clamps to 100 at the top (buff cannot exceed)', () {
      final c = char(status: [
        const StatusInstance(key: 'blessed', severity: 5, sinceClock: 0)
      ]);
      expect(healthOf(c, schema, config), 100);
    });

    test('unknown status keys are ignored', () {
      final c = char(status: [
        const StatusInstance(key: 'nonsense', severity: 9, sinceClock: 0)
      ]);
      expect(healthOf(c, schema, config), 100);
    });

    test('missing vitality stat falls back to default base', () {
      final c = char(stats: const {});
      expect(healthOf(c, schema, config), 100);
    });

    test('health is always within [0,100] across a severity sweep', () {
      for (var severity = 0.0; severity <= 60; severity += 1.5) {
        final c = char(status: [
          StatusInstance(key: 'injured', severity: severity, sinceClock: 0)
        ]);
        final h = healthOf(c, schema, config);
        expect(h, inInclusiveRange(0, 100));
      }
    });
  });

  group('status decay (§4.2)', () {
    test('severity decays per minute from since_clock', () {
      // bleeding decays 0.02/min: severity 2 at minute 0 -> 1 at minute 50.
      const s = StatusInstance(key: 'bleeding', severity: 2, sinceClock: 0);
      final def = schema.statusDef('bleeding');
      expect(effectiveSeverity(s, def, 0), 2);
      expect(effectiveSeverity(s, def, 50), closeTo(1, 1e-9));
      expect(effectiveSeverity(s, def, 100), closeTo(0, 1e-9));
      expect(effectiveSeverity(s, def, 500), 0); // never negative
    });

    test('no decay defined => severity constant', () {
      const s = StatusInstance(key: 'injured', severity: 3, sinceClock: 0);
      expect(effectiveSeverity(s, schema.statusDef('injured'), 10000), 3);
    });

    test('statusExpired flips once fully decayed', () {
      const s = StatusInstance(key: 'bleeding', severity: 1, sinceClock: 0);
      final def = schema.statusDef('bleeding');
      expect(statusExpired(s, def, 0), isFalse);
      expect(statusExpired(s, def, 49), isFalse);
      expect(statusExpired(s, def, 50), isTrue);
    });

    test('decayed severity feeds health', () {
      final c = char(
        status: [
          const StatusInstance(key: 'bleeding', severity: 2, sinceClock: 0)
        ],
        clock: 50,
      );
      // effective severity 1 * weight 8 => 92
      expect(healthOf(c, schema, config), 92);
    });
  });

  group('fixtures sanity', () {
    test('standard schema has the dims and categories tests rely on', () {
      expect(schema.relationshipDims, contains('trust'));
      expect(schema.wikiCategories, contains('Places'));
      expect(testItems().map((i) => i.id), contains('item-potion'));
    });
  });
}
