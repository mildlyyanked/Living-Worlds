/// World Select (§12): per-world tiles + creation + settings.
library;

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../world_store.dart';
import 'settings_screen.dart';
import 'world_screen.dart';

class WorldSelectScreen extends StatefulWidget {
  const WorldSelectScreen({super.key});

  @override
  State<WorldSelectScreen> createState() => _WorldSelectScreenState();
}

class _WorldSelectScreenState extends State<WorldSelectScreen> {
  Future<List<WorldRef>>? _worlds;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _worlds ??= _load();
  }

  Future<List<WorldRef>> _load() => AppScope.of(context).listWorlds();

  void _refresh() => setState(() {
        _worlds = _load();
      });

  Future<void> _createWorld() async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (context) => const _NewWorldDialog(),
    );
    if (result == null || !mounted) return;
    final services = AppScope.of(context);
    await services.createWorld(
        name: result.$1, characterName: result.$2);
    _refresh();
  }

  Future<void> _open(WorldRef ref) async {
    final services = AppScope.of(context);
    final store = await WorldStore.open(services, ref);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => WorldScreen(store: store)),
    );
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Living Worlds'),
        actions: [
          IconButton(
            key: const Key('settings'),
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: FutureBuilder<List<WorldRef>>(
        future: _worlds,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final worlds = snap.data!;
          if (worlds.isEmpty) {
            return const Center(
                child: Text('No worlds yet. Create one to begin.'));
          }
          return GridView.count(
            crossAxisCount: 2,
            padding: const EdgeInsets.all(16),
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            children: [
              for (final w in worlds)
                Card(
                  key: Key('world-tile-${w.id}'),
                  child: InkWell(
                    onTap: () => _open(w),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.public, size: 40),
                          const Spacer(),
                          Text(w.name,
                              style:
                                  Theme.of(context).textTheme.titleLarge),
                          Text(
                            w.path == 'memory' ? 'in memory' : 'on device',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('new-world'),
        onPressed: _createWorld,
        icon: const Icon(Icons.add),
        label: const Text('New world'),
      ),
    );
  }
}

class _NewWorldDialog extends StatefulWidget {
  const _NewWorldDialog();

  @override
  State<_NewWorldDialog> createState() => _NewWorldDialogState();
}

class _NewWorldDialogState extends State<_NewWorldDialog> {
  final _name = TextEditingController(text: 'Harborfall');
  final _character = TextEditingController(text: 'Ash');

  @override
  void dispose() {
    _name.dispose();
    _character.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New world'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('world-name'),
            controller: _name,
            decoration: const InputDecoration(labelText: 'World name'),
          ),
          TextField(
            key: const Key('character-name'),
            controller: _character,
            decoration:
                const InputDecoration(labelText: 'First character'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('create-world'),
          onPressed: () =>
              Navigator.pop(context, (_name.text, _character.text)),
          child: const Text('Create'),
        ),
      ],
    );
  }
}
