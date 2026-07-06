/// Gameplay UI (§12): character info panel beside the chat window,
/// toggleable overlays (inventory with affordances, quests, relationships),
/// mechanical-notification chips inline, debug panel behind a toggle (§9).
library;

import 'package:flutter/material.dart';
import 'package:living_worlds_engine/living_worlds_engine.dart';

import '../app_services.dart';
import '../widgets/debug_report_view.dart';
import '../world_store.dart';
import 'world_screen.dart';

enum _Overlay { none, inventory, quests, relationships }

class GameplayScreen extends StatefulWidget {
  const GameplayScreen(
      {super.key, required this.store, required this.characterId});

  final WorldStore store;
  final String characterId;

  @override
  State<GameplayScreen> createState() => _GameplayScreenState();
}

class _GameplayScreenState extends State<GameplayScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<ChatItem> _session = [];
  _Overlay _overlay = _Overlay.none;
  final Set<String> _present = {};

  WorldStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    _session.addAll(store.chatFor(widget.characterId));
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || store.busy) return;
    _input.clear();
    final turn = await store.playTurn(
      actorId: widget.characterId,
      input: text,
      presentCharacterIds: _present.toList(),
    );
    if (turn == null) return; // error surfaced via store.lastError
    setState(() {
      _session.add(ChatItem(
        userInput: text,
        narrative: turn.narrative,
        notifications: turn.notifications,
        report: turn.report,
        turnSeq: turn.turnSeq,
        died: turn.died,
      ));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final p = store.projection;
        final character = p?.characters[widget.characterId];
        if (p == null || character == null) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        final settings = AppScope.of(context).settings;
        final wide = MediaQuery.sizeOf(context).width > 700;

        final chat = _ChatColumn(
          session: _session,
          scroll: _scroll,
          input: _input,
          onSend: _send,
          store: store,
          character: character,
          onUndoDeath: _undoDeath,
        );
        final info = _InfoPanel(
          projection: p,
          character: character,
          present: _present,
          onTogglePresent: (id) => setState(() {
            _present.contains(id) ? _present.remove(id) : _present.add(id);
          }),
        );

        return Scaffold(
          appBar: AppBar(
            title: Text(character.name),
            actions: [
              Center(
                child: Text(formatClock(character.subjectiveClock),
                    key: const Key('actor-clock')),
              ),
              IconButton(
                key: const Key('overlay-inventory'),
                icon: const Icon(Icons.inventory_2),
                color: _overlay == _Overlay.inventory
                    ? Theme.of(context).colorScheme.primary
                    : null,
                onPressed: () => setState(() => _overlay =
                    _overlay == _Overlay.inventory
                        ? _Overlay.none
                        : _Overlay.inventory),
              ),
              IconButton(
                key: const Key('overlay-quests'),
                icon: const Icon(Icons.flag),
                color: _overlay == _Overlay.quests
                    ? Theme.of(context).colorScheme.primary
                    : null,
                onPressed: () => setState(() => _overlay =
                    _overlay == _Overlay.quests
                        ? _Overlay.none
                        : _Overlay.quests),
              ),
              IconButton(
                key: const Key('overlay-relationships'),
                icon: const Icon(Icons.hub),
                color: _overlay == _Overlay.relationships
                    ? Theme.of(context).colorScheme.primary
                    : null,
                onPressed: () => setState(() => _overlay =
                    _overlay == _Overlay.relationships
                        ? _Overlay.none
                        : _Overlay.relationships),
              ),
            ],
          ),
          body: Stack(
            children: [
              if (wide)
                Row(
                  children: [
                    SizedBox(width: 280, child: info),
                    const VerticalDivider(width: 1),
                    Expanded(child: chat),
                  ],
                )
              else
                chat,
              if (_overlay != _Overlay.none)
                Positioned(
                  top: 0,
                  right: 0,
                  bottom: 0,
                  width: 320,
                  child: Material(
                    elevation: 8,
                    child: _OverlayPanel(
                      overlay: _overlay,
                      projection: p,
                      character: character,
                    ),
                  ),
                ),
              if (store.busy)
                const Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black38,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
            ],
          ),
          bottomSheet: settings.debugPanel && _session.isNotEmpty
              ? DebugPanel(item: _session.last)
              : null,
        );
      },
    );
  }

  Future<void> _undoDeath() async {
    // Undo to just before the last committed turn (the fatal one).
    final events = await store.repo.eventsUpTo(-1);
    final lastTurn = events.lastWhere(
        (e) => e.type == EventType.turnCommitted,
        orElse: () => events.last);
    await store.undoToSeq(lastTurn.seq - 1);
    setState(() {
      if (_session.isNotEmpty) _session.removeLast();
    });
  }
}

class _ChatColumn extends StatelessWidget {
  const _ChatColumn({
    required this.session,
    required this.scroll,
    required this.input,
    required this.onSend,
    required this.store,
    required this.character,
    required this.onUndoDeath,
  });

  final List<ChatItem> session;
  final ScrollController scroll;
  final TextEditingController input;
  final VoidCallback onSend;
  final WorldStore store;
  final Character character;
  final VoidCallback onUndoDeath;

  @override
  Widget build(BuildContext context) {
    final dead = !character.alive;
    return Column(
      children: [
        Expanded(
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.all(12),
            children: [
              for (final item in session) _TurnBubble(item: item),
              if (store.lastError != null)
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('Turn failed (nothing committed): '
                        '${store.lastError}'),
                  ),
                ),
              if (dead)
                Card(
                  key: const Key('death-card'),
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        Text('${character.name} has died. '
                            'This timeline is frozen.'),
                        TextButton(
                          key: const Key('undo-death'),
                          onPressed: onUndoDeath,
                          child: const Text('Undo the fatal turn'),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('turn-input'),
                    controller: input,
                    enabled: !dead && !store.busy,
                    decoration: InputDecoration(
                      hintText: dead
                          ? 'Timeline frozen'
                          : 'What does ${character.name} do?',
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => onSend(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  key: const Key('send-turn'),
                  icon: const Icon(Icons.send),
                  onPressed: dead || store.busy ? null : onSend,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TurnBubble extends StatelessWidget {
  const _TurnBubble({required this.item});

  final ChatItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Card(
            color: theme.colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Text('> ${item.userInput}'),
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(item.narrative, style: theme.textTheme.bodyLarge),
          ),
        ),
        if (item.notifications.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final n in item.notifications)
                  Chip(
                    label: Text(n, style: theme.textTheme.labelSmall),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({
    required this.projection,
    required this.character,
    required this.present,
    required this.onTogglePresent,
  });

  final WorldProjection projection;
  final Character character;
  final Set<String> present;
  final void Function(String) onTogglePresent;

  @override
  Widget build(BuildContext context) {
    final schema = projection.world!.schema;
    final health = healthOf(character, schema, const EngineConfig());
    final others = projection.characters.values
        .where((c) => c.id != character.id && c.alive)
        .toList();
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text(character.name, style: Theme.of(context).textTheme.titleLarge),
        Text(character.bio, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        Row(
          children: [
            const Text('Health'),
            const SizedBox(width: 8),
            Expanded(
              child: LinearProgressIndicator(
                  value: health / 100, minHeight: 8),
            ),
            const SizedBox(width: 8),
            Text('${health.round()}', key: const Key('health-value')),
          ],
        ),
        const SizedBox(height: 12),
        for (final s in character.stats.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(s.key),
                Text(s.value.toStringAsFixed(0)),
              ],
            ),
          ),
        if (character.status.isNotEmpty) ...[
          const Divider(),
          Text('Status', style: Theme.of(context).textTheme.titleSmall),
          for (final s in character.status)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(schema.statusDef(s.key)?.label ?? s.key),
              trailing: Text(effectiveSeverity(s, schema.statusDef(s.key),
                      character.subjectiveClock)
                  .toStringAsFixed(1)),
            ),
        ],
        if (others.isNotEmpty) ...[
          const Divider(),
          Text('Present in scene (cameo, §4.4)',
              style: Theme.of(context).textTheme.titleSmall),
          for (final c in others)
            CheckboxListTile(
              key: Key('present-${c.id}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(c.name),
              subtitle: Text(formatClock(c.subjectiveClock)),
              value: present.contains(c.id),
              onChanged: (_) => onTogglePresent(c.id),
            ),
        ],
      ],
    );
  }
}

class _OverlayPanel extends StatelessWidget {
  const _OverlayPanel({
    required this.overlay,
    required this.projection,
    required this.character,
  });

  final _Overlay overlay;
  final WorldProjection projection;
  final Character character;

  @override
  Widget build(BuildContext context) {
    switch (overlay) {
      case _Overlay.inventory:
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Text('Inventory', style: Theme.of(context).textTheme.titleMedium),
            if (character.inventory.isEmpty) const Text('Empty.'),
            for (final i in character.inventory)
              ListTile(
                title: Text(
                    '${projection.itemDefs[i.defId]?.name ?? i.defId} ×${i.qty}'),
                subtitle: Text([
                  projection.itemDefs[i.defId]?.desc ?? '',
                  if ((projection.itemDefs[i.defId]?.affordances ?? [])
                      .isNotEmpty)
                    'enables: ${projection.itemDefs[i.defId]!.affordances.join(', ')}',
                ].where((s) => s.isNotEmpty).join('\n')),
                isThreeLine: true,
              ),
          ],
        );
      case _Overlay.quests:
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Text('Quests', style: Theme.of(context).textTheme.titleMedium),
            if (character.quests.where((q) => !q.hidden).isEmpty)
              const Text('No quests.'),
            for (final q in character.quests.where((q) => !q.hidden))
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${q.title} — ${q.state.name}',
                          style: Theme.of(context).textTheme.titleSmall),
                      for (final s in q.steps)
                        Row(
                          children: [
                            Icon(
                                s.done
                                    ? Icons.check_box
                                    : Icons.check_box_outline_blank,
                                size: 16),
                            const SizedBox(width: 6),
                            Expanded(child: Text(s.desc)),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
          ],
        );
      case _Overlay.relationships:
        final edges = projection.edges.values
            .where((e) =>
                e.fromChar == character.id || e.toChar == character.id)
            .toList();
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Text('Relationships',
                style: Theme.of(context).textTheme.titleMedium),
            if (edges.isEmpty) const Text('No edges yet.'),
            for (final e in edges)
              ListTile(
                title: Text(
                    '${projection.characters[e.fromChar]?.name ?? e.fromChar}'
                    ' → '
                    '${projection.characters[e.toChar]?.name ?? e.toChar}'),
                subtitle: Text(e.dims.entries
                    .map((d) => '${d.key}: ${d.value.toStringAsFixed(0)}')
                    .join(' · ')),
              ),
          ],
        );
      case _Overlay.none:
        return const SizedBox.shrink();
    }
  }
}
