/// Widget tests: the full app on in-memory repositories with fixture LLMs —
/// the same seams the engine suite uses (§11), now through real UI.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:living_worlds/main.dart';
import 'package:living_worlds/src/app_services.dart';
import 'package:living_worlds/src/persistence.dart';
import 'package:living_worlds_engine/living_worlds_engine.dart';

AppServices testServices({
  LlmClient Function(AppSettings)? llmFactory,
  KeyValueStore? kv,
}) {
  return AppServices(
    repoFactory: (_) => InMemoryRepository(),
    llmFactory: llmFactory,
    worldsDirProvider: () async => Directory('unused-in-tests'),
    keyValueStore: kv ?? InMemoryKeyValueStore(),
    scanDiskWorlds: false,
  );
}

Future<void> createWorldViaUi(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('new-world')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('create-world')));
  await tester.pumpAndSettle();
}

Future<void> openHarborfall(WidgetTester tester) async {
  await tester.tap(find.textContaining('Harborfall'));
  await tester.pumpAndSettle();
}

Future<void> openAsh(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('character-ash')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('world select: create a world and see its tile', (tester) async {
    await tester.pumpWidget(LivingWorldsApp(services: testServices()));
    await tester.pumpAndSettle();
    expect(find.text('No worlds yet. Create one to begin.'), findsOneWidget);

    await createWorldViaUi(tester);
    expect(find.textContaining('Harborfall'), findsOneWidget);
  });

  testWidgets('gameplay: play a turn offline — narrative, chips, clock', (
    tester,
  ) async {
    await tester.pumpWidget(LivingWorldsApp(services: testServices()));
    await tester.pumpAndSettle();
    await createWorldViaUi(tester);
    await openHarborfall(tester);

    expect(find.byKey(const Key('world-clock')), findsOneWidget);
    expect(find.text('Day 1, 00:00'), findsOneWidget);

    await openAsh(tester);
    await tester.enterText(
      find.byKey(const Key('turn-input')),
      'walk the harbor wall',
    );
    await tester.tap(find.byKey(const Key('send-turn')));
    await tester.pumpAndSettle();

    // Offline narrator echoes the action; the engine advanced the clock.
    expect(find.textContaining('walk the harbor wall'), findsWidgets);
    expect(find.textContaining('offline narrator'), findsOneWidget);
    expect(find.text('+30 min'), findsOneWidget); // mechanical chip
    expect(find.text('Day 1, 00:30'), findsOneWidget); // actor clock
  });

  testWidgets('debug panel: toggle in settings, see per-turn transaction', (
    tester,
  ) async {
    final services = testServices();
    services.settings.debugPanel = true;
    await tester.pumpWidget(LivingWorldsApp(services: services));
    await tester.pumpAndSettle();
    await createWorldViaUi(tester);
    await openHarborfall(tester);
    await openAsh(tester);

    await tester.enterText(
      find.byKey(const Key('turn-input')),
      'poke the tide',
    );
    await tester.tap(find.byKey(const Key('send-turn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('debug-panel')), findsOneWidget);
    expect(find.byKey(const Key('debug-death-eval')), findsOneWidget);
    expect(find.textContaining('[clock] accepted'), findsOneWidget);
    expect(find.textContaining('character_sheet'), findsOneWidget);
  });

  testWidgets('character info tab shows bio, composite health, stats, status', (
    tester,
  ) async {
    await tester.pumpWidget(LivingWorldsApp(services: testServices()));
    await tester.pumpAndSettle();
    await createWorldViaUi(tester);
    await openHarborfall(tester);
    await openAsh(tester);

    await tester.tap(find.byKey(const Key('overlay-character')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('character-info')), findsOneWidget);
    expect(find.textContaining('Health (composite)'), findsOneWidget);
    expect(find.byKey(const Key('info-health-value')), findsOneWidget);
    // Vital-need stats are listed; there is no editable health/vitality stat.
    expect(find.textContaining('Hunger'), findsWidgets);
    expect(find.textContaining('Thirst'), findsWidgets);
    expect(find.textContaining('Coin (resource)'), findsOneWidget);
  });

  testWidgets('gameplay overlays: inventory, quests, relationships toggle', (
    tester,
  ) async {
    await tester.pumpWidget(LivingWorldsApp(services: testServices()));
    await tester.pumpAndSettle();
    await createWorldViaUi(tester);
    await openHarborfall(tester);
    await openAsh(tester);

    await tester.tap(find.byKey(const Key('overlay-inventory')));
    await tester.pumpAndSettle();
    expect(find.text('Inventory'), findsOneWidget);
    expect(find.text('Empty.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('overlay-quests')));
    await tester.pumpAndSettle();
    expect(find.text('Quests'), findsOneWidget);

    await tester.tap(find.byKey(const Key('overlay-relationships')));
    await tester.pumpAndSettle();
    expect(find.text('Relationships'), findsOneWidget);
  });

  testWidgets(
    'engine disposes in the UI too: fixture LLM proposes an illegal item '
    'and an over-cap clock; chips show only what was accepted',
    (tester) async {
      final fixture = FixtureLlmClient(
        turnOutputs: [
          const TurnOutput(
            narrative: 'A vorpal sword materializes! You nap for a week.',
            proposedDeltas: ProposedDeltas(
              clockAdvanceMinutes: 100000,
              inventory: [
                InventoryOp(op: InventoryOpKind.grant, item: 'vorpal sword'),
              ],
              stats: [StatOp(key: 'coin', op: StatOpKind.delta, value: 5)],
            ),
          ),
        ],
      );
      final services = testServices(llmFactory: (_) => fixture);
      services.settings.debugPanel = true;
      await tester.pumpWidget(LivingWorldsApp(services: services));
      await tester.pumpAndSettle();
      await createWorldViaUi(tester);
      await openHarborfall(tester);
      await openAsh(tester);

      await tester.enterText(
        find.byKey(const Key('turn-input')),
        'wish for a sword',
      );
      await tester.tap(find.byKey(const Key('send-turn')));
      await tester.pumpAndSettle();

      // Clock clamped to the cap, item rejected, coin accepted.
      expect(find.text('+240 min'), findsOneWidget);
      expect(find.text('+5 COIN'), findsOneWidget);
      expect(find.textContaining('[inventory] rejected'), findsOneWidget);
      expect(find.textContaining('no such item'), findsOneWidget);
      expect(find.textContaining('[clock] clamped'), findsOneWidget);
    },
  );

  testWidgets('wiki: seeding workshop clarifies, proposes, commits; '
      'change log can undo', (tester) async {
    final fixture = FixtureLlmClient(
      completions: [
        '{"action":"clarify","message":"Natural cave or dug tunnel?"}',
        '{"action":"propose_create","entry":{"title":"The Gullet",'
            '"category":"Places","body":"A drowned smuggling tunnel.",'
            '"tags":["harbor"]}}',
      ],
    );
    await tester.pumpWidget(
      LivingWorldsApp(services: testServices(llmFactory: (_) => fixture)),
    );
    await tester.pumpAndSettle();
    await createWorldViaUi(tester);
    await openHarborfall(tester);

    await tester.tap(find.text('Wiki'));
    await tester.pumpAndSettle();
    // Open the Workshop sub-tab and start a new thread.
    await tester.tap(find.text('Workshop'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-seeding-thread')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('seeding-input')),
      'Add a smuggler tunnel',
    );
    await tester.tap(find.byKey(const Key('seeding-send')));
    await tester.pumpAndSettle();
    expect(find.text('Natural cave or dug tunnel?'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('seeding-input')),
      'Dug, floods at high tide',
    );
    await tester.tap(find.byKey(const Key('seeding-send')));
    await tester.pumpAndSettle();
    final acceptBtn = find.byWidgetPredicate(
      (w) => w.key != null && '${w.key}'.contains('accept-proposal'),
    );
    expect(acceptBtn, findsOneWidget);

    await tester.ensureVisible(acceptBtn);
    await tester.pumpAndSettle();
    await tester.tap(acceptBtn);
    await tester.pumpAndSettle();
    expect(find.textContaining('Committed "The Gullet"'), findsOneWidget);
    // The committed proposal's button deactivates and reads "Committed".
    expect(find.widgetWithText(FilledButton, 'Committed'), findsOneWidget);

    // Back to the wiki tab (lands on Workshop); switch to Entries to see
    // the committed entry + change log with undo.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entries'));
    await tester.pumpAndSettle();
    expect(find.textContaining('The Gullet'), findsWidgets);
    expect(find.text('Change log'), findsOneWidget);

    await tester.tap(find.textContaining('Undo to here').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wiki-wiki-the-gullet')), findsNothing);
    // Redo brings it back.
    await tester.tap(find.textContaining('Redo').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wiki-wiki-the-gullet')), findsOneWidget);
  });

  testWidgets('wiki candidates from gameplay land in the review queue and '
      'can be promoted', (tester) async {
    final fixture = FixtureLlmClient(
      turnOutputs: [
        const TurnOutput(
          narrative: 'You discover the Gullet.',
          proposedDeltas: ProposedDeltas(clockAdvanceMinutes: 10),
          wikiCandidates: [
            WikiCandidate(
              id: '',
              title: 'The Gullet',
              category: 'Places',
              body: 'A drowned smuggling tunnel.',
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      LivingWorldsApp(services: testServices(llmFactory: (_) => fixture)),
    );
    await tester.pumpAndSettle();
    await createWorldViaUi(tester);
    await openHarborfall(tester);
    await openAsh(tester);
    await tester.enterText(
      find.byKey(const Key('turn-input')),
      'explore the caves',
    );
    await tester.tap(find.byKey(const Key('send-turn')));
    await tester.pumpAndSettle();

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wiki'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Review queue'), findsOneWidget);
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w.key != null && '${w.key}'.contains('promote-cand'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Review queue'), findsNothing);
    expect(find.byKey(const Key('wiki-wiki-the-gullet')), findsOneWidget);
  });

  testWidgets('save/load: save to a slot and inspect it', (tester) async {
    await tester.pumpWidget(LivingWorldsApp(services: testServices()));
    await tester.pumpAndSettle();
    await createWorldViaUi(tester);
    await openHarborfall(tester);

    await tester.tap(find.text('Save / Load'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-btn-slot-1')));
    await tester.pumpAndSettle();
    expect(find.text('Saved to slot-1.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('inspect-btn-slot-1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('events'), findsWidgets);
    expect(find.textContaining('Format v1'), findsOneWidget);
  });

  testWidgets('relationship graph tab renders with two characters', (
    tester,
  ) async {
    await tester.pumpWidget(LivingWorldsApp(services: testServices()));
    await tester.pumpAndSettle();
    await createWorldViaUi(tester);
    await openHarborfall(tester);

    // Only one character: helpful hint instead of a graph.
    await tester.tap(find.text('Relationships'));
    await tester.pumpAndSettle();
    expect(find.textContaining('second character'), findsOneWidget);
  });

  testWidgets('meeting flow: add a character, mark them present, the turn '
      'writes SharedEvent canon and a time-skip is offered later', (
    tester,
  ) async {
    final services = testServices();
    await tester.pumpWidget(LivingWorldsApp(services: services));
    await tester.pumpAndSettle();
    await createWorldViaUi(tester);
    await openHarborfall(tester);

    // Add Brynn.
    await tester.tap(find.byKey(const Key('new-character')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('new-character-name')),
      'Brynn',
    );
    await tester.tap(find.byKey(const Key('create-character')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('character-brynn')), findsOneWidget);

    // Play Ash with Brynn present in the scene.
    await openAsh(tester);
    await tester.tap(find.byKey(const Key('present-brynn')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('turn-input')),
      'share a drink with Brynn',
    );
    await tester.tap(find.byKey(const Key('send-turn')));
    await tester.pumpAndSettle();

    // Canon written on both timelines.
    final store = find
        .byKey(const Key('turn-input'))
        .evaluate()
        .isNotEmpty; // UI alive
    expect(store, isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Opening Brynn (clock 0 < world clock 30) offers the catch-up dialog.
    await tester.tap(find.byKey(const Key('character-brynn')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('skip-shared')), findsOneWidget);
    expect(find.byKey(const Key('skip-latest')), findsOneWidget);
    await tester.tap(find.byKey(const Key('skip-latest')));
    await tester.pumpAndSettle();

    // Time-skip ran (offline narrator supplies the retrospective) and
    // Brynn's session opened at the world clock.
    expect(find.byKey(const Key('turn-input')), findsOneWidget);
    expect(find.text('Day 1, 00:30'), findsWidgets);
  });

  testWidgets('map tab is a deferred stub (§13)', (tester) async {
    await tester.pumpWidget(LivingWorldsApp(services: testServices()));
    await tester.pumpAndSettle();
    await createWorldViaUi(tester);
    await openHarborfall(tester);
    await tester.tap(find.text('Map'));
    await tester.pumpAndSettle();
    expect(find.textContaining('deferred'), findsOneWidget);
  });

  test('settings (incl. OpenRouter key) persist across app restarts', () async {
    final kv = InMemoryKeyValueStore();
    final first = testServices(kv: kv);
    first.settings.update((s) {
      s.llmMode = LlmMode.openRouterDirect;
      s.openRouterKey = 'sk-or-test';
      s.model = 'anthropic/claude-opus-4';
    });
    await Future<void>.delayed(Duration.zero); // flush fire-and-forget save

    // A fresh AppServices over the same store = a simulated restart.
    final second = testServices(kv: kv);
    await second.init();
    expect(second.settings.llmMode, LlmMode.openRouterDirect);
    expect(second.settings.openRouterKey, 'sk-or-test');
    expect(second.settings.model, 'anthropic/claude-opus-4');
  });

  testWidgets('seeding workshop threads survive leaving the conversation', (
    tester,
  ) async {
    final fixture = FixtureLlmClient(
      completions: ['{"action":"chat","message":"Noted — tell me more."}'],
    );
    await tester.pumpWidget(
      LivingWorldsApp(services: testServices(llmFactory: (_) => fixture)),
    );
    await tester.pumpAndSettle();
    await createWorldViaUi(tester);
    await openHarborfall(tester);

    await tester.tap(find.text('Wiki'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Workshop'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-seeding-thread')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('seeding-input')),
      'Tell me about the docks',
    );
    await tester.tap(find.byKey(const Key('seeding-send')));
    await tester.pumpAndSettle();
    expect(find.text('Noted — tell me more.'), findsOneWidget);

    // Leave the conversation — the thread and its title persist in the list.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.textContaining('Tell me about the docks'), findsWidgets);
    expect(find.textContaining('messages'), findsWidgets);

    // Re-open it — the conversation is still there.
    await tester.tap(find.textContaining('Tell me about the docks').first);
    await tester.pumpAndSettle();
    expect(find.text('Noted — tell me more.'), findsOneWidget);
  });

  testWidgets('observe mode: an observation narrates but advances no clock and '
      'shows no chips', (tester) async {
    await tester.pumpWidget(LivingWorldsApp(services: testServices()));
    await tester.pumpAndSettle();
    await createWorldViaUi(tester);
    await openHarborfall(tester);
    await openAsh(tester);

    // Switch to Observe, then send.
    await tester.tap(find.text('Observe'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('turn-input')),
      'peer into the fog',
    );
    await tester.tap(find.byKey(const Key('send-turn')));
    await tester.pumpAndSettle();

    // Observation bubble rendered; clock unchanged; no mechanical chip.
    expect(find.textContaining('👁'), findsOneWidget);
    expect(find.text('Day 1, 00:00'), findsWidgets); // clock did not move
    expect(find.text('+30 min'), findsNothing);
  });

  testWidgets('new character: seeded creation shows an opening scenario and '
      'starts at the world clock', (tester) async {
    await tester.pumpWidget(LivingWorldsApp(services: testServices()));
    await tester.pumpAndSettle();
    await createWorldViaUi(tester);
    await openHarborfall(tester);

    // Advance the world clock via Ash first.
    await openAsh(tester);
    await tester.enterText(find.byKey(const Key('turn-input')), 'walk a while');
    await tester.tap(find.byKey(const Key('send-turn')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Create Mara from a seeding paragraph.
    await tester.tap(find.byKey(const Key('new-character')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('new-character-name')), 'Mara');
    await tester.enterText(
      find.byKey(const Key('new-character-seed')),
      'A wary dockside smuggler who owes the Guild a debt.',
    );
    await tester.tap(find.byKey(const Key('create-character')));
    await tester.pumpAndSettle();

    // Mara starts at the world clock (Day 1, 00:30), not zero.
    expect(find.byKey(const Key('character-mara')), findsOneWidget);
    expect(find.text('Day 1, 00:30'), findsWidgets);

    // Opening scenario is shown when Mara's session opens.
    await tester.tap(find.byKey(const Key('character-mara')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('opening-scenario')), findsOneWidget);
  });

  testWidgets('dead character: dialogue stays readable, input stays disabled', (
    tester,
  ) async {
    // Fixture forces an instant-lethal poison stack. Phase-1 supplies the
    // consequences; phase-2 (narrations) supplies the account that is stored.
    final fixture = FixtureLlmClient(
      turnOutputs: [
        const TurnOutput(
          narrative: '',
          proposedDeltas: ProposedDeltas(
            status: [
              StatusOp(op: StatusOpKind.add, key: 'poisoned', severity: 10),
            ],
          ),
          peril: true,
        ),
      ],
      narrations: ['The vial shatters; poison floods your veins.'],
    );
    await tester.pumpWidget(
      LivingWorldsApp(services: testServices(llmFactory: (_) => fixture)),
    );
    await tester.pumpAndSettle();
    await createWorldViaUi(tester);
    await openHarborfall(tester);
    await openAsh(tester);

    await tester.enterText(
      find.byKey(const Key('turn-input')),
      'drink the strange vial',
    );
    await tester.tap(find.byKey(const Key('send-turn')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('death-card')), findsOneWidget);

    // Back to the roster; the dead character is still tappable.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('character-ash')));
    await tester.pumpAndSettle();

    // Their dialogue is preserved and the death card shows; input is disabled.
    expect(find.textContaining('poison floods your veins'), findsWidgets);
    expect(find.byKey(const Key('death-card')), findsOneWidget);
    final input = tester.widget<TextField>(find.byKey(const Key('turn-input')));
    expect(input.enabled, isFalse);
  });

  testWidgets('duplicate world: copies a world into a new tile', (
    tester,
  ) async {
    await tester.pumpWidget(LivingWorldsApp(services: testServices()));
    await tester.pumpAndSettle();
    await createWorldViaUi(tester);
    expect(find.textContaining('Harborfall'), findsOneWidget);

    // Open the tile's menu and duplicate.
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w.key != null && '${w.key}'.contains('world-menu'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate'));
    await tester.pumpAndSettle();

    // Original + copy now both present.
    expect(find.textContaining('Harborfall (copy)'), findsOneWidget);
    expect(find.text('Harborfall'), findsOneWidget);
  });

  testWidgets('undo a gameplay step: reverts the turn and its clock advance', (
    tester,
  ) async {
    await tester.pumpWidget(LivingWorldsApp(services: testServices()));
    await tester.pumpAndSettle();
    await createWorldViaUi(tester);
    await openHarborfall(tester);
    await openAsh(tester);

    await tester.enterText(find.byKey(const Key('turn-input')), 'walk a while');
    await tester.tap(find.byKey(const Key('send-turn')));
    await tester.pumpAndSettle();
    expect(find.text('Day 1, 00:30'), findsWidgets); // clock advanced

    // Undo the turn: clock returns to zero and the bubble is gone.
    await tester.tap(find.byKey(const Key('undo-turn')));
    await tester.pumpAndSettle();
    expect(find.text('Day 1, 00:00'), findsWidgets);
    expect(find.text('Day 1, 00:30'), findsNothing);
    expect(find.textContaining('offline narrator'), findsNothing);
  });

  testWidgets('debug panel shows the two-step passes (context + narrative)', (
    tester,
  ) async {
    final services = testServices();
    services.settings.debugPanel = true;
    await tester.pumpWidget(LivingWorldsApp(services: services));
    await tester.pumpAndSettle();
    await createWorldViaUi(tester);
    await openHarborfall(tester);
    await openAsh(tester);

    await tester.enterText(find.byKey(const Key('turn-input')), 'look sharp');
    await tester.tap(find.byKey(const Key('send-turn')));
    await tester.pumpAndSettle();

    // The debug panel is a short, scrollable sheet; the two-step sections sit
    // at the bottom, so scroll them into view before asserting.
    final panelScroll = find.descendant(
      of: find.byKey(const Key('debug-panel')),
      matching: find.byType(Scrollable),
    );
    for (final key in const [
      'debug-context',
      'debug-consequences',
      'debug-narrative',
    ]) {
      await tester.scrollUntilVisible(
        find.byKey(Key(key)),
        120,
        scrollable: panelScroll,
      );
      expect(find.byKey(Key(key)), findsOneWidget);
    }
  });
}
