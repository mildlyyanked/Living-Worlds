/// Seeding UI (§12, §5.1): ChatGPT-style workshop bound to wiki CRUD with a
/// clarifying-question flow and change-log write-through. Conversations are
/// persisted as per-world threads so they survive navigation and restarts.
library;

import 'package:flutter/material.dart';
import 'package:living_worlds_engine/living_worlds_engine.dart';

import '../persistence.dart';
import '../world_store.dart';

class SeedingScreen extends StatefulWidget {
  const SeedingScreen({super.key, required this.store, required this.thread});

  final WorldStore store;
  final SeedingThread thread;

  @override
  State<SeedingScreen> createState() => _SeedingScreenState();
}

class _SeedingScreenState extends State<SeedingScreen> {
  late final SeedingSession _session = widget.store.newSeedingSession(
    resume: widget.thread,
  );
  final _input = TextEditingController();
  bool _busy = false;

  SeedingThread get thread => widget.thread;

  /// Actions keyed by the message index they belong to, so an "Accept &
  /// commit" button can be shown for a proposal even after reload.
  final Map<int, SeedingAction> _pendingActions = {};

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _persist() async {
    thread.updatedAt = DateTime.now();
    // Title the thread from its first user line for the list view.
    final firstUser = thread.messages.where((m) => m.fromUser).firstOrNull;
    if (firstUser != null && thread.title == 'New workshop thread') {
      thread.title = firstUser.text.length <= 40
          ? firstUser.text
          : '${firstUser.text.substring(0, 37)}...';
    }
    await widget.store.persistSeedingThreads();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    _input.clear();
    setState(() {
      thread.messages.add(SeedingMessage(fromUser: true, text: text));
      _busy = true;
    });
    await _persist();
    try {
      final action = await _session.send(text);
      setState(() {
        final display = switch (action.kind) {
          SeedingActionKind.clarify || SeedingActionKind.chat => action.message,
          SeedingActionKind.proposeCreate =>
            'Proposed new entry: "${action.entry!.title}"\n\n${action.entry!.body}',
          SeedingActionKind.proposeUpdate =>
            'Proposed update to: "${action.entry!.title}"\n\n${action.entry!.body}',
        };
        thread.messages.add(SeedingMessage(fromUser: false, text: display));
        if (action.entry != null) {
          _pendingActions[thread.messages.length - 1] = action;
        }
      });
      await _persist();
    } catch (e) {
      setState(() {
        thread.messages.add(SeedingMessage(fromUser: false, text: 'Error: $e'));
      });
      await _persist();
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _accept(int messageIndex, SeedingAction action) async {
    setState(() => _busy = true);
    try {
      await _session.accept(action);
      await widget.store.refresh();
      setState(() {
        _pendingActions.remove(messageIndex);
        thread.messages.add(
          SeedingMessage(
            fromUser: false,
            text:
                'Committed "${action.entry!.title}" to the wiki '
                '(event logged; undo in the change log).',
          ),
        );
      });
      await _persist();
    } catch (e) {
      setState(() {
        thread.messages.add(SeedingMessage(fromUser: false, text: 'Error: $e'));
      });
      await _persist();
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(thread.title)),
      body: Column(
        children: [
          Expanded(
            // SelectionArea makes every message selectable/copyable.
            child: SelectionArea(
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        'Behind-the-scenes world building: describe people, '
                        'places, factions, lore. The assistant may ask '
                        'clarifying questions, then proposes wiki entries you '
                        'approve. No clock, no dice, no character state (§5.1).',
                      ),
                    ),
                  ),
                  for (var i = 0; i < thread.messages.length; i++)
                    _bubble(context, i, thread.messages[i]),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 10),
                          Text('Thinking…'),
                        ],
                      ),
                    ),
                ],
              ),
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

  Widget _bubble(BuildContext context, int index, SeedingMessage m) {
    final action = _pendingActions[index];
    return Column(
      crossAxisAlignment: m.fromUser
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Align(
          alignment: m.fromUser ? Alignment.centerRight : Alignment.centerLeft,
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
        if (action?.entry != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: FilledButton(
              key: const Key('accept-proposal'),
              onPressed: _busy ? null : () => _accept(index, action!),
              child: const Text('Accept & commit'),
            ),
          ),
      ],
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
