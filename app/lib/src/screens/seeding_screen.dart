/// Seeding UI (§12, §5.1): ChatGPT-style workshop bound to wiki CRUD with a
/// clarifying-question flow and change-log write-through.
library;

import 'package:flutter/material.dart';
import 'package:living_worlds_engine/living_worlds_engine.dart';

import '../world_store.dart';

class SeedingScreen extends StatefulWidget {
  const SeedingScreen({super.key, required this.store});

  final WorldStore store;

  @override
  State<SeedingScreen> createState() => _SeedingScreenState();
}

class _Message {
  const _Message({required this.fromUser, required this.text, this.action});

  final bool fromUser;
  final String text;
  final SeedingAction? action;
}

class _SeedingScreenState extends State<SeedingScreen> {
  late final SeedingSession _session = widget.store.newSeedingSession();
  final _input = TextEditingController();
  final List<_Message> _messages = [];
  bool _busy = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    _input.clear();
    setState(() {
      _messages.add(_Message(fromUser: true, text: text));
      _busy = true;
    });
    try {
      final action = await _session.send(text);
      setState(() {
        _messages.add(_Message(
          fromUser: false,
          text: switch (action.kind) {
            SeedingActionKind.clarify || SeedingActionKind.chat =>
              action.message,
            SeedingActionKind.proposeCreate =>
              'Proposed new entry: "${action.entry!.title}"',
            SeedingActionKind.proposeUpdate =>
              'Proposed update to: "${action.entry!.title}"',
          },
          action: action,
        ));
      });
    } catch (e) {
      setState(() {
        _messages.add(_Message(fromUser: false, text: 'Error: $e'));
      });
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _accept(SeedingAction action) async {
    setState(() => _busy = true);
    try {
      await _session.accept(action);
      await widget.store.refresh();
      setState(() {
        _messages.add(_Message(
            fromUser: false,
            text: 'Committed "${action.entry!.title}" to the wiki '
                '(event logged; undo in the change log).'));
      });
    } catch (e) {
      setState(() {
        _messages.add(_Message(fromUser: false, text: 'Error: $e'));
      });
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Seeding workshop')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('Behind-the-scenes world building: describe '
                        'people, places, factions, lore. The assistant may '
                        'ask clarifying questions, then proposes wiki '
                        'entries you approve. No clock, no dice, no '
                        'character state (§5.1).'),
                  ),
                ),
                for (final m in _messages) ...[
                  Align(
                    alignment: m.fromUser
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Card(
                      color: m.fromUser
                          ? Theme.of(context).colorScheme.primaryContainer
                          : null,
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Text(m.text),
                      ),
                    ),
                  ),
                  if (m.action?.entry != null)
                    Card(
                      key: const Key('seeding-proposal'),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                '${m.action!.entry!.title} · '
                                '${m.action!.entry!.category}',
                                style:
                                    Theme.of(context).textTheme.titleSmall),
                            const SizedBox(height: 6),
                            Text(m.action!.entry!.body),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                FilledButton(
                                  key: const Key('accept-proposal'),
                                  onPressed:
                                      _busy ? null : () => _accept(m.action!),
                                  child: const Text('Accept & commit'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
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
                      key: const Key('seeding-input'),
                      controller: _input,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        hintText: 'Describe something for the wiki…',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    key: const Key('seeding-send'),
                    icon: const Icon(Icons.send),
                    onPressed: _busy ? null : _send,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
