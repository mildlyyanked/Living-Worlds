/// World UI (§12): tabs for Characters, Wiki, Relationships, Save/Load,
/// with the furthest-clock display in the app bar. Map/Timeline: stubbed.
library;

import 'package:flutter/material.dart';

import '../tabs/characters_tab.dart';
import '../tabs/relationships_tab.dart';
import '../tabs/save_load_tab.dart';
import '../tabs/wiki_tab.dart';
import '../world_store.dart';

String formatClock(int minutes) {
  final d = minutes ~/ (60 * 24);
  final h = (minutes % (60 * 24)) ~/ 60;
  final m = minutes % 60;
  return 'Day ${d + 1}, ${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

class WorldScreen extends StatelessWidget {
  const WorldScreen({super.key, required this.store});

  final WorldStore store;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final p = store.projection;
        return DefaultTabController(
          length: 5,
          child: Scaffold(
            appBar: AppBar(
              title: Text(store.ref.name),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Center(
                    child: Text(
                      p == null ? '…' : formatClock(p.worldClock),
                      key: const Key('world-clock'),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ),
              ],
              bottom: const TabBar(
                isScrollable: true,
                tabs: [
                  Tab(icon: Icon(Icons.people), text: 'Characters'),
                  Tab(icon: Icon(Icons.menu_book), text: 'Wiki'),
                  Tab(icon: Icon(Icons.hub), text: 'Relationships'),
                  Tab(icon: Icon(Icons.save), text: 'Save / Load'),
                  Tab(icon: Icon(Icons.map), text: 'Map'),
                ],
              ),
            ),
            body: p == null
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    children: [
                      CharactersTab(store: store),
                      WikiTab(store: store),
                      RelationshipsTab(store: store),
                      SaveLoadTab(store: store),
                      const _DeferredStub(
                          label: 'Map / Timeline — deferred (§13)'),
                    ],
                  ),
          ),
        );
      },
    );
  }
}

class _DeferredStub extends StatelessWidget {
  const _DeferredStub({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Center(
        child: Text(label, style: Theme.of(context).textTheme.bodyLarge),
      );
}
