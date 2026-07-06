/// Characters tab (§12): list -> Gameplay UI; time-skip entry point (§4.6).
library;

import 'package:flutter/material.dart';
import 'package:living_worlds_engine/living_worlds_engine.dart';

import '../screens/gameplay_screen.dart';
import '../screens/world_screen.dart';
import '../world_store.dart';

class CharactersTab extends StatelessWidget {
  const CharactersTab({super.key, required this.store});

  final WorldStore store;

  Future<void> _openCharacter(BuildContext context, Character c) async {
    final p = store.projection!;
    // Behind the world? Offer the catch-up generator (§4.6).
    if (c.alive && c.subjectiveClock < p.worldClock) {
      final choice = await showDialog<TimeSkipTarget?>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text('${c.name} is behind the world clock '
              '(${formatClock(c.subjectiveClock)} vs '
              '${formatClock(p.worldClock)})'),
          children: [
            SimpleDialogOption(
              key: const Key('skip-shared'),
              onPressed: () =>
                  Navigator.pop(context, TimeSkipTarget.afterLastSharedEvent),
              child: const Text('Resume after last shared event'),
            ),
            SimpleDialogOption(
              key: const Key('skip-latest'),
              onPressed: () =>
                  Navigator.pop(context, TimeSkipTarget.latestWorldClock),
              child: const Text('Catch up to the world clock'),
            ),
            SimpleDialogOption(
              key: const Key('skip-none'),
              onPressed: () => Navigator.pop(context),
              child: const Text('Play from where they are'),
            ),
          ],
        ),
      );
      if (choice != null) {
        final result =
            await store.timeSkip(characterId: c.id, target: choice);
        if (result != null && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Time skip: ${result.summary}'),
            duration: const Duration(seconds: 5),
          ));
        }
      }
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => GameplayScreen(store: store, characterId: c.id),
    ));
  }

  Future<void> _newCharacter(BuildContext context) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _NewCharacterDialog(),
    );
    if (name == null || name.isEmpty) return;
    final id = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    if (store.projection!.characters.containsKey(id)) return;
    await store.worldService.createCharacter(Character(
      id: id,
      worldId: store.ref.id,
      name: name,
      bio: 'A newcomer to ${store.ref.name}.',
      stats: const {'vitality': 100, 'hunger': 0, 'fatigue': 0, 'coin': 10},
    ));
    await store.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final p = store.projection!;
    final schema = p.world!.schema;
    final characters = p.characters.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('new-character'),
        onPressed: () => _newCharacter(context),
        icon: const Icon(Icons.person_add),
        label: const Text('New character'),
      ),
      body: ListView(
      children: [
        for (final c in characters)
          ListTile(
            key: Key('character-${c.id}'),
            leading: CircleAvatar(
              child: Text(c.name.isEmpty ? '?' : c.name[0]),
            ),
            title: Text(c.name + (c.alive ? '' : ' †')),
            subtitle: Text(
                '${formatClock(c.subjectiveClock)} · health '
                '${healthOf(c, schema, const EngineConfig()).round()}/100'
                '${c.status.isNotEmpty ? ' · ${c.status.map((s) => s.key).join(', ')}' : ''}'),
            trailing: c.alive
                ? const Icon(Icons.play_arrow)
                : const Icon(Icons.block),
            onTap: c.alive ? () => _openCharacter(context, c) : null,
          ),
      ],
      ),
    );
  }
}

class _NewCharacterDialog extends StatefulWidget {
  const _NewCharacterDialog();

  @override
  State<_NewCharacterDialog> createState() => _NewCharacterDialogState();
}

class _NewCharacterDialogState extends State<_NewCharacterDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New character'),
      content: TextField(
        key: const Key('new-character-name'),
        controller: _name,
        decoration: const InputDecoration(labelText: 'Name'),
        autofocus: true,
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          key: const Key('create-character'),
          onPressed: () => Navigator.pop(context, _name.text.trim()),
          child: const Text('Create'),
        ),
      ],
    );
  }
}
